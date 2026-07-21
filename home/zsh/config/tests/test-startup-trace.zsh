#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ STARTUP TRACE TEST ++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies startup-trace.zsh both in isolation (TSV report creation, mode 600,
# stable header, recorded milestones) and end to end through a real fast-start
# shell (milestone coverage and chronological order, plus early zprof loading
# from .zshenv).
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
typeset zsh_root="${test_root:h}"
typeset fixture_parent="$test_root/tests/.tmp"
mkdir -p "$fixture_parent"
export TMPDIR="$fixture_parent"
export TMPPREFIX="$fixture_parent/zsh"
typeset fixture_root
fixture_root="$(mktemp -d "$fixture_parent/trace-test.XXXXXX")" || return 1
trap '
  command rm -rf -- "$fixture_root"
  command rmdir -- "$fixture_parent" 2>/dev/null
' EXIT
trap 'exit 130' INT TERM HUP

typeset trace_file="$fixture_root/unit.tsv"
export ZSH_STARTUP_TRACE=1
export ZSH_STARTUP_TRACE_FILE="$trace_file"
source "$test_root/startup-trace.zsh"
_zsh_startup_trace_mark "unit:marker"
_zsh_startup_trace_write

[[ -s "$trace_file" ]] || {
  print -u2 "FAIL: startup trace did not create its TSV report"
  return 1
}
[[ "$(command stat -f '%Lp' "$trace_file" 2>/dev/null ||
       command stat -c '%a' "$trace_file")" == 600 ]] || {
  print -u2 "FAIL: startup trace report does not have mode 600"
  return 1
}

typeset unit_report="$(<"$trace_file")"
[[ "$unit_report" == *$'elapsed_ms\tdelta_ms\tmilestone'* ]] || {
  print -u2 "FAIL: startup trace report has no stable TSV header"
  return 1
}
[[ "$unit_report" == *$'\ttrace:start'* ]] || {
  print -u2 "FAIL: startup trace omitted its origin milestone"
  return 1
}
[[ "$unit_report" == *$'\tunit:marker'* ]] || {
  print -u2 "FAIL: startup trace omitted a recorded milestone"
  return 1
}

mkdir -p "$fixture_root/home" "$fixture_root/cache"
ln -s "$zsh_root/zshrc" "$fixture_root/home/.zshrc"
typeset child_trace="$fixture_root/child.tsv"
typeset child_stdout="$fixture_root/child.stdout"
typeset child_stderr="$fixture_root/child.stderr"

command env \
  HOME="$fixture_root/home" \
  XDG_CACHE_HOME="$fixture_root/cache" \
  ZDOTDIR="$test_root" \
  ZSH_CACHE_AUTO=0 \
  ZSH_FAST_START=1 \
  ZSH_STARTUP_TRACE=1 \
  ZSH_STARTUP_TRACE_EXIT=1 \
  ZSH_STARTUP_TRACE_FILE="$child_trace" \
  ZSH_STARTUP_TRACE_FINISH=precmd \
  zsh -di </dev/null >"$child_stdout" 2>"$child_stderr" || {
    print -u2 "FAIL: isolated fast-start trace did not complete"
    command sed -n '1,120p' "$child_stderr" >&2
    return 1
  }

typeset child_report="$(<"$child_trace")"
typeset milestone
for milestone in \
  .zshenv:entry \
  .zshenv:ready \
  .zshrc:entry \
  module:00-initialization.zsh \
  module:90-path.zsh \
  .zshrc:loaded \
  precmd \
  input-ready; do
  [[ "$child_report" == *$'\t'"$milestone"* ]] || {
    print -u2 "FAIL: end-to-end trace omitted '$milestone'"
    return 1
  }
done

typeset -i previous_line=0 current_line=0
for milestone in .zshenv:entry .zshrc:entry .zshrc:loaded input-ready; do
  current_line="$(command grep -n $'\t'"$milestone"'$' \
    "$child_trace" | command cut -d: -f1)"
  (( current_line > previous_line )) || {
    print -u2 "FAIL: startup milestones are not chronologically ordered"
    return 1
  }
  previous_line=$current_line
done

command env \
  HOME="$fixture_root/home" \
  ZDOTDIR="$test_root" \
  ZSH_PROFILE=1 \
  zsh -d -c '(( $+builtins[zprof] ))' || {
    print -u2 "FAIL: zprof was not loaded early from .zshenv"
    return 1
  }

print -r -- \
  "PASS: secure startup trace, ordered milestones, and early zprof"

# ============================================================================ #
# End of tests/test-startup-trace.zsh
