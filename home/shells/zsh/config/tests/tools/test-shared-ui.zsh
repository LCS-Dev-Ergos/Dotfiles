#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ SHARED UI TEST ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies the shared terminal style in scripts/_ui.zsh, loaded through
# _shared-helpers.zsh: mode resolution (plain/ansi/gum, NO_COLOR override,
# invalid mode rejection), the framed headers and the ruled section, card,
# table, summary and callout renderers (no Gum process for static output,
# margins and width fitting, status markers and colors, plain capture
# layout), path display shortening, the function
# spinner contract, and the safe non-interactive confirm and choose.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
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

_ui_gum_calls() {
  if [[ -s "$GUM_CALL_LOG" ]]; then
    command wc -l < "$GUM_CALL_LOG" | command tr -d ' '
  else
    print -r -- 0
  fi
}

_ui_strip() {
  emulate -L zsh
  setopt localoptions extendedglob
  REPLY="${1//$'\e'\[[0-9;]#m/}"
}

# A header sits in a rounded frame whose inside lines up with the content
# column: the badge starts where section titles do.
typeset ansi_heading
ansi_heading="$(COLUMNS=60 ZSH_UI_STYLE=ansi _zsh_ui_heading Title Subtitle)" ||
  return 1
typeset -a heading_lines=("${(@f)ansi_heading}")
_ui_strip "${heading_lines[2]}"
(( ${#heading_lines} == 3 )) &&
  [[ "${heading_lines[1]}" == $'\e[34m╭'*$'╮\e[0m' &&
     "${heading_lines[2]}" == *$'\e[1;7;36m Title \e[0m  \e[38;5;245mSubtitle\e[0m'* &&
     "$REPLY" == "│  Title   Subtitle"*" │" &&
     "${heading_lines[3]}" == $'\e[34m╰'*$'╯\e[0m' ]] &&
  (( ${(m)#REPLY} == 60 )) || {
  print -u2 "FAIL: ANSI heading is not a framed badge with its subtitle beside it"
  return 1
}
typeset long_heading
long_heading="$(
  COLUMNS=40 ZSH_UI_STYLE=ansi _zsh_ui_heading Title \
    "a subtitle too long to share the line with the badge"
)" || return 1
heading_lines=("${(@f)long_heading}")
_ui_strip "${heading_lines[3]}"
(( ${#heading_lines} == 4 )) && [[ "$REPLY" == "│  a subtitle"*"… │" ]] || {
  print -u2 "FAIL: a long heading subtitle did not move under the badge"
  return 1
}

typeset plain_heading
plain_heading="$(ZSH_UI_STYLE=plain _zsh_ui_heading Title Subtitle)" || return 1
[[ "$plain_heading" == $'Title\nSubtitle' ]] || {
  print -u2 "FAIL: plain heading is no longer two bare lines"
  return 1
}

# Static output is drawn natively in every mode; Gum is reserved for prompts
# and spinners, so none of these may start a process.
ZSH_UI_STYLE=gum _zsh_ui_heading Title Subtitle >/dev/null
typeset gum_section
gum_section="$(
  COLUMNS=40 ZSH_UI_STYLE=gum _zsh_ui_section 'Section · 3'
)" || return 1
_ui_strip "$gum_section"
[[ "$gum_section" == $'  \e[1;34mSection\e[0m \e[2;34m─'* &&
   "$REPLY" == "  Section ─"*"─ 3" ]] && (( ${(m)#REPLY} == 38 )) || {
  print -u2 "FAIL: styled section lost its rule or the note at its end"
  return 1
}
[[ "$(ZSH_UI_STYLE=ansi _zsh_ui_section --tone error Failed)" == \
   $'  \e[1;31mFailed\e[0m \e[2;34m─'* ]] || {
  print -u2 "FAIL: a toned section did not set its title in the tone's color"
  return 1
}
ZSH_UI_STYLE=ansi _zsh_ui_section --tone loud Failed >/dev/null 2>&1 &&
  { print -u2 "FAIL: an unknown section tone was accepted"; return 1 }
[[ "$(ZSH_UI_STYLE=plain _zsh_ui_section Section 3)" == "Section · 3" ]] || {
  print -u2 "FAIL: plain section did not keep its note"
  return 1
}
ZSH_UI_STYLE=gum _zsh_ui_subsection Section 80 >/dev/null
ZSH_UI_STYLE=gum _zsh_ui_card Card "" $'Field\tvalue' >/dev/null
ZSH_UI_STYLE=gum _zsh_ui_table $'Name\tValue' $'alpha\t1' >/dev/null
ZSH_UI_STYLE=gum _zsh_ui_definition_list $'term\tdescription' >/dev/null
ZSH_UI_STYLE=gum _shared_banner Banner Subtitle >/dev/null
ZSH_UI_STYLE=gum _zsh_ui_app_header tool Title Subtitle >/dev/null
ZSH_UI_STYLE=gum _zsh_ui_summary $'ok\t1\tok' >/dev/null
ZSH_UI_STYLE=gum _zsh_ui_callout warn Title Body >/dev/null
[[ "$(_ui_gum_calls)" == 0 ]] || {
  print -u2 "FAIL: static output spawned a Gum process"
  return 1
}

typeset plain_subsection
plain_subsection="$(ZSH_UI_STYLE=plain _zsh_ui_subsection Section 80)" ||
  return 1
[[ "$plain_subsection" == $'Section\n  ------------------------' ]] || {
  print -u2 "FAIL: shared subsection diverged from the zfuncs layout"
  return 1
}

typeset plain_card
plain_card="$(
  ZSH_UI_STYLE=plain _zsh_ui_card Card $'Short\tone' $'Longer key\ttwo'
)" || return 1
[[ "$plain_card" == $'Card\n\nShort       one\nLonger key  two' ]] || {
  print -u2 "FAIL: plain card did not align its key/value lines"
  return 1
}

typeset styled_card
styled_card="$(
  COLUMNS=44 ZSH_UI_STYLE=ansi _zsh_ui_card Card \
    $'Key\tvalue that is long enough to wrap inside the narrow card'
)" || return 1
typeset -a card_lines=("${(@f)styled_card}")
typeset card_line
for card_line in "${card_lines[@]}"; do
  _ui_strip "$card_line"
  (( ${(m)#REPLY} <= 44 )) || {
    print -u2 "FAIL: styled card is wider than the terminal"
    return 1
  }
  [[ "$REPLY" != *[╭╮╰╯│]* ]] || {
    print -u2 "FAIL: styled card still draws a frame"
    return 1
  }
done
[[ "${card_lines[1]}" == $'  \e[1;34mCard\e[0m \e[2;34m─'* &&
   "${card_lines[2]}" == $'    \e[38;5;245mKey\e[0m  value'* ]] || {
  print -u2 "FAIL: styled card lost its section title or indented muted key"
  return 1
}
(( ${#card_lines} > 2 )) || {
  print -u2 "FAIL: styled card did not wrap a long value"
  return 1
}
_ui_strip "${card_lines[3]}"
[[ "$REPLY" == "         "[a-z]* ]] || {
  print -u2 "FAIL: a wrapped value did not stay under its column"
  return 1
}

typeset plain_table
plain_table="$(
  ZSH_UI_STYLE=plain _zsh_ui_table \
    $'Name\tValue' $'alpha\t1' $'longer\t2'
)" || return 1
[[ "$plain_table" == $'NAME    VALUE\nalpha   1\nlonger  2' ]] || {
  print -u2 "FAIL: plain table layout changed"
  return 1
}

typeset aligned_table
aligned_table="$(
  ZSH_UI_STYLE=plain _zsh_ui_table --align lr \
    $'Name\tSize' $'alpha\t1 KB' $'beta\t120 KB'
)" || return 1
[[ "$aligned_table" == $'NAME     SIZE\nalpha    1 KB\nbeta   120 KB' ]] || {
  print -u2 "FAIL: right-aligned column was not padded on the left"
  return 1
}

typeset styled_table
styled_table="$(
  ZSH_UI_STYLE=ansi _zsh_ui_table --status 2 \
    $'Name\tState' $'alpha\tOK' $'beta\tbroken' $'gamma\t-'
)" || return 1
[[ "$styled_table" != *[╭╮╰╯│┼]* &&
   "$styled_table" == $'    \e[38;5;245mNAME\e[0m'* &&
   "$styled_table" == *$'\e[32mOK'* &&
   "$styled_table" == *$'\e[31mbroken'* &&
   "$styled_table" == *$'\e[38;5;240m-'* ]] || {
  print -u2 "FAIL: styled table drew a frame or lost its labels or status colors"
  return 1
}

# With --marker, rows lead with their status marker like report rows; the
# labels and a row whose word has no tone keep the place blank.
typeset marked_table
marked_table="$(
  ZSH_UI_STYLE=ansi _zsh_ui_table --marker 1 --status 1 \
    $'State\tName' $'ok\talpha' $'missing\tbeta' $'other\tgamma'
)" || return 1
typeset -a marked_lines=("${(@f)marked_table}")
[[ "${marked_lines[1]}" == $'      \e[38;5;245mSTATE'* &&
   "${marked_lines[2]}" == $'    \e[1;32m●\e[0m \e[32mok'* &&
   "${marked_lines[3]}" == $'    \e[1;31m✖\e[0m \e[31mmissing'* &&
   "${marked_lines[4]}" == '      other'* ]] || {
  print -u2 "FAIL: a marked table did not lead its rows with status markers"
  return 1
}
typeset toned_table
toned_table="$(
  ZSH_UI_STYLE=ansi _zsh_ui_table --tones ok,error --status 2 \
    $'Case\tVerdict' $'01.in\tPASSED' $'02.in\tTIMEOUT'
)" || return 1
marked_lines=("${(@f)toned_table}")
[[ "${marked_lines[1]}" == $'      \e[38;5;245mCASE'* &&
   "${marked_lines[2]}" == $'    \e[1;32m●\e[0m 01.in  \e[32mPASSED'* &&
   "${marked_lines[3]}" == $'    \e[1;31m✖\e[0m 02.in  \e[31mTIMEOUT'* ]] || {
  print -u2 "FAIL: explicit row tones did not set the markers and status colors"
  return 1
}
[[ "$(ZSH_UI_STYLE=plain _zsh_ui_table --marker 1 $'State\tName' $'ok\talpha')" == \
   $'STATE  NAME\nok     alpha' ]] || {
  print -u2 "FAIL: plain output drew table markers"
  return 1
}

# A table wider than the terminal gives up space from its widest column and
# keeps both ends of a path.
typeset fitted_table
fitted_table="$(
  COLUMNS=40 ZSH_UI_STYLE=ansi _zsh_ui_table $'Name\tPath' \
    $'tool\t/very/long/directory/that/cannot/fit/in/forty/columns/bin/tool'
)" || return 1
typeset table_line
for table_line in "${(@f)fitted_table}"; do
  _ui_strip "$table_line"
  (( ${(m)#REPLY} <= 40 )) || {
    print -u2 "FAIL: styled table overflowed a 40-column terminal"
    return 1
  }
done
[[ "$fitted_table" == *'/very/'*'…'*'/bin/tool'* ]] || {
  print -u2 "FAIL: path cell was not shortened in the middle"
  return 1
}

typeset definitions
definitions="$(
  ZSH_UI_STYLE=plain _zsh_ui_definition_list \
    $'short\tOne' $'longer-term\tTwo'
)" || return 1
[[ "$definitions" == $'  short        One\n  longer-term  Two' ]] || {
  print -u2 "FAIL: shared definition list did not align its descriptions"
  return 1
}
definitions="$(ZSH_UI_STYLE=ansi _zsh_ui_definition_list $'short\tOne')" ||
  return 1
[[ "$definitions" == $'    \e[36mshort\e[0m  \e[38;5;245mOne\e[0m' ]] || {
  print -u2 "FAIL: styled definition list is not one indent in"
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

typeset unsafe_styled
unsafe_styled="$(
  ZSH_UI_STYLE=ansi _zsh_ui_table $'Name\tValue' $'unsafe\tline\e[2J'
)" || return 1
[[ "$unsafe_styled" != *$'\e[2J'* ]] || {
  print -u2 "FAIL: styled table passed a control sequence through"
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
_ui_strip "$styled_rule"
[[ "$REPLY" == "  ${(pl:36::─:)}" &&
   "$styled_rule" == $'  \e[2;34m─'* ]] || {
  print -u2 "FAIL: default styled rule does not run from margin to margin"
  return 1
}

typeset styled_log
styled_log="$(ZSH_UI_STYLE=ansi _zsh_ui_log ok complete)" || return 1
[[ "$styled_log" == $'  \e[1;32m✓\e[0m complete' ]] || {
  print -u2 "FAIL: styled log line did not lead with its sign on the gutter"
  return 1
}

typeset plain_summary styled_summary
plain_summary="$(
  ZSH_UI_STYLE=plain _zsh_ui_summary --hint "apply installs 2" \
    $'ok\t3\tpresent' $'pending\t2\tmissing' $'error\t0\tconflict'
)" || return 1
[[ "$plain_summary" == "[INFO]  3 present, 2 missing; apply installs 2." ]] || {
  print -u2 "FAIL: plain summary changed: $plain_summary"
  return 1
}
styled_summary="$(
  COLUMNS=60 ZSH_UI_STYLE=ansi _zsh_ui_summary --hint "apply installs 2" \
    $'ok\t3\tpresent' $'pending\t2\tmissing'
)" || return 1
typeset -a summary_lines=("${(@f)styled_summary}")
_ui_strip "${summary_lines[1]}"
[[ "$REPLY" == "  ${(pl:56::─:)}" ]] || {
  print -u2 "FAIL: summary did not open with a rule across the content"
  return 1
}
_ui_strip "${summary_lines[2]}"
[[ "$REPLY" == "  ● 3 present   ▲ 2 missing"*"apply installs 2" ]] &&
  (( ${(m)#REPLY} == 58 )) || {
  print -u2 "FAIL: summary lost its markers or right-aligned hint"
  return 1
}

typeset styled_callout
styled_callout="$(
  COLUMNS=40 ZSH_UI_STYLE=ansi _zsh_ui_callout error "Needs a person" \
    "a reason long enough to wrap onto a second line of the notice"
)" || return 1
typeset -a callout_lines=("${(@f)styled_callout}")
(( ${#callout_lines} == 3 )) &&
  [[ "${callout_lines[1]}" == $'  \e[31m┃\e[0m \e[1mNeeds a person'* ]] || {
  print -u2 "FAIL: callout lost its bar, title, or wrapping"
  return 1
}
for card_line in "${callout_lines[@]}"; do
  _ui_strip "$card_line"
  (( ${(m)#REPLY} <= 40 )) || {
    print -u2 "FAIL: callout is wider than the terminal"
    return 1
  }
done

typeset styled_header
styled_header="$(
  COLUMNS=60 ZSH_UI_STYLE=ansi _zsh_ui_app_header tool Title Subtitle \
    context note
)" || return 1
typeset -a header_lines=("${(@f)styled_header}")
_ui_strip "${header_lines[2]}"
(( ${#header_lines} == 4 )) &&
  [[ "${header_lines[1]}" == $'\e[34m╭'* && "${header_lines[4]}" == $'\e[34m╰'* &&
     "$REPLY" == "│  TOOL   Title"*"context │" ]] &&
  (( ${(m)#REPLY} == 60 )) || {
  print -u2 "FAIL: masthead lost its frame, badge or right-aligned context"
  return 1
}
_ui_strip "${header_lines[3]}"
[[ "$REPLY" == "│"*" Subtitle"*"note │" ]] || {
  print -u2 "FAIL: masthead lost its subtitle line"
  return 1
}
[[ "$(ZSH_UI_STYLE=plain _zsh_ui_app_header tool Title Subtitle context)" == \
   $'tool · Title\nSubtitle · context' ]] || {
  print -u2 "FAIL: plain masthead dropped a part"
  return 1
}

typeset short_path
HOME=/home/tester ZSH_UI_STYLE=ansi \
  _zsh_ui_short_path "/home/tester/bin → /nix/store/abcdefghijklmnopqrstuvwxyz012345-cc/bin/cc"
short_path="$REPLY"
[[ "$short_path" == "~/bin → /nix/store/abcdefg…-cc/bin/cc" ]] || {
  print -u2 "FAIL: styled path shortening changed: $short_path"
  return 1
}
ZSH_UI_STYLE=plain _zsh_ui_short_path "/nix/store/abcdefghijklmnopqrstuvwxyz012345-cc"
[[ "$REPLY" == "/nix/store/abcdefghijklmnopqrstuvwxyz012345-cc" ]] || {
  print -u2 "FAIL: plain output shortened a path"
  return 1
}

if ZSH_UI_STYLE=plain _zsh_ui_confirm "Continue?" </dev/null 2>/dev/null; then
  print -u2 "FAIL: non-interactive confirmation did not fail safely"
  return 1
fi
# A default of yes only shapes the prompt; it never answers for a script.
if ZSH_UI_STYLE=plain _zsh_ui_confirm "Continue?" yes </dev/null 2>/dev/null
then
  print -u2 "FAIL: a yes default accepted without a terminal"
  return 1
fi
typeset -i confirm_status=0
ZSH_UI_STYLE=plain _zsh_ui_confirm "Continue?" maybe </dev/null 2>/dev/null ||
  confirm_status=$?
(( confirm_status == 2 )) || {
  print -u2 "FAIL: confirm accepted an invalid default"
  return 1
}
if ZSH_UI_STYLE=plain _zsh_ui_choose "Pick" one two </dev/null >/dev/null 2>&1
then
  print -u2 "FAIL: non-interactive choose picked an option"
  return 1
fi

# +++++++++++++++++++++++ FUNCTION SPINNER CONTRACT ++++++++++++++++++++++++++ #

_ui_spin_worker() {
  print -r -- "worker-output"
  return 5
}

# With stderr redirected there is nowhere to draw, so no Gum process may start
# and the label must not contaminate the captured standard output.
typeset spin_calls_before spin_output
typeset -i spin_status=0
spin_calls_before="$(_ui_gum_calls)"
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
[[ "$(_ui_gum_calls)" == "$spin_calls_before" ]] || {
  print -u2 "FAIL: function spinner spawned Gum with no terminal to draw on"
  return 1
}

# The Gum branch only runs with a real terminal on stderr, so it needs a pty.
# It is where a deadlock or a lost exit status would hide.
if zmodload zsh/zpty 2>/dev/null; then
  typeset spin_script
  spin_script="source ${(q)test_root}/scripts/_shared-helpers.zsh"
  spin_script+='; work() { /bin/sleep 0.3; print -r -- pty-payload; print -u2 -r -- pty-diagnostic; return 4 }'
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
  # A failure replays what the work wrote to stderr behind the spinner.
  [[ "$pty_buffer" == *"pty-diagnostic"* ]] || {
    print -u2 "FAIL: Gum spinner path dropped the failing work's diagnostics"
    return 1
  }
fi

print -r -- "PASS: shared UI modes, native rendering, and safe fallback"

# ============================================================================ #
# End of tests/tools/test-shared-ui.zsh
