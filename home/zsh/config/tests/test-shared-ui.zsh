#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ SHARED UI TEST ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies the shared UI helpers in scripts/_shared-helpers.zsh: mode
# resolution (plain/ansi/gum, NO_COLOR override, invalid mode rejection),
# ANSI accent colors, the Gum process budget per call, and the safe-by-default
# non-interactive confirm.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir shared-ui)" || return 1
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$fixture_root/bin"
cat > "$fixture_root/bin/gum" <<'EOF'
#!/bin/sh
printf 'call\n' >> "$GUM_CALL_LOG"
printf '%s\n' "$*" >> "$GUM_ARG_LOG"
if [ "${GUM_FAIL:-0}" = 1 ]; then
  if [ "$1" = table ]; then
    cat >/dev/null
  fi
  exit 1
fi
if [ "$1" = table ]; then
  cat
  exit 0
fi
for argument do
  last_argument=$argument
done
printf '%s\n' "$last_argument"
EOF
chmod 700 "$fixture_root/bin/gum"

export PATH="$fixture_root/bin:$PATH"
export GUM_CALL_LOG="$fixture_root/gum-calls"
export GUM_ARG_LOG="$fixture_root/gum-args"
rehash

source "$test_root/scripts/_shared-helpers.zsh"
unset NO_COLOR

[[ "$(_zsh_ui_mode plain)" == plain ]] || {
  print -u2 "FAIL: explicit plain UI mode was not preserved"
  return 1
}
[[ "$(_zsh_ui_mode ansi)" == ansi ]] || {
  print -u2 "FAIL: explicit ANSI UI mode was not preserved"
  return 1
}
[[ "$(NO_COLOR=1 _zsh_ui_mode gum)" == plain ]] || {
  print -u2 "FAIL: NO_COLOR did not force plain UI mode"
  return 1
}
if _zsh_ui_mode invalid >/dev/null 2>&1; then
  print -u2 "FAIL: invalid UI mode was accepted"
  return 1
fi

typeset ansi_heading
ansi_heading="$(ZSH_UI_STYLE=ansi _zsh_ui_heading Title Subtitle)" || return 1
[[ "$ansi_heading" == *$'\e[1;38;5;212mTitle'* ]] || {
  print -u2 "FAIL: ANSI heading did not use the shared accent"
  return 1
}

ZSH_UI_STYLE=gum _zsh_ui_heading Title Subtitle >/dev/null
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 1 ]] || {
  print -u2 "FAIL: shared heading did not use exactly one Gum process"
  return 1
}

typeset gum_section
gum_section="$(ZSH_UI_STYLE=gum _zsh_ui_section Section)" || return 1
[[ "$gum_section" == *$'\e[1;38;5;75mSection'* ]] || {
  print -u2 "FAIL: Gum mode section did not retain native ANSI color"
  return 1
}
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 1 ]] || {
  print -u2 "FAIL: a per-section Gum process was spawned"
  return 1
}

typeset plain_subsection
plain_subsection="$(ZSH_UI_STYLE=plain _zsh_ui_subsection Section 80)" ||
  return 1
[[ "$plain_subsection" == $'Section\n  ------------------------' ]] || {
  print -u2 "FAIL: shared subsection diverged from the zfuncs layout"
  return 1
}

ZSH_UI_STYLE=gum _zsh_ui_subsection Section 80 >/dev/null
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 1 ]] || {
  print -u2 "FAIL: shared subsection spawned a Gum process"
  return 1
}

ZSH_UI_STYLE=gum _zsh_ui_card Card "" "Field  value" >/dev/null
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 2 ]] || {
  print -u2 "FAIL: shared card did not use exactly one Gum process"
  return 1
}

typeset plain_table
plain_table="$(
  ZSH_UI_STYLE=plain _zsh_ui_table \
    $'Name\tValue' $'alpha\t1' $'longer\t2'
)" || return 1
[[ "$plain_table" == *'Name'*'Value'*'longer'*'2'* ]] || {
  print -u2 "FAIL: native table fallback lost headers or rows"
  return 1
}

typeset gum_table
gum_table="$(
  ZSH_UI_STYLE=gum _zsh_ui_table $'Name\tValue' $'alpha\t1'
)" || return 1
[[ "$gum_table" == *$'alpha\t1'* ]] || {
  print -u2 "FAIL: Gum table did not receive its row data"
  return 1
}
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 3 ]] || {
  print -u2 "FAIL: shared table did not use exactly one Gum process"
  return 1
}

typeset plain_definitions
plain_definitions="$(
  ZSH_UI_STYLE=plain _zsh_ui_definition_list \
    $'short\tOne' $'longer-term\tTwo'
)" || return 1
[[ "$plain_definitions" == $'  short        One\n  longer-term  Two' ]] || {
  print -u2 "FAIL: shared definition list did not align its descriptions"
  return 1
}

ZSH_UI_STYLE=gum _zsh_ui_definition_list $'term\tdescription' >/dev/null
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 3 ]] || {
  print -u2 "FAIL: shared definition list spawned a Gum process"
  return 1
}

typeset failed_gum_table
failed_gum_table="$(
  GUM_FAIL=1 ZSH_UI_STYLE=gum _zsh_ui_table \
    $'Name\tValue' $'fallback\tworks'
)" || return 1
[[ "$failed_gum_table" == *'Name'*'Value'*'fallback'*'works'* ]] || {
  print -u2 "FAIL: failed Gum table did not use the native fallback"
  return 1
}
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 4 ]] || {
  print -u2 "FAIL: failed Gum table spawned an unexpected process count"
  return 1
}

typeset unsafe_table
unsafe_table="$(
  ZSH_UI_STYLE=plain _zsh_ui_table \
    $'Name\tValue' $'unsafe\tline\e[2J\nnext'
)" || return 1
[[ "$unsafe_table" != *$'\e'* &&
   "$unsafe_table" == *'line\x1b[2J\nnext'* ]] || {
  print -u2 "FAIL: table output did not escape terminal control characters"
  return 1
}

ZSH_UI_STYLE=gum _shared_banner Banner Subtitle >/dev/null
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == 5 ]] || {
  print -u2 "FAIL: compatibility banner exceeded its Gum process budget"
  return 1
}

typeset plain_log
plain_log="$(ZSH_UI_STYLE=plain _zsh_ui_log ok complete)" || return 1
[[ "$plain_log" == "[OK]    complete" ]] || {
  print -u2 "FAIL: plain shared log output is unstable"
  return 1
}

typeset unsafe_log
unsafe_log="$(
  ZSH_UI_STYLE=plain _zsh_ui_log info $'line\e[2J\nnext'
)" || return 1
[[ "$unsafe_log" != *$'\e'* &&
   "$unsafe_log" == *'line\x1b[2J\nnext'* ]] || {
  print -u2 "FAIL: log output did not escape terminal control characters"
  return 1
}

typeset wide_rule
wide_rule="$(ZSH_UI_STYLE=plain _zsh_ui_rule - 160)" || return 1
(( ${#wide_rule} == 160 )) || {
  print -u2 "FAIL: shared rule still clamps wide layouts prematurely"
  return 1
}

typeset styled_rule
styled_rule="$(NO_COLOR= ZSH_UI_STYLE=ansi _zsh_ui_rule "" 40)" ||
  return 1
[[ "$styled_rule" == "${(pl:40::─:)}" ]] || {
  print -u2 "FAIL: default styled rule did not match the zfuncs divider"
  return 1
}

if ZSH_UI_STYLE=plain _zsh_ui_confirm "Continue?" </dev/null 2>/dev/null; then
  print -u2 "FAIL: non-interactive confirmation did not fail safely"
  return 1
fi

# ++++++++++++++++++++++++++ GUM TABLE REGRESSIONS +++++++++++++++++++++++++++ #

# The row join needs the p flag. Without it the rows were joined by the literal
# characters "\" and "n", Gum saw a single malformed record, and every table
# with more than one row silently fell back to the native renderer.
typeset multi_row_table
multi_row_table="$(
  ZSH_UI_STYLE=gum _zsh_ui_table \
    $'Name\tValue' $'alpha\t1' $'beta\t2' $'gamma\t3'
)" || return 1
[[ "$multi_row_table" == $'alpha\t1\nbeta\t2\ngamma\t3' ]] || {
  print -u2 "FAIL: multi-row table rows were not passed to Gum as separate lines"
  return 1
}

typeset table_args
table_args="$(command grep -m1 '^table ' "$GUM_ARG_LOG" || true)"
[[ "$table_args" == *--lazy-quotes* ]] || {
  print -u2 "FAIL: Gum table did not tolerate quotes in cell data"
  return 1
}
[[ "$table_args" != *--header.foreground* ]] || {
  print -u2 "FAIL: Gum 2.0 applies --header.foreground to the first data row"
  return 1
}

# +++++++++++++++++++++++ FUNCTION SPINNER CONTRACT ++++++++++++++++++++++++++ #

_ui_spin_worker() {
  print -r -- "worker-output"
  return 5
}

# With stderr redirected there is nowhere to draw, so no Gum process may start
# and the label must not contaminate the captured standard output.
typeset spin_calls_before spin_output
typeset -i spin_status=0
spin_calls_before="$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')"
spin_output="$(
  ZSH_UI_STYLE=gum _zsh_ui_spinner_fn "Working" _ui_spin_worker 2>/dev/null
)" || spin_status=$?
[[ "$spin_output" == "worker-output" ]] || {
  print -u2 "FAIL: function spinner altered the captured output"
  return 1
}
(( spin_status == 5 )) || {
  print -u2 "FAIL: function spinner lost the worker exit status, got $spin_status"
  return 1
}
[[ "$(wc -l < "$GUM_CALL_LOG" | tr -d ' ')" == "$spin_calls_before" ]] || {
  print -u2 "FAIL: function spinner spawned Gum with no terminal to draw on"
  return 1
}

# The Gum branch only runs with a real terminal on stderr, so it needs a pty.
# It is where a deadlock or a lost exit status would hide.
if zmodload zsh/zpty 2>/dev/null; then
  typeset spin_script
  spin_script="source ${(q)test_root}/scripts/_shared-helpers.zsh"
  spin_script+='; work() { /bin/sleep 0.3; print -r -- pty-payload; return 4 }'
  spin_script+='; out=$(ZSH_UI_STYLE=gum _zsh_ui_spinner_fn Working work)'
  spin_script+='; print -r -- "SPINRESULT=${out}=$?"'

  zpty ui_spin "PATH=${(q)PATH} GUM_CALL_LOG=${(q)GUM_CALL_LOG} GUM_ARG_LOG=${(q)GUM_ARG_LOG} zsh -c ${(q)spin_script}"
  typeset pty_buffer="" pty_chunk=""
  typeset -i pty_ticks=0
  while (( pty_ticks < 150 )); do
    if zpty -r -t ui_spin pty_chunk 2>/dev/null; then
      pty_buffer+="$pty_chunk"
      [[ "$pty_buffer" == *SPINRESULT=* ]] && break
    fi
    /bin/sleep 0.1
    # Post-increment yields the old value, so the first pass would return 1 and
    # err_return would abort the suite mid-loop.
    (( ++pty_ticks ))
  done
  zpty -d ui_spin 2>/dev/null
  pty_buffer="${pty_buffer//$'\r'/}"
  [[ "$pty_buffer" == *"SPINRESULT=pty-payload=4"* ]] || {
    print -u2 "FAIL: Gum spinner path lost output or status: ${pty_buffer//$'\n'/ }"
    return 1
  }
fi

print -r -- "PASS: shared UI modes, Gum budget, and safe fallback"

# ============================================================================ #
# End of tests/test-shared-ui.zsh
