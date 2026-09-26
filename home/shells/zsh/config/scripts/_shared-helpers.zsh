#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ SHARED SHELL HELPERS +++++++++++++++++++++++++++ #
# ============================================================================ #
# Common utility functions shared across zsh scripts.
#
# Provides terminal color initialization, leveled logging, and interactive
# confirmation prompts. Designed to be sourced by other scripts in this
# directory to eliminate code duplication.
#
# Usage:
#   source "${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts/_shared-helpers.zsh"
#
# Guard:
#   Re-sourcing is supported so real implementations can replace lazy stubs.
#
# Author: LCS-Dev-Ergos
# License: MIT
# ============================================================================ #

# Re-sourcing is intentionally allowed so real helper implementations can
# replace stale lazy-loader stubs after a shell reload.

_shared_runtime_helpers="${${(%):-%N}:A:h:h}/runtime-helpers.zsh"
if [[ -r "$_shared_runtime_helpers" ]]; then
  # shellcheck disable=SC1090
  source "$_shared_runtime_helpers"
else
  printf "[ERROR] Runtime helpers not found: %s\n" \
    "$_shared_runtime_helpers" >&2
  return 1 2>/dev/null || exit 1
fi
unset _shared_runtime_helpers

# +++++++++++++++++++++++++++++ SHARED UI LAYER ++++++++++++++++++++++++++++++ #
#
# Static output (headings, sections, tables, cards, and log lines) is drawn by
# the shell in every mode: it costs no process, never depends on a Gum release,
# and looks the same whether Gum is installed or not. Gum is kept for what it
# does better than a prompt string, confirmations and spinners. Colors are the
# terminal's own ANSI slots, so the output follows the terminal theme, and the
# geometry is shared with cpp-tools: a double/single rule for banners and
# rounded boxes for structured blocks.

# -----------------------------------------------------------------------------
# _zsh_ui_resolve_mode
# @internal
# @description Resolves the requested UI style into plain, ansi, or gum and
# stores it in REPLY. NO_COLOR and non-interactive auto mode select plain.
# @arg $1 string Optional style override: auto, plain, ansi, or gum.
# -----------------------------------------------------------------------------
_zsh_ui_resolve_mode() {
  emulate -L zsh
  local requested="${1:-${ZSH_UI_STYLE:-auto}}"

  if [[ -n "${NO_COLOR-}" ]]; then
    REPLY="plain"
    return 0
  fi

  case "$requested" in
    plain|ansi)
      REPLY="$requested"
      ;;
    gum)
      (( $+commands[gum] )) && REPLY="gum" || REPLY="ansi"
      ;;
    auto|"")
      if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
        (( $+commands[gum] )) && REPLY="gum" || REPLY="ansi"
      else
        REPLY="plain"
      fi
      ;;
    *)
      return 2
      ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_mode
# @internal
# @description Prints the effective shared UI style.
# @arg $1 string Optional style override: auto, plain, ansi, or gum.
# @exitcode 2 If the requested style is invalid.
# @stdout The resolved style: plain, ansi, or gum.
# -----------------------------------------------------------------------------
_zsh_ui_mode() {
  _zsh_ui_resolve_mode "${1:-${ZSH_UI_STYLE:-auto}}" || return $?
  print -r -- "$REPLY"
}

# -----------------------------------------------------------------------------
# _zsh_ui_set_palette
# @internal
# @description Sets private ANSI palette variables for a resolved UI mode.
# Titles are bold cyan, section labels and table headers bold blue, frames
# plain blue; secondary text keeps a neutral grey that stays readable on
# both dark and light themes.
# @arg $1 string Resolved style: plain, ansi, or gum.
# -----------------------------------------------------------------------------
_zsh_ui_set_palette() {
  emulate -L zsh
  local mode="$1"

  if [[ "$mode" == plain ]]; then
    typeset -g _ZSH_UI_RESET="" _ZSH_UI_BOLD="" _ZSH_UI_ACCENT=""
    typeset -g _ZSH_UI_HEADING="" _ZSH_UI_MUTED="" _ZSH_UI_BORDER=""
    typeset -g _ZSH_UI_KEY="" _ZSH_UI_INFO="" _ZSH_UI_OK=""
    typeset -g _ZSH_UI_WARN="" _ZSH_UI_ERROR=""
    return 0
  fi

  typeset -g _ZSH_UI_RESET=$'\e[0m'
  typeset -g _ZSH_UI_BOLD=$'\e[1m'
  typeset -g _ZSH_UI_ACCENT=$'\e[1;36m'
  typeset -g _ZSH_UI_HEADING=$'\e[1;34m'
  typeset -g _ZSH_UI_MUTED=$'\e[38;5;245m'
  typeset -g _ZSH_UI_BORDER=$'\e[34m'
  typeset -g _ZSH_UI_KEY=$'\e[36m'
  typeset -g _ZSH_UI_INFO=$'\e[1;36m'
  typeset -g _ZSH_UI_OK=$'\e[1;32m'
  typeset -g _ZSH_UI_WARN=$'\e[1;33m'
  typeset -g _ZSH_UI_ERROR=$'\e[1;31m'
}

# -----------------------------------------------------------------------------
# _zsh_ui_width
# @internal
# @description Stores the terminal width, clamped to a readable range, in
# REPLY. Banners and cards use it; tables fit the full terminal instead.
# @arg $1 integer Optional upper bound; defaults to 100.
# -----------------------------------------------------------------------------
_zsh_ui_width() {
  emulate -L zsh
  local -i width="${COLUMNS:-80}" limit="${1:-100}"
  (( width > 0 )) || width=80
  (( width < 40 )) && width=40
  (( width > limit )) && width=limit
  REPLY=$width
}

# -----------------------------------------------------------------------------
# _zsh_ui_text_width
# @internal
# @description Stores the display width of a string in REPLY, ignoring SGR
# color sequences and counting double-width characters twice.
# @arg $1 string Text to measure.
# -----------------------------------------------------------------------------
_zsh_ui_text_width() {
  emulate -L zsh
  setopt localoptions extendedglob
  local text="${1//$'\e'\[[0-9;]#m/}"
  REPLY=${(m)#text}
}

# -----------------------------------------------------------------------------
# _zsh_ui_truncate
# @internal
# @description Shortens text to a display width with an ellipsis. Paths lose
# their middle, so both the root and the file name stay visible; other text
# loses its end.
# @arg $1 string Text to shorten.
# @arg $2 integer Maximum display width.
# -----------------------------------------------------------------------------
_zsh_ui_truncate() {
  emulate -L zsh
  local text="$1"
  local -i width="$2" head tail

  if (( ${(m)#text} <= width )); then
    REPLY="$text"
    return 0
  fi
  if (( width < 2 )); then
    REPLY="${text[1,width]}"
    return 0
  fi

  # "link → target" keeps its arrow: each side is shortened on its own, and
  # space one side does not need goes to the other.
  if [[ "$text" == *" → "* ]] && (( width >= 11 )); then
    local left="${text%% → *}" right="${text#* → }"
    local -i left_budget=$(( (width - 3) / 2 )) right_budget
    right_budget=$(( width - 3 - left_budget ))
    (( ${(m)#left} < left_budget )) &&
      (( right_budget += left_budget - ${(m)#left} ))
    (( ${(m)#right} < right_budget )) &&
      (( left_budget += right_budget - ${(m)#right} ))
    _zsh_ui_truncate "$left" "$left_budget"
    left="$REPLY"
    _zsh_ui_truncate "$right" "$right_budget"
    REPLY="$left → $REPLY"
    return 0
  fi

  tail=$(( (width - 1) * 3 / 5 ))
  head=$(( width - 1 - tail ))
  if [[ "$text" == */* ]] && (( head > 0 && tail > 0 )); then
    REPLY="${text[1,head]}…${text[-tail,-1]}"
  else
    REPLY="${text[1,width-1]}…"
  fi
}

# -----------------------------------------------------------------------------
# _zsh_ui_short_path
# @internal
# @description Stores the display form of a path, or of text containing
# paths, in REPLY. Styled output writes $HOME as ~ and cuts Nix store hashes
# to seven characters; plain output keeps every path intact, so a captured
# report can still be copied from.
# @arg $1 string Path or text.
# -----------------------------------------------------------------------------
_zsh_ui_short_path() {
  emulate -L zsh
  setopt localoptions extendedglob
  local text="$1"

  if _zsh_ui_resolve_mode && [[ "$REPLY" != plain ]]; then
    [[ -n "${HOME-}" && "$HOME" != / ]] && text="${text//$HOME\//~/}"
    text="${text//(#b)\/nix\/store\/([a-z0-9](#c7))[a-z0-9](#c25)-//nix/store/${match[1]}…-}"
  fi
  REPLY="$text"
}

# -----------------------------------------------------------------------------
# _zsh_ui_status_style
# @internal
# @description Stores the palette color for a status word in REPLY: green
# for healthy states, yellow for ones worth a look, red for failures, grey
# for informational ones, and nothing for anything else. Only the first word
# counts, so "Warning: resolves to Clang" reads as a warning.
# @arg $1 string Cell text.
# -----------------------------------------------------------------------------
_zsh_ui_status_style() {
  emulate -L zsh
  local word="${(L)1}"
  word="${word%%[^a-z]*}"

  case "$word" in
    ok|available|reachable|pass|passed|active|loaded|installed|ready|\
clean|current|verified|enabled|done|success)
      REPLY="$_ZSH_UI_OK" ;;
    warn|warning|outdated|lazy|shadowed|unknown|partial|stale|pending|\
degraded|skipped|changed)
      REPLY="$_ZSH_UI_WARN" ;;
    broken|error|fail|failed|failure|missing|invalid|unreachable|conflict)
      REPLY="$_ZSH_UI_ERROR" ;;
    dormant|unused|absent|disabled|inactive|none)
      REPLY="$_ZSH_UI_MUTED" ;;
    *)
      REPLY="" ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_log
# @internal
# @description Prints a compact leveled log line; warn and error go to stderr.
# @arg $1 string Level: info, ok, warn, or error.
# @arg $@ string Message text.
# @exitcode 2 If the level or ZSH_UI_STYLE value is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_log() {
  emulate -L zsh
  local level="$1"
  shift
  local message="$*"
  _zsh_ui_sanitize_text "$message"
  message="$REPLY"
  _zsh_ui_resolve_mode || return $?
  _zsh_ui_set_palette "$REPLY"

  case "$level" in
    info)
      printf '%s[INFO]%s  %s\n' \
        "$_ZSH_UI_INFO" "$_ZSH_UI_RESET" "$message"
      ;;
    ok)
      printf '%s[OK]%s    %s\n' \
        "$_ZSH_UI_OK" "$_ZSH_UI_RESET" "$message"
      ;;
    warn)
      printf '%s[WARN]%s  %s\n' \
        "$_ZSH_UI_WARN" "$_ZSH_UI_RESET" "$message" >&2
      ;;
    error)
      printf '%s[ERROR]%s %s\n' \
        "$_ZSH_UI_ERROR" "$_ZSH_UI_RESET" "$message" >&2
      ;;
    *)
      return 2
      ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_rule
# @internal
# @description Prints a horizontal rule clamped to a practical width; the
# default character matches the resolved plain or styled UI mode.
# @arg $1 string Optional rule character.
# @arg $2 integer Optional explicit width; defaults to COLUMNS.
# -----------------------------------------------------------------------------
_zsh_ui_rule() {
  emulate -L zsh
  local char="${1:-}"
  _zsh_ui_resolve_mode || return $?
  _zsh_ui_set_palette "$REPLY"
  if [[ -z "$char" ]]; then
    char="-"
    [[ "$REPLY" == plain ]] || char="─"
  fi
  local -i width="${2:-${COLUMNS:-80}}"
  (( width > 0 )) || width=80
  (( width < 40 )) && width=40
  (( width > 240 )) && width=240
  print -r -- "${_ZSH_UI_BORDER}${(pl:$width::$char:)}${_ZSH_UI_RESET}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_heading
# @internal
# @description Prints a title banner and an optional subtitle. Styled output
# draws the cpp-tools rule, `════────── Title ───…───════`, with the subtitle
# aligned under the title; plain output is the two bare lines.
# @arg $1 string Title text.
# @arg $2 string Optional subtitle text.
# -----------------------------------------------------------------------------
_zsh_ui_heading() {
  emulate -L zsh
  _zsh_ui_sanitize_text "$1"
  local title="$REPLY"
  _zsh_ui_sanitize_text "${2:-}"
  local subtitle="$REPLY"

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  if [[ "$mode" == plain ]]; then
    print -r -- "$title"
    [[ -z "$subtitle" ]] || print -r -- "$subtitle"
    return 0
  fi

  _zsh_ui_width
  local -i width=$REPLY
  local -i fill=$(( width - 16 - ${(m)#title} ))
  if (( fill < 2 )); then
    print -r -- "${_ZSH_UI_ACCENT}${title}${_ZSH_UI_RESET}"
  else
    print -r -- "${_ZSH_UI_BORDER}════──────${_ZSH_UI_RESET}"\
" ${_ZSH_UI_ACCENT}${title}${_ZSH_UI_RESET} "\
"${_ZSH_UI_BORDER}${(pl:$fill::─:)}════${_ZSH_UI_RESET}"
  fi
  [[ -z "$subtitle" ]] ||
    print -r -- "           ${_ZSH_UI_MUTED}${subtitle}${_ZSH_UI_RESET}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_app_header
# @internal
# @description Prints the title bar of a report-style tool. Styled output draws
# a rounded box: the tool name as a reverse-video badge, the title beside it
# and context on the right, then a secondary line with its own right-aligned
# note. Plain output is "TAG · Title" and the subtitle, like _zsh_ui_heading.
# @arg $1 string Tool name shown as the badge.
# @arg $2 string Title.
# @arg $3 string Optional subtitle, under the title.
# @arg $4 string Optional context, right-aligned on the title line.
# @arg $5 string Optional note, right-aligned on the subtitle line.
# -----------------------------------------------------------------------------
_zsh_ui_app_header() {
  emulate -L zsh
  local -a parts=()
  local part
  for part in "$@"; do
    _zsh_ui_sanitize_text "$part"
    parts+=("$REPLY")
  done
  local tag="${parts[1]:-}" title="${parts[2]:-}" subtitle="${parts[3]:-}"
  local context="${parts[4]:-}" note="${parts[5]:-}"

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  if [[ "$mode" == plain ]]; then
    print -r -- "${tag:+$tag · }$title"
    [[ -z "$subtitle" ]] || print -r -- "$subtitle"
    return 0
  fi

  _zsh_ui_width 120
  local -i inner=$(( REPLY - 4 ))
  local badge=" ${(U)tag} "
  local -i indent=$(( ${(m)#badge} + 2 ))
  local border="$_ZSH_UI_BORDER" reset="$_ZSH_UI_RESET"

  # Context yields to the title, then the title yields to the frame.
  local -i room=$(( inner - indent - ${(m)#title} - 2 ))
  (( ${(m)#context} > room )) && context=""
  _zsh_ui_truncate "$title" $(( inner - indent ))
  title="$REPLY"
  room=$(( inner - indent - ${(m)#subtitle} - 2 ))
  (( ${(m)#note} > room )) && note=""
  _zsh_ui_truncate "$subtitle" $(( inner - indent ))
  subtitle="$REPLY"

  local -i gap1=$(( inner - indent - ${(m)#title} - ${(m)#context} ))
  local -i gap2=$(( inner - indent - ${(m)#subtitle} - ${(m)#note} ))
  print -r -- "${border}╭${(pl:$(( inner + 2 ))::─:)}╮${reset}"
  print -r -- "${border}│${reset} ${_ZSH_UI_ACCENT}"$'\e[7m'"${badge}${reset}"\
"  ${_ZSH_UI_BOLD}${title}${reset}${(l:$gap1:: :)}${_ZSH_UI_MUTED}${context}${reset}"\
" ${border}│${reset}"
  print -r -- "${border}│${reset} ${(l:$indent:: :)}${_ZSH_UI_MUTED}${subtitle}${reset}"\
"${(l:$gap2:: :)}${_ZSH_UI_MUTED}${note}${reset} ${border}│${reset}"
  print -r -- "${border}╰${(pl:$(( inner + 2 ))::─:)}╯${reset}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_status_glyph
# @internal
# @description Stores a one-cell marker for a status word in REPLY and its
# palette color in reply[1]: a filled dot for healthy states, a triangle or
# diamond for ones worth a look, a cross for failures, and a hollow dot for
# informational ones. Plain output uses ASCII markers.
# @arg $1 string Status word.
# -----------------------------------------------------------------------------
_zsh_ui_status_glyph() {
  emulate -L zsh
  local word="${(L)1}"
  _zsh_ui_status_style "$word"
  local color="$REPLY"
  _zsh_ui_resolve_mode || return $?
  if [[ "$REPLY" == plain ]]; then
    case "$word" in
      broken|error|fail|failed|missing) REPLY="x" ;;
      outdated|shadowed|unknown|warn|warning) REPLY="!" ;;
      dormant|unused|absent|disabled|inactive) REPLY="-" ;;
      *) REPLY="*" ;;
    esac
    reply=("")
    return 0
  fi
  case "$word" in
    broken|error|fail|failed|missing) REPLY="✖" ;;
    outdated) REPLY="▲" ;;
    shadowed) REPLY="◆" ;;
    unknown|warn|warning) REPLY="?" ;;
    dormant) REPLY="◐" ;;
    unused|absent|disabled|inactive) REPLY="○" ;;
    *) REPLY="●" ;;
  esac
  reply=("$color")
}

# -----------------------------------------------------------------------------
# _zsh_ui_section
# @internal
# @description Prints a section label. A " · " suffix, such as a count, is
# rendered as secondary text.
# @arg $1 string Section title.
# -----------------------------------------------------------------------------
_zsh_ui_section() {
  emulate -L zsh
  _zsh_ui_sanitize_text "$1"
  local title="$REPLY" detail=""
  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  if [[ "$mode" == plain ]]; then
    print -r -- "$title"
    return 0
  fi
  if [[ "$title" == *" · "* ]]; then
    detail=" · ${title#* · }"
    title="${title%% · *}"
  fi
  print -r -- "${_ZSH_UI_BORDER}──${_ZSH_UI_RESET} "\
"${_ZSH_UI_HEADING}${title}${_ZSH_UI_RESET}"\
"${_ZSH_UI_MUTED}${detail}${_ZSH_UI_RESET}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_subsection
# @internal
# @description Renders a section label and the short, indented divider used by
# the zfuncs catalog. The divider adapts to the label and available width.
# @arg $1 string Section title.
# @arg $2 integer Optional available width; defaults to COLUMNS or 80.
# @exitcode 2 If the title is missing, width is invalid, or UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_subsection() {
  emulate -L zsh
  (( $# )) || return 2

  local title="$1"
  local available_width="${2:-${COLUMNS:-80}}"
  [[ "$available_width" == <-> ]] || return 2
  (( available_width > 0 )) || available_width=80

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  local rule_character="-"
  [[ "$mode" == plain ]] || rule_character="─"
  local -i rule_width=$(( ${#title} + 4 ))
  (( rule_width < 24 )) && rule_width=24
  (( rule_width > 48 )) && rule_width=48
  (( rule_width > available_width - 2 )) &&
    rule_width=$(( available_width - 2 ))
  (( rule_width < 1 )) && rule_width=1

  print -r -- "${_ZSH_UI_HEADING}${title}${_ZSH_UI_RESET}"
  print -r -- \
    "  ${_ZSH_UI_BORDER}${(pl:$rule_width::$rule_character:)}${_ZSH_UI_RESET}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_wrap
# @internal
# @description Word-wraps text to a display width into the reply array. A word
# longer than the width is split rather than allowed to overflow.
# @arg $1 integer Display width.
# @arg $2 string Text to wrap.
# -----------------------------------------------------------------------------
_zsh_ui_wrap() {
  emulate -L zsh
  local -i width="$1"
  local text="$2" word line=""
  reply=()
  (( width > 0 )) || width=1

  _zsh_ui_text_width "$text"
  if (( REPLY <= width )); then
    reply=("$text")
    return 0
  fi

  for word in ${=text}; do
    while (( ${(m)#word} > width )); do
      [[ -z "$line" ]] || { reply+=("$line"); line="" }
      reply+=("${word[1,width]}")
      word="${word[width+1,-1]}"
    done
    [[ -n "$word" ]] || continue
    if [[ -z "$line" ]]; then
      line="$word"
    elif (( ${(m)#line} + 1 + ${(m)#word} <= width )); then
      line+=" $word"
    else
      reply+=("$line")
      line="$word"
    fi
  done
  [[ -z "$line" ]] || reply+=("$line")
  (( ${#reply} )) || reply=("")
}

# -----------------------------------------------------------------------------
# _zsh_ui_card
# @internal
# @description Prints a compact information block. Body lines of the form
# "key<TAB>value" become an aligned key/value list, empty lines stay as
# spacing, and any other line is free text. Styled output draws a rounded box
# sized to its content with the title set into the top border; long lines wrap
# inside it. Free text may carry palette escapes from trusted callers.
# @arg $1 string Card title.
# @arg $@ string Optional body lines.
# -----------------------------------------------------------------------------
_zsh_ui_card() {
  emulate -L zsh
  setopt localoptions extendedglob
  _zsh_ui_sanitize_text "$1"
  local title="$REPLY"
  shift

  local line key value
  local -i key_width=0
  for line in "$@"; do
    [[ "$line" == *$'\t'* ]] || continue
    key="${line%%$'\t'*}"
    (( ${(m)#key} > key_width )) && key_width=${(m)#key}
  done

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  if [[ "$mode" == plain ]]; then
    print -r -- "$title"
    (( $# == 0 )) || print -r -- ""
    for line in "$@"; do
      if [[ "$line" == *$'\t'* ]]; then
        key="${line%%$'\t'*}"
        printf '%s%*s  %s\n' "$key" $(( key_width - ${(m)#key} )) "" \
          "${line#*$'\t'}"
      else
        print -r -- "$line"
      fi
    done
    return 0
  fi

  _zsh_ui_width
  local -i max_inner=$(( REPLY - 6 )) inner=0 value_width
  for line in "$@"; do
    if [[ "$line" == *$'\t'* ]]; then
      _zsh_ui_text_width "${line#*$'\t'}"
      (( REPLY += key_width + 2 ))
    else
      _zsh_ui_text_width "$line"
    fi
    (( REPLY > inner )) && inner=$REPLY
  done
  (( ${(m)#title} + 1 > inner )) && inner=$(( ${(m)#title} + 1 ))
  (( inner < 30 )) && inner=30
  (( inner > max_inner )) && inner=max_inner
  _zsh_ui_truncate "$title" $(( inner - 1 ))
  title="$REPLY"

  local border="$_ZSH_UI_BORDER" reset="$_ZSH_UI_RESET"
  local -a body=() wrapped
  local -i index
  for line in "$@"; do
    if [[ "$line" == *$'\t'* ]]; then
      key="${line%%$'\t'*}"
      value="${line#*$'\t'}"
      value_width=$(( inner - key_width - 2 ))
      _zsh_ui_wrap "$value_width" "$value"
      wrapped=("${reply[@]}")
      body+=("${_ZSH_UI_KEY}${key}${reset}${(l:$(( key_width - ${(m)#key} + 2 )):: :)}${wrapped[1]}")
      for (( index = 2; index <= ${#wrapped}; index++ )); do
        body+=("${(l:$(( key_width + 2 )):: :)}${wrapped[index]}")
      done
    elif [[ -z "$line" ]]; then
      body+=("")
    else
      _zsh_ui_wrap "$inner" "$line"
      body+=("${reply[@]}")
    fi
  done

  print -r -- "${border}╭─${reset} ${_ZSH_UI_ACCENT}${title}${reset} "\
"${border}${(pl:$(( inner + 1 - ${(m)#title} ))::─:)}╮${reset}"
  for line in "${body[@]}"; do
    _zsh_ui_text_width "$line"
    print -r -- "${border}│${reset}  ${line}${reset}"\
"${(l:$(( inner - REPLY )):: :)}  ${border}│${reset}"
  done
  print -r -- "${border}╰${(pl:$(( inner + 4 ))::─:)}╯${reset}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_sanitize_text
# @internal
# @description Escapes terminal control characters in untrusted display text.
# Stores the printable result in REPLY.
# @arg $1 string Text to sanitize.
# -----------------------------------------------------------------------------
_zsh_ui_sanitize_text() {
  emulate -L zsh
  local value="$1"
  # Almost every value is already printable; skip the per-character walk.
  if [[ "$value" != *[[:cntrl:]]* ]]; then
    REPLY="$value"
    return 0
  fi

  local output="" char escaped
  local -i index code

  for (( index = 1; index <= ${#value}; index++ )); do
    char="${value[$index]}"
    case "$char" in
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      [[:cntrl:]])
        printf -v code '%d' "'$char"
        printf -v escaped '\\x%02x' "$code"
        output+="$escaped"
        ;;
      *) output+="$char" ;;
    esac
  done
  REPLY="$output"
}

# -----------------------------------------------------------------------------
# _zsh_ui_table
# @internal
# @description Renders tab-separated rows as a table. Styled output draws a
# rounded frame with a bold header and fits the terminal: the widest columns
# give up space first and their cells are shortened with an ellipsis (paths
# in the middle). Plain output stays an unframed, untruncated, aligned layout
# that is safe to capture. "-" cells are dimmed in every styled table.
# @option --align <spec> One letter per column, l or r; defaults to l.
# @option --status <n[,n]> Columns whose status words are colored.
# @option --width <n> Width to fit instead of COLUMNS.
# @arg $1 string Tab-separated column headings.
# @arg $@ string Tab-separated data rows.
# @exitcode 2 If the header is missing, an option is invalid, or the UI style
# is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_table() {
  emulate -L zsh
  local align="" status_spec=""
  local -i limit=0

  while [[ "${1-}" == --* ]]; do
    case "$1" in
      --align|--status|--width)
        (( $# >= 2 )) || return 2
        case "$1" in
          --align) align="$2" ;;
          --status) status_spec="$2" ;;
          --width) [[ "$2" == <1-> ]] || return 2; limit=$2 ;;
        esac
        shift 2
        ;;
      --) shift; break ;;
      *) return 2 ;;
    esac
  done
  (( $# )) || return 2

  local -a columns=() cells=() fields=() widths=() aligns=()
  local -A status_columns=()
  local field row
  local -i ncols nrows c r index

  for field in "${(@ps:\t:)1}"; do
    _zsh_ui_sanitize_text "$field"
    columns+=("$REPLY")
  done
  shift
  ncols=${#columns}
  nrows=$#
  for field in "${(@s:,:)status_spec}"; do
    [[ "$field" == <1-> ]] && status_columns[$field]=1
  done

  for (( c = 1; c <= ncols; c++ )); do
    widths[c]=${(m)#columns[c]}
    aligns[c]="${align[c]:-l}"
  done
  for row in "$@"; do
    fields=("${(@ps:\t:)row}")
    for (( c = 1; c <= ncols; c++ )); do
      _zsh_ui_sanitize_text "${fields[c]-}"
      cells+=("$REPLY")
      (( ${(m)#REPLY} > widths[c] )) && widths[c]=${(m)#REPLY}
    done
  done

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  local line text pad
  if [[ "$mode" == plain ]]; then
    for (( r = 0; r <= nrows; r++ )); do
      line=""
      for (( c = 1; c <= ncols; c++ )); do
        if (( r == 0 )); then
          text="${columns[c]}"
        else
          text="${cells[(r - 1) * ncols + c]}"
        fi
        pad="${(l:$(( widths[c] - ${(m)#text} )):: :)}"
        if [[ "${aligns[c]}" == r ]]; then
          text="$pad$text"
        elif (( c < ncols )); then
          text+="$pad"
        fi
        (( c > 1 )) && line+="  "
        line+="$text"
      done
      print -r -- "$line"
    done
    return 0
  fi

  # Shrink the widest column one step at a time until the frame fits. A
  # column never drops below its heading or 8 cells, whichever is smaller
  # than its content; a table that still overflows is left to wrap.
  local -i available="${limit:-0}" total=1 excess best widest
  (( available > 0 )) || available="${COLUMNS:-80}"
  for (( c = 1; c <= ncols; c++ )); do
    (( total += widths[c] + 3 ))
  done
  if (( total > available )); then
    local -a floors=()
    for (( c = 1; c <= ncols; c++ )); do
      floors[c]=${(m)#columns[c]}
      (( floors[c] < 8 )) && floors[c]=8
      (( floors[c] > widths[c] )) && floors[c]=${widths[c]}
    done
    excess=$(( total - available ))
    while (( excess > 0 )); do
      best=0 widest=0
      for (( c = 1; c <= ncols; c++ )); do
        if (( widths[c] > floors[c] && widths[c] > widest )); then
          widest=${widths[c]}
          best=$c
        fi
      done
      (( best )) || break
      (( widths[best]--, excess-- ))
    done
  fi

  local border="$_ZSH_UI_BORDER" reset="$_ZSH_UI_RESET"
  local top="╭" middle="├" bottom="╰" segment style
  for (( c = 1; c <= ncols; c++ )); do
    segment="${(pl:$(( widths[c] + 2 ))::─:)}"
    top+="$segment" middle+="$segment" bottom+="$segment"
    if (( c < ncols )); then
      top+="┬" middle+="┼" bottom+="┴"
    fi
  done

  print -r -- "${border}${top}╮${reset}"
  for (( r = 0; r <= nrows; r++ )); do
    line="${border}│${reset}"
    for (( c = 1; c <= ncols; c++ )); do
      if (( r == 0 )); then
        text="${columns[c]}"
      else
        text="${cells[(r - 1) * ncols + c]}"
      fi
      _zsh_ui_truncate "$text" "${widths[c]}"
      text="$REPLY"
      pad="${(l:$(( widths[c] - ${(m)#text} )):: :)}"

      style=""
      if (( r == 0 )); then
        style="$_ZSH_UI_HEADING"
      elif [[ "$text" == (-|—) ]]; then
        style="$_ZSH_UI_MUTED"
      elif (( ${+status_columns[$c]} )); then
        _zsh_ui_status_style "$text"
        style="$REPLY"
      fi
      [[ -z "$style" ]] || text="${style}${text}${reset}"

      if [[ "${aligns[c]}" == r ]]; then
        line+=" ${pad}${text} ${border}│${reset}"
      else
        line+=" ${text}${pad} ${border}│${reset}"
      fi
    done
    print -r -- "$line"
    (( r == 0 )) && print -r -- "${border}${middle}┤${reset}"
  done
  print -r -- "${border}${bottom}╯${reset}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_definition_list
# @internal
# @description Renders tab-separated terms and descriptions as an aligned,
# indented list. Styling stays shell-native in every mode, so help menus do
# not spawn one Gum process per section.
# @arg $@ string Tab-separated term and description rows.
# @exitcode 2 If the UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_definition_list() {
  emulate -L zsh
  (( $# )) || return 0

  local -a terms=() descriptions=()
  local row term description
  local -i width=0 index

  for row in "$@"; do
    term="${row%%$'\t'*}"
    if [[ "$row" == *$'\t'* ]]; then
      description="${row#*$'\t'}"
    else
      description=""
    fi
    _zsh_ui_sanitize_text "$term"
    term="$REPLY"
    _zsh_ui_sanitize_text "$description"
    description="$REPLY"
    terms+=("$term")
    descriptions+=("$description")
    (( ${#term} > width )) && width=${#term}
  done

  _zsh_ui_resolve_mode || return $?
  _zsh_ui_set_palette "$REPLY"
  for (( index = 1; index <= ${#terms[@]}; index++ )); do
    if [[ -n "${descriptions[$index]}" ]]; then
      printf '  %s%-*s%s  %s%s%s\n' \
        "$_ZSH_UI_INFO" "$width" "${terms[$index]}" "$_ZSH_UI_RESET" \
        "$_ZSH_UI_MUTED" "${descriptions[$index]}" "$_ZSH_UI_RESET"
    else
      printf '  %s%s%s\n' \
        "$_ZSH_UI_INFO" "${terms[$index]}" "$_ZSH_UI_RESET"
    fi
  done
}

# -----------------------------------------------------------------------------
# _zsh_ui_confirm
# @internal
# @description Requests confirmation with Gum when useful, otherwise a native
# y/N prompt; non-interactive input fails safely.
# @arg $1 string Optional prompt text; defaults to "Continue?".
# @exitcode 1 If stdin is not a tty or the user declines.
# -----------------------------------------------------------------------------
_zsh_ui_confirm() {
  emulate -L zsh
  _zsh_ui_sanitize_text "${1:-Continue?}"
  local prompt="$REPLY"
  local reply

  if [[ ! -t 0 ]]; then
    _zsh_ui_log error "Cannot prompt: stdin is not a terminal."
    return 1
  fi

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum && -t 1 ]]; then
    GUM_CONFIRM_PROMPT_FOREGROUND=6 \
      GUM_CONFIRM_SELECTED_BACKGROUND=4 \
      command gum confirm --default=false "$prompt"
    return $?
  fi

  _zsh_ui_set_palette "$mode"
  printf '%s?%s %s %s[y/N]%s ' \
    "$_ZSH_UI_ACCENT" "$_ZSH_UI_RESET" "$prompt" \
    "$_ZSH_UI_MUTED" "$_ZSH_UI_RESET"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_spinner
# @internal
# @description Runs a command under one Gum spinner on a tty, or logs the label
# once and runs it directly in other modes.
# @arg $1 string Progress label.
# @arg $@ command Command and arguments to execute.
# @exitcode 2 If no command is provided or the UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_spinner() {
  emulate -L zsh
  local label="$1"
  shift
  (( $# )) || return 2

  _zsh_ui_resolve_mode || return $?
  if [[ "$REPLY" == gum && -t 1 && -t 2 ]]; then
    GUM_SPIN_SPINNER_FOREGROUND=6 \
      command gum spin --spinner dot --title "$label" -- "$@"
  else
    _zsh_ui_log info "$label"
    command "$@"
  fi
}

# -----------------------------------------------------------------------------
# _zsh_ui_spinner_fn
# @internal
# @description Runs a shell function under one Gum spinner, buffering its
# standard output and replaying it once the work finishes. _zsh_ui_spinner can
# only run external commands, and it drops the spinner whenever standard output
# is redirected; Gum draws the spinner on standard error, so this variant keeps
# it for work whose output the caller captures.
# @arg $1 string Progress label.
# @arg $@ command Function or command, and its arguments, to execute.
# @exitcode 2 If no command is provided or the UI style is invalid.
# @stdout Whatever the command wrote to standard output. The command's standard
# error is discarded while a spinner is drawn, because it would corrupt it.
# -----------------------------------------------------------------------------
_zsh_ui_spinner_fn() {
  emulate -L zsh
  setopt localoptions no_aliases no_monitor no_notify extendedglob
  local label="$1"
  shift
  (( $# )) || return 2

  _zsh_ui_resolve_mode || return $?
  # Only a non-terminal stderr rules the spinner out; a captured stdout does
  # not, because that is not where Gum draws. For the same reason the fallback
  # label goes to stderr: stdout belongs to the command.
  if [[ "$REPLY" != gum || ! -t 2 ]]; then
    _zsh_ui_log info "$label" >&2
    "$@"
    return $?
  fi

  local work_dir
  work_dir="$(command mktemp -d "${TMPDIR:-/tmp}/zsh-ui-spin.XXXXXX")" || {
    _zsh_ui_log info "$label" >&2
    "$@"
    return $?
  }

  local out_file="$work_dir/output"
  local status_file="$work_dir/status"
  local -i worker_pid worker_status

  { "$@" >| "$out_file" 2>/dev/null; print -r -- $? >| "$status_file" } &
  worker_pid=$!

  # The waiter polls a status file rather than the pid: it survives a reaped
  # child and cannot latch onto a recycled pid.
  GUM_SPIN_SPINNER_FOREGROUND=6 \
    command gum spin --spinner dot --title "$label" -- \
    /bin/sh -c 'until [ -s "$1" ]; do sleep 0.2; done' spin "$status_file" \
    >/dev/null 2>&1

  # `wait` reports the status of the subshell's last command, which is the
  # bookkeeping `print`, never the worker's own. The status file is the only
  # honest source.
  wait "$worker_pid" 2>/dev/null
  worker_status=1
  if [[ -s "$status_file" ]]; then
    local recorded
    recorded="$(<"$status_file")"
    [[ "$recorded" == [0-9]## ]] && worker_status=$recorded
  fi

  command cat -- "$out_file" 2>/dev/null
  command rm -rf -- "$work_dir" 2>/dev/null
  return $worker_status
}

# ++++++++++++++++++++++++++++++ COLOR HANDLING ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_init_colors
# @internal
# @description Sets C_* color variables, empty when output is not a tty.
# @noargs
# -----------------------------------------------------------------------------
_shared_init_colors() {
  _zsh_init_colors
  if [[ -n "${NO_COLOR-}" ]]; then
    C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW=""
    C_BLUE="" C_MAGENTA="" C_CYAN=""
  fi
}

# ++++++++++++++++++++++++++++ LOGGING UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_log
# @internal
# @description Prints a leveled, color-coded log line; warn/error go to stderr.
# @arg $1 string Level: info, ok, warn, or error.
# @arg $@ string Message text.
# -----------------------------------------------------------------------------
_shared_log() {
  _zsh_ui_log "$@"
}

# -----------------------------------------------------------------------------
# _shared_rule
# @internal
# @description Prints a horizontal rule sized to the terminal width.
# @arg $1 string Optional rule character; defaults to "-".
# -----------------------------------------------------------------------------
_shared_rule() {
  _zsh_ui_rule "$@"
}

# -----------------------------------------------------------------------------
# _shared_banner
# @internal
# @description Prints the shared title banner followed by a blank line.
# @arg $1 string Title text.
# @arg $2 string Optional subtitle text.
# -----------------------------------------------------------------------------
_shared_banner() {
  _zsh_ui_heading "$1" "${2:-}" || return $?
  print -r -- ""
}

# -----------------------------------------------------------------------------
# _shared_section
# @internal
# @description Prints a section label.
# @arg $1 string Section title.
# -----------------------------------------------------------------------------
_shared_section() {
  _zsh_ui_section "$1"
}

# +++++++++++++++++++++++++++++ PLATFORM HELPERS ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_detect_platform
# @internal
# @description Detects the OS and Linux distribution; idempotent once cached.
# @noargs
# @set SHARED_PLATFORM string Detected platform: macOS, Linux, or Other.
# @set SHARED_DISTRO string Linux distro name (e.g. Arch); empty elsewhere.
# -----------------------------------------------------------------------------
_shared_detect_platform() {
  if [[ -n "${SHARED_PLATFORM:-}" ]]; then
    return 0
  fi

  if [[ -n "${PLATFORM:-}" ]]; then
    SHARED_PLATFORM="$PLATFORM"
  else
    _zsh_detect_platform
    SHARED_PLATFORM="$PLATFORM"
  fi

  SHARED_DISTRO=""
  if [[ "$SHARED_PLATFORM" == "Linux" ]]; then
    if [[ "${ARCH_LINUX:-false}" == true || -f "/etc/arch-release" ]]; then
      SHARED_DISTRO="Arch"
    elif command -v lsb_release >/dev/null 2>&1; then
      SHARED_DISTRO=$(lsb_release -si 2>/dev/null || printf "")
    fi
  fi
}

# -----------------------------------------------------------------------------
# _shared_platform_pretty
# @internal
# @description Prints a human-readable platform string, e.g. "Linux (Arch)".
# @noargs
# @stdout The platform string.
# -----------------------------------------------------------------------------
_shared_platform_pretty() {
  _shared_detect_platform
  if [[ "${SHARED_PLATFORM:-}" == "Linux" && -n "${SHARED_DISTRO:-}" ]]; then
    printf "Linux (%s)\n" "$SHARED_DISTRO"
  else
    printf "%s\n" "${SHARED_PLATFORM:-unknown}"
  fi
}

# ++++++++++++++++++++++++++++ VALIDATION HELPERS +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_is_bool
# @internal
# @description Checks whether a value is the literal string "true" or "false".
# @arg $1 string Value to validate.
# @exitcode 1 If the value is neither "true" nor "false".
# -----------------------------------------------------------------------------
_shared_is_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

# -----------------------------------------------------------------------------
# _shared_has_command
# @internal
# @description Checks whether a command exists in PATH.
# @arg $1 string Command name.
# @exitcode 1 If the command is not found.
# -----------------------------------------------------------------------------
_shared_has_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# _shared_require_command
# @internal
# @description Logs an error and fails if a required command is missing.
# @arg $1 string Command name.
# @arg $2 string Optional error message override.
# @exitcode 1 If the command is not found.
# -----------------------------------------------------------------------------
_shared_require_command() {
  local cmd="$1"
  local message="${2:-Required command not found: $cmd}"

  if _shared_has_command "$cmd"; then
    return 0
  fi

  _shared_log error "$message"
  return 1
}

# +++++++++++++++++++++++++++ INTERACTIVE PROMPTS ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_confirm
# @internal
# @description Prompts for y/N confirmation, defaulting to "no" for safety;
# fails immediately if stdin is not a terminal.
# @arg $1 string Optional prompt text; defaults to "Continue?".
# @exitcode 1 If the user declines, or stdin is not a terminal.
# -----------------------------------------------------------------------------
_shared_confirm() {
  _zsh_ui_confirm "$@"
}

_SHARED_HELPERS_LOADED=1

# ============================================================================ #
# End of _shared-helpers.zsh
