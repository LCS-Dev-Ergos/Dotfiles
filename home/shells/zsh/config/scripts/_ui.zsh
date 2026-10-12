#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ TERMINAL STYLE ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# The one look every shell tool shares: style tokens, static components and
# the Gum-backed interactions. A header sits in a rounded frame; below it,
# ruled section titles, type and space carry the structure, and tables stay
# borderless. home/shells/zsh/docs/Terminal-Style.md describes the model and
# when to use what.
#
# Usage:
#   source "${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts/_ui.zsh"
#
# Self-contained: it needs zsh, and Gum only for prompts and spinners. Python
# tools mirror the tokens (home/dev/bootstrap/core/ui.py), and a test there
# fails when the two tables differ.
#
# Author: LCS-Dev-Ergos
# License: MIT
# ============================================================================ #

# Re-sourcing is intentionally allowed so real implementations can replace
# stale lazy-loader stubs after a shell reload.

# ++++++++++++++++++++++++++++++++ STYLE TOKENS ++++++++++++++++++++++++++++++ #
#
# SGR parameters by role, and the glyphs that carry meaning. Colors are the
# terminal's own ANSI slots, so output follows the terminal theme; the two
# greys are fixed because a theme's "bright black" is often unreadable. Rules
# are the frame's blue, dimmed: where a terminal cannot dim, they fall back to
# plain blue.

typeset -gA _ZSH_UI_SGR=(
  strong   '1'
  accent   '36'
  badge    '1;7;36'
  heading  '1;34'
  frame    '34'
  rule     '2;34'
  muted    '38;5;245'
  faint    '38;5;240'
  ok       '32'
  warn     '33'
  error    '31'
)

typeset -gA _ZSH_UI_GLYPH=(
  ok            '●'
  pending       '▲'
  warn          '◆'
  error         '✖'
  muted         '○'
  info          '›'
  done          '✓'
  rule          '─'
  bar           '┃'
  side          '│'
  top_left      '╭'
  top_right     '╮'
  bottom_left   '╰'
  bottom_right  '╯'
)

# Two columns of margin on each side: a header's frame is drawn in it, and
# everything else starts after it. What a section holds (rows, tables,
# fields) sits one indent further in.
typeset -gi _ZSH_UI_GUTTER=2
typeset -gi _ZSH_UI_INDENT=2

# +++++++++++++++++++++++++++++++ MODE AND PALETTE +++++++++++++++++++++++++++ #

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
# @description Sets the palette variables for a resolved UI mode from the
# style tokens; plain mode empties them all. _ZSH_UI_BORDER, _ZSH_UI_KEY and
# _ZSH_UI_INFO keep the names older callers use.
# @arg $1 string Resolved style: plain, ansi, or gum.
# -----------------------------------------------------------------------------
_zsh_ui_set_palette() {
  emulate -L zsh
  local mode="$1"

  if [[ "$mode" == plain ]]; then
    typeset -g _ZSH_UI_RESET="" _ZSH_UI_BOLD="" _ZSH_UI_ACCENT=""
    typeset -g _ZSH_UI_BADGE="" _ZSH_UI_HEADING="" _ZSH_UI_MUTED=""
    typeset -g _ZSH_UI_FAINT="" _ZSH_UI_FRAME="" _ZSH_UI_RULE=""
    typeset -g _ZSH_UI_BORDER="" _ZSH_UI_KEY="" _ZSH_UI_INFO=""
    typeset -g _ZSH_UI_OK="" _ZSH_UI_WARN="" _ZSH_UI_ERROR=""
    return 0
  fi

  local -A sgr=("${(@kv)_ZSH_UI_SGR}")
  typeset -g _ZSH_UI_RESET=$'\e[0m'
  typeset -g _ZSH_UI_BOLD=$'\e['"${sgr[strong]}"'m'
  typeset -g _ZSH_UI_ACCENT=$'\e['"${sgr[accent]}"'m'
  typeset -g _ZSH_UI_BADGE=$'\e['"${sgr[badge]}"'m'
  typeset -g _ZSH_UI_HEADING=$'\e['"${sgr[heading]}"'m'
  typeset -g _ZSH_UI_MUTED=$'\e['"${sgr[muted]}"'m'
  typeset -g _ZSH_UI_FAINT=$'\e['"${sgr[faint]}"'m'
  typeset -g _ZSH_UI_FRAME=$'\e['"${sgr[frame]}"'m'
  typeset -g _ZSH_UI_RULE=$'\e['"${sgr[rule]}"'m'
  typeset -g _ZSH_UI_OK=$'\e['"${sgr[ok]}"'m'
  typeset -g _ZSH_UI_WARN=$'\e['"${sgr[warn]}"'m'
  typeset -g _ZSH_UI_ERROR=$'\e['"${sgr[error]}"'m'
  typeset -g _ZSH_UI_BORDER="$_ZSH_UI_FRAME"
  typeset -g _ZSH_UI_KEY="$_ZSH_UI_MUTED"
  typeset -g _ZSH_UI_INFO="$_ZSH_UI_ACCENT"
}

# -----------------------------------------------------------------------------
# _zsh_ui_tone_color
# @internal
# @description Stores the color of a tone in REPLY: ok, pending, warn, error
# or muted. With --strong, the bold variant markers use.
# @arg $1 string Optional --strong.
# @arg $2 string Tone.
# -----------------------------------------------------------------------------
_zsh_ui_tone_color() {
  emulate -L zsh
  local strong=""
  if [[ "${1-}" == --strong ]]; then
    strong="${_ZSH_UI_SGR[strong]};"
    shift
  fi
  local token
  case "${1-}" in
    ok) token=ok ;;
    pending|warn) token=warn ;;
    error) token=error ;;
    *) token=muted ;;
  esac
  _zsh_ui_resolve_mode || return $?
  if [[ "$REPLY" == plain ]]; then
    REPLY=""
  else
    REPLY=$'\e['"${strong}${_ZSH_UI_SGR[$token]}"'m'
  fi
}

# -----------------------------------------------------------------------------
# _zsh_ui_marker
# @internal
# @description Stores the colored one-cell marker of a tone in REPLY: a dot
# when healthy, a triangle when work is due, a diamond when worth a look, a
# cross on failure and a hollow dot for information.
# @arg $1 string Tone: ok, pending, warn, error, or muted.
# -----------------------------------------------------------------------------
_zsh_ui_marker() {
  emulate -L zsh
  local tone="${1:-muted}"
  local glyph="${_ZSH_UI_GLYPH[$tone]:-${_ZSH_UI_GLYPH[muted]}}"
  _zsh_ui_tone_color --strong "$tone" || return $?
  [[ -z "$REPLY" ]] || REPLY="${REPLY}${glyph}"$'\e[0m'
  [[ -n "$REPLY" ]] || REPLY="$glyph"
}

# +++++++++++++++++++++++++++++++ TEXT MEASURES ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _zsh_ui_width
# @internal
# @description Stores the terminal width, clamped to a readable range, in
# REPLY.
# @arg $1 integer Optional upper bound; defaults to 120.
# -----------------------------------------------------------------------------
_zsh_ui_width() {
  emulate -L zsh
  local -i width="${COLUMNS:-80}" limit="${1:-120}"
  (( width > 0 )) || width=80
  (( width < 40 )) && width=40
  (( width > limit )) && width=limit
  REPLY=$width
}

# -----------------------------------------------------------------------------
# _zsh_ui_layout_width
# @internal
# @description Stores the width a component draws to in REPLY: an explicit
# width when the caller fits its own layout, never under 40 columns, or the
# terminal's, clamped to 40-120.
# @arg $1 integer Optional explicit width; 0 or empty means the terminal's.
# -----------------------------------------------------------------------------
_zsh_ui_layout_width() {
  emulate -L zsh
  local -i width="${1:-0}"
  if (( width > 0 )); then
    (( width < 40 )) && width=40
    REPLY=$width
  else
    _zsh_ui_width
  fi
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
# @description Shortens text to a display width with an ellipsis. A path drops
# whole middle components, keeping its end first, so its file name and root
# stay visible; "link → target" shortens each side on its own; other text
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

  if [[ "$text" == */*/* && "$text" != *' '* ]]; then
    local -a parts=("${(@s:/:)text}")
    local -i count=${#parts}
    local candidate
    head=1 tail=1
    # An absolute path keeps its first directory (/nix, /opt) when it can:
    # the bare root says nothing.
    if [[ -z "${parts[1]}" ]] && (( count > 3 )); then
      candidate="/${parts[2]}/…/${parts[count]}"
      (( ${(m)#candidate} <= width )) && head=2
    fi
    candidate="${(j:/:)parts[1,head]}/…/${(j:/:)parts[count-tail+1,count]}"
    if (( ${(m)#candidate} <= width )); then
      while (( head + tail < count - 1 )); do
        candidate="${(j:/:)parts[1,head]}/…/${(j:/:)parts[count-tail,count]}"
        if (( ${(m)#candidate} <= width )); then
          (( tail++ ))
          continue
        fi
        candidate="${(j:/:)parts[1,head+1]}/…/${(j:/:)parts[count-tail+1,count]}"
        if (( ${(m)#candidate} <= width )); then
          (( head++ ))
          continue
        fi
        break
      done
      REPLY="${(j:/:)parts[1,head]}/…/${(j:/:)parts[count-tail+1,count]}"
      return 0
    fi
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

# +++++++++++++++++++++++++++++++ STATUS WORDS +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _zsh_ui_status_tone
# @internal
# @description Stores the tone of a status word in REPLY: ok for healthy
# states, pending for due work, warn for ones worth a look, error for
# failures, muted for informational ones, and nothing for anything else. Only
# the first word counts, so "Warning: resolves to Clang" reads as a warning.
# @arg $1 string Cell text.
# -----------------------------------------------------------------------------
_zsh_ui_status_tone() {
  emulate -L zsh
  local word="${(L)1}"
  word="${word%%[^a-z]*}"

  case "$word" in
    ok|available|reachable|pass|passed|active|loaded|installed|ready|\
clean|current|verified|enabled|done|success|present|removed)
      REPLY="ok" ;;
    outdated|pending|retire)
      REPLY="pending" ;;
    warn|warning|lazy|shadowed|unknown|partial|stale|degraded|skipped|\
changed|blocked)
      REPLY="warn" ;;
    broken|error|fail|failed|failure|missing|invalid|unreachable|conflict)
      REPLY="error" ;;
    dormant|unused|absent|disabled|inactive|none|external)
      REPLY="muted" ;;
    *)
      REPLY="" ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_status_style
# @internal
# @description Stores the palette color for a status word in REPLY, from its
# tone; nothing for a word without one. Set the palette first.
# @arg $1 string Cell text.
# -----------------------------------------------------------------------------
_zsh_ui_status_style() {
  emulate -L zsh
  _zsh_ui_status_tone "$1"
  case "$REPLY" in
    ok) REPLY="$_ZSH_UI_OK" ;;
    pending|warn) REPLY="$_ZSH_UI_WARN" ;;
    error) REPLY="$_ZSH_UI_ERROR" ;;
    muted) REPLY="$_ZSH_UI_MUTED" ;;
    *) REPLY="" ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_status_glyph
# @internal
# @description Stores a one-cell marker for a status word in REPLY and its
# bold color in reply[1]. A few words keep a sharper marker of their own:
# shadowed is a diamond, unknown a question mark, dormant a half-filled dot.
# Plain output uses ASCII markers.
# @arg $1 string Status word.
# -----------------------------------------------------------------------------
_zsh_ui_status_glyph() {
  emulate -L zsh
  local word="${(L)1}"
  _zsh_ui_status_tone "$word"
  local tone="$REPLY"
  _zsh_ui_resolve_mode || return $?
  if [[ "$REPLY" == plain ]]; then
    case "$tone" in
      error) REPLY="x" ;;
      pending|warn) REPLY="!" ;;
      muted) REPLY="-" ;;
      *) REPLY="*" ;;
    esac
    reply=("")
    return 0
  fi
  if [[ -n "$tone" ]]; then
    _zsh_ui_tone_color --strong "$tone"
    reply=("$REPLY")
  else
    reply=("")
  fi
  case "$word" in
    shadowed) REPLY="◆" ;;
    unknown|warn|warning) REPLY="?" ;;
    dormant) REPLY="◐" ;;
    *) REPLY="${_ZSH_UI_GLYPH[${tone:-ok}]}" ;;
  esac
}

# ++++++++++++++++++++++++++++++++ COMPONENTS ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _zsh_ui_log
# @internal
# @description Prints one event line; warn and error go to stderr. Styled
# output leads with a colored sign on the gutter (› info, ✓ ok, ▲ warn,
# ✖ error); plain output keeps the bracketed level for logs and grep.
# @arg $1 string Level: info, ok, warn, or error.
# @arg $@ string Message text.
# @exitcode 2 If the level or ZSH_UI_STYLE value is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_log() {
  emulate -L zsh
  local level="$1"
  shift
  _zsh_ui_sanitize_text "$*"
  local message="$REPLY"
  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  local label glyph tone
  case "$level" in
    info) label='[INFO]  ' glyph="${_ZSH_UI_GLYPH[info]}" tone="" ;;
    ok) label='[OK]    ' glyph="${_ZSH_UI_GLYPH[done]}" tone=ok ;;
    warn) label='[WARN]  ' glyph="${_ZSH_UI_GLYPH[pending]}" tone=warn ;;
    error) label='[ERROR] ' glyph="${_ZSH_UI_GLYPH[error]}" tone=error ;;
    *) return 2 ;;
  esac

  local line
  if [[ "$mode" == plain ]]; then
    line="${label}${message}"
  else
    local color="$_ZSH_UI_ACCENT"
    if [[ -n "$tone" ]]; then
      _zsh_ui_tone_color --strong "$tone"
      color="$REPLY"
    fi
    line="${(l:_ZSH_UI_GUTTER:: :)}${color}${glyph}${_ZSH_UI_RESET} ${message}"
  fi
  case "$level" in
    warn|error) print -r -- "$line" >&2 ;;
    *) print -r -- "$line" ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_rule
# @internal
# @description Prints a rule across the content column, from margin to
# margin, in the rule color; plain output prints a dashed line instead, at
# the full width.
# @arg $1 string Optional rule character.
# @arg $2 integer Optional explicit width; defaults to COLUMNS.
# -----------------------------------------------------------------------------
_zsh_ui_rule() {
  emulate -L zsh
  local char="${1:-}"
  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"
  local -i width="${2:-${COLUMNS:-80}}"
  (( width > 0 )) || width=80
  (( width < 40 )) && width=40
  (( width > 240 )) && width=240
  if [[ "$mode" == plain ]]; then
    [[ -n "$char" ]] || char="-"
    print -r -- "${(pl:$width::$char:)}"
    return 0
  fi
  [[ -n "$char" ]] || char="${_ZSH_UI_GLYPH[rule]}"
  local -i gutter=_ZSH_UI_GUTTER
  print -r -- "${(l:gutter:: :)}${_ZSH_UI_RULE}"\
"${(pl:$(( width - 2 * gutter ))::$char:)}${_ZSH_UI_RESET}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_frame
# @internal
# @description Draws a header's rounded frame around styled lines. The frame
# lies in the margin, so the lines inside start and end where the content
# below does. Set the palette first.
# @arg $1 integer Frame width.
# @arg $@ string Lines, already styled and no wider than the frame's inside.
# -----------------------------------------------------------------------------
_zsh_ui_frame() {
  emulate -L zsh
  local -i width="$1" inner pad
  shift
  inner=$(( width - 2 * _ZSH_UI_GUTTER ))
  local frame="$_ZSH_UI_FRAME" reset="$_ZSH_UI_RESET"
  local rule="${_ZSH_UI_GLYPH[rule]}" side="${_ZSH_UI_GLYPH[side]}"
  local edge="${(pl:$(( width - 2 ))::$rule:)}"
  local margin="${(l:$(( _ZSH_UI_GUTTER - 1 )):: :)}" line

  print -r -- "${frame}${_ZSH_UI_GLYPH[top_left]}${edge}"\
"${_ZSH_UI_GLYPH[top_right]}${reset}"
  for line in "$@"; do
    _zsh_ui_text_width "$line"
    pad=$(( inner - REPLY ))
    (( pad < 0 )) && pad=0
    print -r -- "${frame}${side}${reset}${margin}${line}${(l:$pad:: :)}"\
"${margin}${frame}${side}${reset}"
  done
  print -r -- "${frame}${_ZSH_UI_GLYPH[bottom_left]}${edge}"\
"${_ZSH_UI_GLYPH[bottom_right]}${reset}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_heading
# @internal
# @description Prints the header of a simple command: the title in the accent
# badge inside a rounded frame, with the subtitle muted beside it, or under it
# when the line is too short for both. Plain output is the two bare lines.
# @option --width <n> Width to fit instead of the terminal's.
# @arg $1 string Title text.
# @arg $2 string Optional subtitle text.
# @exitcode 2 If an option is invalid or the UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_heading() {
  emulate -L zsh
  local -i limit=0
  if [[ "${1-}" == --width ]]; then
    [[ "${2-}" == <1-> ]] || return 2
    limit=$2
    shift 2
  fi
  _zsh_ui_sanitize_text "${1-}"
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

  _zsh_ui_layout_width "$limit"
  local -i width=$REPLY
  local -i inner=$(( width - 2 * _ZSH_UI_GUTTER ))
  _zsh_ui_truncate "$title" $(( inner - 2 ))
  local -i used=$(( ${(m)#REPLY} + 2 ))
  local -a lines=("${_ZSH_UI_BADGE} ${REPLY} ${_ZSH_UI_RESET}")
  if [[ -z "$subtitle" ]]; then
    :
  elif (( used + 2 + ${(m)#subtitle} <= inner )); then
    lines[1]+="  ${_ZSH_UI_MUTED}${subtitle}${_ZSH_UI_RESET}"
  else
    # Under the badge, the subtitle lines up with the title's first letter.
    _zsh_ui_truncate "$subtitle" $(( inner - 1 ))
    lines+=(" ${_ZSH_UI_MUTED}${REPLY}${_ZSH_UI_RESET}")
  fi
  _zsh_ui_frame "$width" "${lines[@]}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_app_header
# @internal
# @description Prints the masthead of a report-style tool in a rounded frame:
# the tool name in the accent badge, the title beside it and context on the
# right, then a quieter line with its own right-aligned note. Context and
# note give way before the text they share a line with is cut. Plain output
# is "tool · Title" and one line with the rest.
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
    local -a details=("$subtitle" "$context" "$note")
    details=("${(@)details:#}")
    (( ${#details} )) && print -r -- "${(j: · :)details}"
    return 0
  fi

  _zsh_ui_width
  local -i width=$REPLY
  local badge=" ${(U)tag} "
  local -i indent=$(( ${(m)#badge} + 2 ))
  local -i room=$(( width - 2 * _ZSH_UI_GUTTER - indent ))
  (( ${(m)#title} + 2 + ${(m)#context} > room )) && context=""
  (( ${(m)#subtitle} + 2 + ${(m)#note} > room )) && note=""
  _zsh_ui_truncate "$title" "$room"
  title="$REPLY"
  _zsh_ui_truncate "$subtitle" "$room"
  subtitle="$REPLY"

  local muted="$_ZSH_UI_MUTED" reset="$_ZSH_UI_RESET"
  local -i gap1=$(( room - ${(m)#title} - ${(m)#context} ))
  local -i gap2=$(( room - ${(m)#subtitle} - ${(m)#note} ))
  local -a lines=()
  local line="${_ZSH_UI_BADGE}${badge}${reset}  ${_ZSH_UI_BOLD}${title}${reset}"
  [[ -z "$context" ]] ||
    line+="${(l:$gap1:: :)}${muted}${context}${reset}"
  lines+=("$line")
  if [[ -n "$subtitle$note" ]]; then
    line="${(l:$indent:: :)}"
    [[ -z "$subtitle" ]] || line+="${muted}${subtitle}${reset}"
    [[ -z "$note" ]] || line+="${(l:$gap2:: :)}${muted}${note}${reset}"
    lines+=("$line")
  fi
  _zsh_ui_frame "$width" "${lines[@]}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_section_line
# @internal
# @description Draws a section title: the title in the heading color, or in
# the given one, then a rule to the right margin that ends in the note, muted.
# The note gives way before the rule grows too short to read as one. Set the
# palette first.
# @arg $1 integer Width to fit.
# @arg $2 string Title, already sanitized.
# @arg $3 string Optional note, already sanitized.
# @arg $4 string Optional title color; defaults to the heading color.
# -----------------------------------------------------------------------------
_zsh_ui_section_line() {
  emulate -L zsh
  local -i room=$(( $1 - 2 * _ZSH_UI_GUTTER )) fill
  local note="${3-}" color="${4:-$_ZSH_UI_HEADING}"
  _zsh_ui_truncate "$2" "$room"
  local title="$REPLY"

  # title, space, rule, space, note
  fill=$(( room - ${(m)#title} - ${(m)#note} - 2 ))
  if [[ -z "$note" ]] || (( fill < 3 )); then
    note=""
    fill=$(( room - ${(m)#title} - 1 ))
  fi
  local rule="${_ZSH_UI_GLYPH[rule]}"
  local line="${(l:_ZSH_UI_GUTTER:: :)}${color}${title}${_ZSH_UI_RESET}"
  (( fill > 0 )) &&
    line+=" ${_ZSH_UI_RULE}${(pl:$fill::$rule:)}${_ZSH_UI_RESET}"
  [[ -z "$note" ]] || line+=" ${_ZSH_UI_MUTED}${note}${_ZSH_UI_RESET}"
  print -r -- "$line"
}

# -----------------------------------------------------------------------------
# _zsh_ui_section
# @internal
# @description Prints a section title in the heading color and a rule to the
# right margin, ending in an optional muted note such as the count of what
# the section holds. "Title · note" reads as a title and its note. Plain
# output is the bare title, with " · note" when there is one.
# @option --width <n> Width to fit instead of the terminal's.
# @option --tone <tone> Sets the title in a tone's bold color instead of the
# heading color, for a section that reports an outcome (a failed build).
# @arg $1 string Section title.
# @arg $2 string Optional note at the end of the rule.
# @exitcode 2 If an option is invalid or the UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_section() {
  emulate -L zsh
  local -i limit=0
  local tone=""
  while [[ "${1-}" == --(width|tone) ]]; do
    case "$1" in
      --width) [[ "${2-}" == <1-> ]] || return 2; limit=$2 ;;
      --tone) [[ "${2-}" == (ok|pending|warn|error|muted) ]] || return 2; tone=$2 ;;
    esac
    shift 2
  done
  _zsh_ui_sanitize_text "${1-}"
  local title="$REPLY"
  _zsh_ui_sanitize_text "${2-}"
  local note="$REPLY"
  if [[ -z "$note" && "$title" == *" · "* ]]; then
    note="${title#* · }"
    title="${title%% · *}"
  fi

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  if [[ "$mode" == plain ]]; then
    print -r -- "${title}${note:+ · $note}"
    return 0
  fi
  local color=""
  if [[ -n "$tone" ]]; then
    _zsh_ui_tone_color --strong "$tone"
    color="$REPLY"
  fi
  _zsh_ui_layout_width "$limit"
  _zsh_ui_section_line "$REPLY" "$title" "$note" "$color"
}

# -----------------------------------------------------------------------------
# _zsh_ui_subsection
# @internal
# @description Prints a section title for help menus and catalogs. Styled
# output is the shared section title; plain output keeps the zfuncs layout,
# the title over a short, indented dashed rule.
# @arg $1 string Section title.
# @arg $2 integer Optional available width; defaults to COLUMNS or 80.
# @arg $3 string Optional note at the end of the styled rule.
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

  if [[ "$mode" != plain ]]; then
    local -i limit=0
    [[ -n "${2-}" ]] && limit=$available_width
    _zsh_ui_sanitize_text "$title"
    title="$REPLY"
    _zsh_ui_sanitize_text "${3-}"
    local note="$REPLY"
    _zsh_ui_layout_width "$limit"
    _zsh_ui_section_line "$REPLY" "$title" "$note"
    return 0
  fi

  local -i rule_width=$(( ${#title} + 4 ))
  (( rule_width < 24 )) && rule_width=24
  (( rule_width > 48 )) && rule_width=48
  (( rule_width > available_width - 2 )) &&
    rule_width=$(( available_width - 2 ))
  (( rule_width < 1 )) && rule_width=1
  print -r -- "$title"
  print -r -- "  ${(pl:$rule_width::-:)}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_card
# @internal
# @description Prints a compact information block: a section title, then its
# body one indent in. Body lines of the form "key<TAB>value" become an
# aligned key/value list with muted keys, empty lines stay as spacing, and
# any other line is free text; long values wrap under their own column. Free
# text may carry palette escapes from trusted callers.
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
  local -i width=$REPLY index
  local -i offset=$(( _ZSH_UI_GUTTER + _ZSH_UI_INDENT ))
  local -i room=$(( width - offset - _ZSH_UI_GUTTER ))
  local indent="${(l:offset:: :)}" reset="$_ZSH_UI_RESET"
  local -a wrapped
  _zsh_ui_section_line "$width" "$title"
  for line in "$@"; do
    if [[ "$line" == *$'\t'* ]]; then
      key="${line%%$'\t'*}"
      value="${line#*$'\t'}"
      _zsh_ui_wrap $(( room - key_width - 2 )) "$value"
      wrapped=("${reply[@]}")
      print -r -- "${indent}${_ZSH_UI_MUTED}${key}${reset}"\
"${(l:$(( key_width - ${(m)#key} + 2 )):: :)}${wrapped[1]}${reset}"
      for (( index = 2; index <= ${#wrapped}; index++ )); do
        print -r -- "${indent}${(l:$(( key_width + 2 )):: :)}${wrapped[index]}"
      done
    elif [[ -z "$line" ]]; then
      print -r -- ""
    else
      _zsh_ui_wrap "$room" "$line"
      for value in "${reply[@]}"; do
        print -r -- "${indent}${value}${reset}"
      done
    fi
  done
}

# -----------------------------------------------------------------------------
# _zsh_ui_table
# @internal
# @description Renders tab-separated rows as a borderless table with its
# column labels in capitals. Styled output sits one indent in, like everything
# a section holds, mutes the labels and fits the terminal: the widest columns
# give up space first and their cells are shortened with an ellipsis (paths
# lose middle components). Plain output stays an untruncated, aligned layout
# that is safe to capture. "-" cells are faint in every styled table.
# @option --align <spec> One letter per column, l or r; defaults to l.
# @option --marker <n> Styled rows lead with the marker of column n's status
# word, as report rows do; a word without a tone leaves the place blank.
# @option --status <n[,n]> Columns whose status words are colored.
# @option --tones <tone,...> One tone per row, for callers that know each
# row's outcome: rows lead with its marker, and --status columns take its
# color whatever their words say.
# @option --width <n> Width to fit instead of COLUMNS.
# @arg $1 string Tab-separated column headings.
# @arg $@ string Tab-separated data rows.
# @exitcode 2 If the header is missing, an option is invalid, or the UI style
# is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_table() {
  emulate -L zsh
  local align="" status_spec=""
  local -i limit=0 marker_column=0
  local -a row_tones=()

  while [[ "${1-}" == --* ]]; do
    case "$1" in
      --align|--marker|--status|--tones|--width)
        (( $# >= 2 )) || return 2
        case "$1" in
          --align) align="$2" ;;
          --marker) [[ "$2" == <1-> ]] || return 2; marker_column=$2 ;;
          --status) status_spec="$2" ;;
          --tones) row_tones=("${(@s:,:)2}") ;;
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
  local -i ncols nrows c r

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

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"
  columns=("${(@U)columns}")

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

  # Shrink the widest column one step at a time until the table fits. A
  # column never drops below its heading or 8 cells, whichever is smaller
  # than its content; a table that still overflows is left to wrap.
  local -i available="${limit:-0}" total excess best widest
  local -i offset=$(( _ZSH_UI_GUTTER + _ZSH_UI_INDENT )) lead=0
  (( marker_column > 0 && marker_column <= ncols )) || marker_column=0
  (( marker_column || ${#row_tones} )) && lead=2
  (( available > 0 )) || available="${COLUMNS:-80}"
  (( available -= offset + lead + _ZSH_UI_GUTTER ))
  total=$(( 2 * (ncols - 1) ))
  for (( c = 1; c <= ncols; c++ )); do
    (( total += widths[c] ))
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

  local reset="$_ZSH_UI_RESET" style indent="${(l:offset:: :)}"
  for (( r = 0; r <= nrows; r++ )); do
    line="$indent"
    if (( r > 0 && ${#row_tones} )); then
      _zsh_ui_marker "${row_tones[r]:-muted}"
      line+="${REPLY} "
    elif (( lead )); then
      _zsh_ui_status_tone "${cells[(r - 1) * ncols + marker_column]-}"
      if (( r == 0 )) || [[ -z "$REPLY" ]]; then
        line+="  "
      else
        _zsh_ui_status_glyph "${cells[(r - 1) * ncols + marker_column]}"
        line+="${reply[1]}${REPLY}${reset} "
      fi
    fi
    for (( c = 1; c <= ncols; c++ )); do
      if (( r == 0 )); then
        text="${columns[c]}"
      else
        text="${cells[(r - 1) * ncols + c]}"
      fi
      _zsh_ui_truncate "$text" "${widths[c]}"
      text="$REPLY"
      pad="${(l:$(( widths[c] - ${(m)#text} )):: :)}"
      (( c == ncols )) && [[ "${aligns[c]}" != r ]] && pad=""

      style=""
      if (( r == 0 )); then
        style="$_ZSH_UI_MUTED"
      elif [[ "$text" == (-|—) ]]; then
        style="$_ZSH_UI_FAINT"
      elif (( ${+status_columns[$c]} && ${#row_tones} )); then
        _zsh_ui_tone_color "${row_tones[r]:-muted}"
        style="$REPLY"
      elif (( ${+status_columns[$c]} )); then
        _zsh_ui_status_style "$text"
        style="$REPLY"
      fi
      [[ -z "$style" ]] || text="${style}${text}${reset}"

      (( c > 1 )) && line+="  "
      if [[ "${aligns[c]}" == r ]]; then
        line+="${pad}${text}"
      else
        line+="${text}${pad}"
      fi
    done
    print -r -- "$line"
  done
}

# -----------------------------------------------------------------------------
# _zsh_ui_definition_list
# @internal
# @description Renders tab-separated terms and descriptions as an aligned
# list: terms in the accent color, descriptions muted. Styled output sits one
# indent in, under its section title; plain output keeps two spaces. Styling
# stays shell-native in every mode, so help menus do not spawn one Gum
# process per section.
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
  local indent="  "
  [[ "$REPLY" == plain ]] ||
    indent="${(l:$(( _ZSH_UI_GUTTER + _ZSH_UI_INDENT )):: :)}"
  for (( index = 1; index <= ${#terms[@]}; index++ )); do
    if [[ -n "${descriptions[$index]}" ]]; then
      printf '%s%s%-*s%s  %s%s%s\n' "$indent" \
        "$_ZSH_UI_ACCENT" "$width" "${terms[$index]}" "$_ZSH_UI_RESET" \
        "$_ZSH_UI_MUTED" "${descriptions[$index]}" "$_ZSH_UI_RESET"
    else
      printf '%s%s%s%s\n' "$indent" \
        "$_ZSH_UI_ACCENT" "${terms[$index]}" "$_ZSH_UI_RESET"
    fi
  done
}

# -----------------------------------------------------------------------------
# _zsh_ui_callout
# @internal
# @description Sets a notice off with a bar in its tone's color, on the
# gutter and without a frame: a bold title, then wrapped lines. Plain output
# is the title and the lines indented under it.
# @arg $1 string Tone: ok, pending, warn, error, or muted.
# @arg $2 string Title.
# @arg $@ string Optional body lines.
# @exitcode 2 If the title is missing or the UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_callout() {
  emulate -L zsh
  (( $# >= 2 )) || return 2
  local tone="$1" line piece
  _zsh_ui_sanitize_text "$2"
  local title="$REPLY"
  shift 2

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  if [[ "$mode" == plain ]]; then
    print -r -- "$title"
    for line in "$@"; do
      _zsh_ui_sanitize_text "$line"
      print -r -- "  $REPLY"
    done
    return 0
  fi

  _zsh_ui_width
  local -i room=$(( REPLY - 2 * _ZSH_UI_GUTTER - 2 ))
  _zsh_ui_tone_color "$tone"
  local bar="${(l:_ZSH_UI_GUTTER:: :)}${REPLY}${_ZSH_UI_GLYPH[bar]}${_ZSH_UI_RESET} "
  _zsh_ui_truncate "$title" "$room"
  print -r -- "${bar}${_ZSH_UI_BOLD}${REPLY}${_ZSH_UI_RESET}"
  for line in "$@"; do
    _zsh_ui_sanitize_text "$line"
    _zsh_ui_wrap "$room" "$REPLY"
    for piece in "${reply[@]}"; do
      print -r -- "${bar}${piece}"
    done
  done
}

# -----------------------------------------------------------------------------
# _zsh_ui_summary
# @internal
# @description Closes a report: a rule across the content column, then the
# count of each state with its marker and, on the right margin, what to do
# next. Counts wrap rather than overflow, and the hint gives way first. Plain
# output is one leveled sentence, labeled by the most severe tone.
# @option --hint <text> What to do next.
# @option --width <n> Width to fit instead of COLUMNS.
# @arg $@ string Tab-separated rows: tone, count, word. Zero counts are left
# out; an empty tone marks the word as _zsh_ui_status_glyph does.
# @exitcode 2 If an option is invalid or the UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_summary() {
  emulate -L zsh
  local hint=""
  local -i limit=0
  while [[ "${1-}" == --* ]]; do
    case "$1" in
      --hint) (( $# >= 2 )) || return 2; hint="$2"; shift 2 ;;
      --width) [[ "${2-}" == <1-> ]] || return 2; limit=$2; shift 2 ;;
      --) shift; break ;;
      *) return 2 ;;
    esac
  done
  _zsh_ui_sanitize_text "$hint"
  hint="$REPLY"

  local -a fields items=() words=()
  local row worst="ok" tone
  local -A severity=(ok 1 muted 2 pending 3 warn 4 error 5)
  for row in "$@"; do
    fields=("${(@ps:\t:)row}")
    [[ "${fields[2]:-0}" == <1-> ]] || continue
    tone="${fields[1]}"
    if [[ -n "$tone" ]]; then
      _zsh_ui_marker "$tone"
    else
      _zsh_ui_status_tone "${fields[3]}"
      tone="${REPLY:-ok}"
      _zsh_ui_status_glyph "${fields[3]}"
      [[ -z "${reply[1]}" ]] || REPLY="${reply[1]}${REPLY}"$'\e[0m'
    fi
    (( ${severity[$tone]:-1} > ${severity[$worst]} )) && worst="$tone"
    words+=("${fields[2]} ${fields[3]}")
    items+=("$REPLY ${fields[2]} ${fields[3]}")
  done

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  _zsh_ui_set_palette "$mode"

  if [[ "$mode" == plain ]]; then
    local -A labels=(ok '[OK]    ' muted '[OK]    ' pending '[INFO]  '
      warn '[WARN]  ' error '[ERROR] ')
    local sentence="${(j:, :)words}"
    [[ -n "$hint" ]] && sentence+="${sentence:+; }$hint"
    print -r -- "${labels[$worst]}${sentence}${sentence:+.}"
    return 0
  fi

  local -i width="${limit:-0}"
  (( width > 0 )) || { _zsh_ui_width; width=$REPLY; }
  local -i room=$(( width - 2 * _ZSH_UI_GUTTER )) gap
  local gutter="${(l:_ZSH_UI_GUTTER:: :)}" item
  local -a lines=("")
  for item in "${items[@]}"; do
    _zsh_ui_text_width "${lines[-1]}   $item"
    if [[ -n "${lines[-1]}" ]] && (( REPLY > room )); then
      lines+=("")
    fi
    lines[-1]+="${lines[-1]:+   }$item"
  done
  _zsh_ui_text_width "${lines[-1]}"
  gap=$(( room - REPLY - ${(m)#hint} ))
  if (( gap < 3 )); then
    hint="" gap=0
  fi
  [[ -z "$hint" ]] ||
    lines[-1]+="${(l:$gap:: :)}${_ZSH_UI_MUTED}${hint}${_ZSH_UI_RESET}"

  local rule="${_ZSH_UI_GLYPH[rule]}"
  print -r -- "${gutter}${_ZSH_UI_RULE}${(pl:$room::$rule:)}${_ZSH_UI_RESET}"
  for item in "${lines[@]}"; do
    print -r -- "${gutter}${item}"
  done
}

# +++++++++++++++++++++++++++++++ INTERACTIONS +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _zsh_ui_gum
# @internal
# @description Runs Gum with the shared theme: accent cyan for prompts,
# cursors and spinners, blue for selections and headers, never Gum's default
# pink.
# @arg $@ string Gum subcommand and arguments.
# -----------------------------------------------------------------------------
_zsh_ui_gum() {
  emulate -L zsh
  local -x GUM_CONFIRM_PROMPT_FOREGROUND=6 GUM_CONFIRM_SELECTED_BACKGROUND=4
  local -x GUM_CHOOSE_CURSOR_FOREGROUND=6 GUM_CHOOSE_HEADER_FOREGROUND=4
  local -x GUM_CHOOSE_SELECTED_FOREGROUND=6 GUM_SPIN_SPINNER_FOREGROUND=6
  command gum "$@"
}

# -----------------------------------------------------------------------------
# _zsh_ui_confirm
# @internal
# @description Requests confirmation with Gum when useful, otherwise a native
# prompt. Without a terminal on stdin it fails, whatever the default: only
# the caller's own explicit flag, such as --yes, may accept unattended.
# @arg $1 string Optional prompt text; defaults to "Continue?".
# @arg $2 string Optional default answer on a terminal: no (default) or yes.
# @exitcode 1 If stdin is not a tty or the user declines.
# @exitcode 2 If the default is neither yes nor no.
# -----------------------------------------------------------------------------
_zsh_ui_confirm() {
  emulate -L zsh
  _zsh_ui_sanitize_text "${1:-Continue?}"
  local prompt="$REPLY" default_answer="${2:-no}" reply
  [[ "$default_answer" == (yes|no) ]] || return 2

  if [[ ! -t 0 ]]; then
    _zsh_ui_log error "Cannot prompt: stdin is not a terminal."
    return 1
  fi

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum && -t 1 ]]; then
    local selected=false
    [[ "$default_answer" == yes ]] && selected=true
    _zsh_ui_gum confirm --default="$selected" "$prompt"
    return $?
  fi

  _zsh_ui_set_palette "$mode"
  local choices="[y/N]"
  [[ "$default_answer" == yes ]] && choices="[Y/n]"
  printf '%s?%s %s %s%s%s ' \
    "$_ZSH_UI_ACCENT" "$_ZSH_UI_RESET" "$prompt" \
    "$_ZSH_UI_MUTED" "$choices" "$_ZSH_UI_RESET"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    "") [[ "$default_answer" == yes ]] ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# _zsh_ui_choose
# @internal
# @description Asks for one option and prints it on stdout: Gum's chooser on a
# terminal, otherwise a numbered list on stderr and a native prompt. Without a
# terminal on stdin it fails, so a script never picks for the user.
# @arg $1 string Header text.
# @arg $@ string Options.
# @exitcode 1 If stdin is not a tty or the answer is not an option.
# @exitcode 2 If no option is given or the UI style is invalid.
# @stdout The chosen option.
# -----------------------------------------------------------------------------
_zsh_ui_choose() {
  emulate -L zsh
  (( $# >= 2 )) || return 2
  _zsh_ui_sanitize_text "$1"
  local header="$REPLY" answer
  shift

  if [[ ! -t 0 ]]; then
    _zsh_ui_log error "Cannot prompt: stdin is not a terminal."
    return 1
  fi

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum && -t 2 ]]; then
    _zsh_ui_gum choose --header "$header" -- "$@"
    return $?
  fi

  _zsh_ui_set_palette "$mode"
  local -i index
  print -u2 -r -- "$header"
  for (( index = 1; index <= $#; index++ )); do
    _zsh_ui_sanitize_text "${@[index]}"
    print -u2 -r -- "  ${_ZSH_UI_MUTED}${index})${_ZSH_UI_RESET} $REPLY"
  done
  printf '%s?%s Choose %s[1-%d]%s ' "$_ZSH_UI_ACCENT" "$_ZSH_UI_RESET" \
    "$_ZSH_UI_MUTED" $# "$_ZSH_UI_RESET" >&2
  read -r answer
  [[ "$answer" == <1-> ]] && (( answer <= $# )) || return 1
  print -r -- "${@[answer]}"
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
    _zsh_ui_gum spin --spinner dot --title "$label" -- "$@"
  else
    _zsh_ui_log info "$label"
    command "$@"
  fi
}

# -----------------------------------------------------------------------------
# _zsh_ui_spinner_fn
# @internal
# @description Runs a shell function under one Gum spinner, buffering its
# output and replaying it once the work finishes. _zsh_ui_spinner can only
# run external commands, and it drops the spinner whenever standard output
# is redirected; Gum draws the spinner on standard error, so this variant keeps
# it for work whose output the caller captures.
# @arg $1 string Progress label.
# @arg $@ command Function or command, and its arguments, to execute.
# @exitcode 2 If no command is provided or the UI style is invalid.
# @stdout Whatever the command wrote to standard output.
# @stderr What the command wrote to standard error, replayed only when it
# fails: a spinner cannot share the terminal with it, and a success needs no
# diagnostics.
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
  local err_file="$work_dir/errors"
  local status_file="$work_dir/status"
  local -i worker_pid worker_status

  { "$@" >| "$out_file" 2>| "$err_file"; print -r -- $? >| "$status_file" } &
  worker_pid=$!

  # The waiter polls a status file rather than the pid: it survives a reaped
  # child and cannot latch onto a recycled pid.
  _zsh_ui_gum spin --spinner dot --title "$label" -- \
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
  (( worker_status == 0 )) || command cat -- "$err_file" >&2 2>/dev/null
  command rm -rf -- "$work_dir" 2>/dev/null
  return $worker_status
}

_ZSH_UI_LOADED=1

# ============================================================================ #
# End of _ui.zsh
