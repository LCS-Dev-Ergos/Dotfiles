#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ PUBLIC FUNCTION SAFETY TEST ++++++++++++++++++++++ #
# ============================================================================ #
# Verifies fail-closed validation and secure bookmark updates for public
# helpers changed by the shared UI refactor. No network or long-running command
# is allowed to execute during this test.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail extendedglob
umask 077

typeset test_root="${0:A:h:h}"
typeset fixture_parent="$test_root/tests/.tmp"
command mkdir -p -- "$fixture_parent"
typeset fixture_root
fixture_root="$(command mktemp -d \
  "$fixture_parent/function-safety.XXXXXX")" || return 1

_function_safety_cleanup() {
  case "${fixture_root:-}" in
    "$fixture_parent"/function-safety.*)
      command rm -rf -- "$fixture_root"
      ;;
  esac
  command rmdir -- "$fixture_parent" 2>/dev/null || :
}
trap _function_safety_cleanup EXIT
trap 'exit 130' INT TERM HUP

command mkdir -p -- "$fixture_root/home" "$fixture_root/work"
export HOME="$fixture_root/home"
export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain

source "$test_root/runtime-helpers.zsh"
source "$test_root/functions/productivity.zsh"
source "$test_root/functions/files.zsh"
source "$test_root/functions/network.zsh"

builtin cd -- "$fixture_root/work" || return 1
bm add 'team\docs' >/dev/null || {
  print -u2 "FAIL: bm rejected a safe bookmark name"
  return 1
}
command grep -Fqx -- "team\docs=$fixture_root/work" \
  "$HOME/.directory_bookmarks" || {
  print -u2 "FAIL: bm did not preserve a literal backslash in the name"
  return 1
}

zmodload -i zsh/stat
typeset -A bookmark_stat
zstat -L -H bookmark_stat -- "$HOME/.directory_bookmarks"
(( (bookmark_stat[mode] & 8#77) == 0 )) || {
  print -u2 "FAIL: bm created a group- or world-accessible store"
  return 1
}
typeset -a bookmark_temps=("$HOME"/.directory_bookmarks.tmp.*(N))
(( ${#bookmark_temps[@]} == 0 )) || {
  print -u2 "FAIL: bm left a temporary file behind"
  return 1
}

bm del 'team\docs' >/dev/null || {
  print -u2 "FAIL: bm could not delete a literal bookmark name"
  return 1
}

typeset protected_file="$fixture_root/protected"
print -r -- "do not modify" >| "$protected_file"
command chmod 644 "$protected_file"
command rm -f -- "$HOME/.directory_bookmarks"
command ln -s -- "$protected_file" "$HOME/.directory_bookmarks"
if bm list >/dev/null 2>&1; then
  print -u2 "FAIL: bm accepted a symlinked bookmark store"
  return 1
fi
[[ "$(<"$protected_file")" == "do not modify" ]] || {
  print -u2 "FAIL: bm modified the target of a bookmark symlink"
  return 1
}
typeset -A protected_stat
zstat -L -H protected_stat -- "$protected_file"
(( (protected_stat[mode] & 8#77) == 8#44 )) || {
  print -u2 "FAIL: bm changed permissions through a symlink"
  return 1
}

if count "$fixture_root" "$fixture_root/work" >/dev/null 2>&1; then
  print -u2 "FAIL: count silently accepted multiple target directories"
  return 1
fi
if portscan -proxy 1 2 >/dev/null 2>&1; then
  print -u2 "FAIL: portscan accepted an option-like hostname"
  return 1
fi
if serve 8000 8001 >/dev/null 2>&1; then
  print -u2 "FAIL: serve silently accepted multiple ports"
  return 1
fi
if shorten example.com ignored >/dev/null 2>&1; then
  print -u2 "FAIL: shorten silently ignored extra arguments"
  return 1
fi

print -r -- "PASS: public helpers validate inputs and protect local state"

# ============================================================================ #
# End of tests/test-function-safety.zsh
