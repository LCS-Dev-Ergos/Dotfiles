# ============================================================================ #
# +++++++++++++++++++++++++++++ SHARED UI LAYER ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# cpp-tools draws with the terminal style every shell tool shares, defined in
# home/shells/zsh/config/scripts/_ui.zsh and described in Terminal-Style.md
# next to it. The package installs a copy as lib/_ui.zsh; a source checkout
# reads the original. The _cp_* functions keep the names the modules and the
# tests use: they apply cpp-tools' own settings (CP_UI_STYLE, CP_NO_GUM and
# CP_UI_WIDTH) and hand the drawing to the shared components.
# ============================================================================ #

: "${CP_UI_STYLE:=auto}"
: "${CP_UI_WIDTH:=auto}"

() {
  local root="${1:A:h:h}" candidate
  for candidate in \
      "$root/lib/_ui.zsh" \
      "$root/../../../../shells/zsh/config/scripts/_ui.zsh"; do
    [[ -r "$candidate" ]] || continue
    source "$candidate" && return 0
  done
  print -u2 -r -- "cpp-tools: the shared terminal style (_ui.zsh) is missing"
  return 1
} "${(%):-%x}" || return 2

# -----------------------------------------------------------------------------
# _cp_ui_has_gum
# -----------------------------------------------------------------------------
# Return success when Gum is installed and has not been disabled explicitly.
# CP_NO_GUM remains supported as a backwards-compatible override.
# -----------------------------------------------------------------------------
_cp_ui_has_gum() {
  [[ "${CP_NO_GUM:-0}" != 1 ]] && (( $+commands[gum] ))
}

# -----------------------------------------------------------------------------
# _cp_ui_resolve_mode
# -----------------------------------------------------------------------------
# Resolve auto, gum, ansi, or plain into REPLY. Auto mode uses Gum only when
# stdout is a terminal. NO_COLOR always selects plain output.
# -----------------------------------------------------------------------------
_cp_ui_resolve_mode() {
  emulate -L zsh
  local requested="${1:-${CP_UI_STYLE:-auto}}"
  unset REPLY

  if [[ -n "${NO_COLOR-}" ]]; then
    REPLY="plain"
    return 0
  fi

  case "$requested" in
    plain|ansi)
      REPLY="$requested"
      ;;
    gum)
      _cp_ui_has_gum && REPLY="gum" || REPLY="ansi"
      ;;
    auto|"")
      if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
        _cp_ui_has_gum && REPLY="gum" || REPLY="ansi"
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
# _cp_ui_gum_for_fd
# -----------------------------------------------------------------------------
# Return success when the selected style permits Gum on the requested terminal
# descriptor. This keeps choosers and spinners active when stdout is captured.
# -----------------------------------------------------------------------------
_cp_ui_gum_for_fd() {
  emulate -L zsh
  local fd="${1:-1}"
  local requested="${CP_UI_STYLE:-auto}"

  [[ -z "${NO_COLOR-}" ]] || return 1
  _cp_ui_has_gum || return 1

  case "$requested" in
    gum) return 0 ;;
    auto|"") [[ -t "$fd" && "${TERM:-dumb}" != dumb ]] ;;
    *) return 1 ;;
  esac
}

_cp_gum_ui() {
  _cp_ui_gum_for_fd 1
}

_cp_gum_interactive() {
  [[ -t 0 ]] && _cp_ui_gum_for_fd 2
}

# -----------------------------------------------------------------------------
# _cp_ui_call
# -----------------------------------------------------------------------------
# Run a shared component in the style cpp-tools resolved, so CP_UI_STYLE and
# CP_NO_GUM decide for it as they do for everything else here.
# -----------------------------------------------------------------------------
_cp_ui_call() {
  _cp_ui_resolve_mode || return $?
  local ZSH_UI_STYLE="$REPLY"
  # Gum is ruled out on this descriptor even when the style allows it.
  [[ "$REPLY" != gum ]] || _cp_ui_gum_for_fd 2 || ZSH_UI_STYLE=ansi
  "$@"
}

# -----------------------------------------------------------------------------
# _cp_ui_set_palette
# -----------------------------------------------------------------------------
# Install the palette the modules print with, taken from the shared style
# tokens, or empty values for plain output. Blue is the frame's, cyan the
# accent; muted holds secondary facts such as timings.
# -----------------------------------------------------------------------------
_cp_ui_set_palette() {
  emulate -L zsh
  local mode="$1"

  if [[ "$mode" == plain ]]; then
    typeset -g C_RESET="" C_BOLD="" C_RED="" C_GREEN=""
    typeset -g C_YELLOW="" C_BLUE="" C_CYAN="" C_MUTED=""
    return 0
  fi

  local -A sgr=("${(@kv)_ZSH_UI_SGR}")
  typeset -g C_RESET=$'\e[0m'
  typeset -g C_BOLD=$'\e['"${sgr[strong]}"'m'
  typeset -g C_RED=$'\e['"${sgr[error]}"'m'
  typeset -g C_GREEN=$'\e['"${sgr[ok]}"'m'
  typeset -g C_YELLOW=$'\e['"${sgr[warn]}"'m'
  typeset -g C_BLUE=$'\e['"${sgr[frame]}"'m'
  typeset -g C_CYAN=$'\e['"${sgr[accent]}"'m'
  typeset -g C_MUTED=$'\e['"${sgr[muted]}"'m'
}

# -----------------------------------------------------------------------------
# _cp_ui_refresh
# -----------------------------------------------------------------------------
# Re-evaluate the output mode and palette for the current invocation.
# -----------------------------------------------------------------------------
_cp_ui_refresh() {
  _cp_ui_resolve_mode "${1:-${CP_UI_STYLE:-auto}}" || return $?
  _cp_ui_set_palette "$REPLY"
}

# -----------------------------------------------------------------------------
# _cp_ui_mode
# -----------------------------------------------------------------------------
# Print the effective style. Intended for diagnostics and regression tests.
# -----------------------------------------------------------------------------
_cp_ui_mode() {
  _cp_ui_resolve_mode "${1:-${CP_UI_STYLE:-auto}}" || return $?
  print -r -- "$REPLY"
}

# -----------------------------------------------------------------------------
# _cp_ui_width
# -----------------------------------------------------------------------------
# Store the width output fits in REPLY: the shared one (the terminal's,
# within 40-120 columns) for CP_UI_WIDTH=auto, or an explicit integer clamped
# to 40-160 columns.
# -----------------------------------------------------------------------------
_cp_ui_width() {
  emulate -L zsh
  local requested="${1:-${CP_UI_WIDTH:-auto}}"
  local -i width

  if [[ "$requested" == auto || -z "$requested" ]]; then
    _zsh_ui_width
    return 0
  elif [[ "$requested" == <-> ]]; then
    width=$requested
  else
    return 2
  fi

  (( width < 40 )) && width=40
  (( width > 160 )) && width=160
  REPLY=$width
}

# -----------------------------------------------------------------------------
# _cp_ui_sanitize_text
# -----------------------------------------------------------------------------
# Escape terminal control characters in untrusted display text.
# -----------------------------------------------------------------------------
_cp_ui_sanitize_text() {
  _zsh_ui_sanitize_text "$1"
}

# -----------------------------------------------------------------------------
# _cp_rule / _cp_header / _cp_box_top / _cp_box_bottom
# -----------------------------------------------------------------------------
# A titled rule is a section title; its color names a tone when the section
# reports an outcome (red a failure, green a success, yellow a warning). An
# untitled rule closes raw output, such as a failed build's log. A box is a
# section too: its top is the title, and its bottom only says what follows.
# -----------------------------------------------------------------------------
_cp_rule() {
  emulate -L zsh
  local title="${1:-}"
  local -a tone=()
  case "${2:-blue}" in
    blue|cyan) ;;
    red) tone=(--tone error) ;;
    green) tone=(--tone ok) ;;
    yellow) tone=(--tone warn) ;;
    *) return 2 ;;
  esac
  _cp_ui_width || return $?
  if [[ -n "$title" ]]; then
    _cp_ui_call _zsh_ui_section --width "$REPLY" "${tone[@]}" "$title"
  else
    _cp_ui_call _zsh_ui_rule "" "$REPLY"
  fi
}

_cp_header() {
  _cp_rule "$1" "${2:-blue}"
}

_cp_box_top() {
  _cp_rule "${1:-}" "${2:-blue}"
}

_cp_box_bottom() {
  [[ -z "${1:-}" ]] || _cp_info "$1"
}

# -----------------------------------------------------------------------------
# _cp_heading / _cp_section
# -----------------------------------------------------------------------------
# A command's framed title, and a section title within its output.
# -----------------------------------------------------------------------------
_cp_heading() {
  _cp_ui_width || return $?
  _cp_ui_call _zsh_ui_heading --width "$REPLY" "$1" "${2:-}"
}

_cp_section() {
  _cp_ui_width || return $?
  _cp_ui_call _zsh_ui_section --width "$REPLY" "$1" "${2:-}"
}

# -----------------------------------------------------------------------------
# _cp_ui_table / _cp_ui_card
# -----------------------------------------------------------------------------
# A borderless table that fits the width, taking the shared table's options
# (--marker, --status, --align) before its tab-separated header; and a
# section title with key<TAB>value fields beneath.
# -----------------------------------------------------------------------------
_cp_ui_table() {
  (( $# )) || return 2
  _cp_ui_width || return $?
  _cp_ui_call _zsh_ui_table --width "$REPLY" "$@"
}

_cp_ui_card() {
  _cp_ui_call _zsh_ui_card "$@"
}

# -----------------------------------------------------------------------------
# _cp_kv
# -----------------------------------------------------------------------------
# One field of a section: a muted, padded label and its value, one indent in.
# -----------------------------------------------------------------------------
_cp_kv() {
  _cp_ui_refresh || return $?
  _cp_ui_sanitize_text "$1"
  local label="$REPLY"
  _cp_ui_sanitize_text "$2"
  printf '%*s%s%-16s%s %s\n' $(( _ZSH_UI_GUTTER + _ZSH_UI_INDENT )) "" \
    "$C_MUTED" "$label" "$C_RESET" "$REPLY"
}

# -----------------------------------------------------------------------------
# _cp_success / _cp_error / _cp_warn / _cp_info
# -----------------------------------------------------------------------------
# Event lines: a sign in its tone, then the message. Warnings and errors go
# to stderr; plain output keeps the bracketed level.
# -----------------------------------------------------------------------------
_cp_success() {
  _cp_ui_call _zsh_ui_log ok "$*"
}

_cp_error() {
  _cp_ui_call _zsh_ui_log error "$*"
}

_cp_warn() {
  _cp_ui_call _zsh_ui_log warn "$*"
}

_cp_info() {
  _cp_ui_call _zsh_ui_log info "$*"
}

# -----------------------------------------------------------------------------
# _cp_confirm / _cp_choose
# -----------------------------------------------------------------------------
# Without a terminal on stdin both fail, whatever the default: only a
# command's own --yes accepts unattended.
# -----------------------------------------------------------------------------
_cp_confirm() {
  [[ "${2:-no}" == (yes|no) ]] || return 2
  _cp_ui_call _zsh_ui_confirm "$1" "${2:-no}"
}

_cp_choose() {
  (( $# >= 2 )) || return 2
  _cp_ui_call _zsh_ui_choose "$@"
}

# -----------------------------------------------------------------------------
# _cp_spin
# -----------------------------------------------------------------------------
# Run a command under the shared spinner and print what it wrote, stderr
# included, once it ends: builds are read from their combined output.
# -----------------------------------------------------------------------------
_cp_spin() {
  emulate -L zsh
  (( $# >= 2 )) || return 2
  _cp_ui_sanitize_text "$1"
  local title="$REPLY"
  shift
  _cp_ui_call _zsh_ui_spinner_fn "$title" _cp_spin_merged "$@"
}

_cp_spin_merged() {
  "$@" 2>&1
}

# -----------------------------------------------------------------------------
# _cp_report_row
# -----------------------------------------------------------------------------
# Append one check to the caller's rows array, for _cp_report.
# @arg $1 string Group.
# @arg $2 string Tone: ok, warn, error, or muted for information.
# @arg $3 string Check.
# @arg $4 string Detail.
# -----------------------------------------------------------------------------
_cp_report_row() {
  rows+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4")
}

# -----------------------------------------------------------------------------
# _cp_report
# -----------------------------------------------------------------------------
# Draw a report of checks like devdoctor's and return 1 when any failed:
# a framed header, one counted section per group, a marker per check and a
# summary with the next step. Plain output is one aligned line per check,
# led by its state, then the same summary sentence.
# @arg $1 string Report title, beside the cpp-tools badge.
# @arg $2 string What to do next, on the summary line.
# @arg $@ string Rows: group, tone (ok, warn, error or muted), check, detail.
# -----------------------------------------------------------------------------
_cp_report() {
  emulate -L zsh
  setopt localoptions extendedglob
  local title="$1" hint="$2"
  shift 2
  local row group current="" tone label detail
  local -a f groups=()
  local -A count=() tally=()
  local -i w_label=0
  for row in "$@"; do
    f=("${(@ps:\t:)row}")
    (( count[$f[1]]++ )) || groups+=("$f[1]")
    (( tally[$f[2]]++ ))
    (( ${(m)#f[3]} > w_label )) && w_label=${(m)#f[3]}
  done

  local -a summary=(
    "ok"$'\t'"${tally[ok]:-0}"$'\t'"ok"
    "warn"$'\t'"${tally[warn]:-0}"$'\t'"warning${${tally[warn]:#1}:+s}"
    "error"$'\t'"${tally[error]:-0}"$'\t'"failed"
  )

  _cp_ui_resolve_mode || return $?
  if [[ "$REPLY" == plain ]]; then
    local -A words=(ok OK warn WARN error ERROR muted INFO)
    print -r -- "cpp-tools · $title"
    for row in "$@"; do
      f=("${(@ps:\t:)row}")
      if [[ "$f[1]" != "$current" ]]; then
        current="$f[1]"
        print -r -- ""
        print -r -- "$current"
      fi
      _cp_ui_sanitize_text "$f[4]"
      printf '%-6s %-*s  %s\n' "${words[$f[2]]}" "$w_label" "$f[3]" "$REPLY"
    done
    print -r -- ""
    _cp_ui_call _zsh_ui_summary --hint "$hint" "${summary[@]}"
    (( ${tally[error]:-0} == 0 ))
    return
  fi

  _cp_ui_refresh || return $?
  _cp_ui_width || return $?
  local -i width=$REPLY
  local indent="${(l:$(( _ZSH_UI_GUTTER + _ZSH_UI_INDENT )):: :)}"
  # The marker and its space, the gap and the right margin are fixed.
  local -i room=$(( width - ${#indent} - 2 - w_label - 2 - _ZSH_UI_GUTTER ))
  (( room < 12 )) && room=12
  _cp_ui_call _zsh_ui_app_header cpp-tools "$title" \
    "${#} checks in ${#groups} groups"
  for row in "$@"; do
    f=("${(@ps:\t:)row}")
    if [[ "$f[1]" != "$current" ]]; then
      current="$f[1]"
      print -r -- ""
      _cp_ui_call _zsh_ui_section --width "$width" "$current" "${count[$current]}"
    fi
    _cp_ui_call _zsh_ui_marker "$f[2]"
    local marker="$REPLY" color="$C_MUTED"
    [[ "$f[2]" == (warn|error) ]] && {
      _cp_ui_call _zsh_ui_tone_color "$f[2]"
      color="$REPLY"
    }
    _cp_ui_sanitize_text "$f[4]"
    _cp_ui_call _zsh_ui_short_path "$REPLY"
    _zsh_ui_truncate "$REPLY" "$room"
    print -r -- "${indent}${marker} ${f[3]}${(l:$(( w_label - ${(m)#f[3]} )):: :)}"\
"  ${color}${REPLY}${C_RESET}"
  done
  print -r -- ""
  _cp_ui_call _zsh_ui_summary --width "$width" --hint "$hint" "${summary[@]}"
  (( ${tally[error]:-0} == 0 ))
}

_cp_ui_refresh && _cp_ui_width || {
  print -u2 -r -- "cpp-tools: invalid CP_UI_STYLE or CP_UI_WIDTH setting"
  return 2
}

# ============================================================================ #
# End of 05-ui.zsh
