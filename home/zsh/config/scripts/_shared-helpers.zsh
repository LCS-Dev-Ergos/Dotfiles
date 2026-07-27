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
# Author: XtremeXSPC
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
# @arg $1 string Resolved style: plain, ansi, or gum.
# -----------------------------------------------------------------------------
_zsh_ui_set_palette() {
  emulate -L zsh
  local mode="$1"

  if [[ "$mode" == plain ]]; then
    typeset -g _ZSH_UI_RESET="" _ZSH_UI_BOLD="" _ZSH_UI_ACCENT=""
    typeset -g _ZSH_UI_HEADING="" _ZSH_UI_MUTED="" _ZSH_UI_INFO=""
    typeset -g _ZSH_UI_OK="" _ZSH_UI_WARN="" _ZSH_UI_ERROR=""
    return 0
  fi

  typeset -g _ZSH_UI_RESET=$'\e[0m'
  typeset -g _ZSH_UI_BOLD=$'\e[1m'
  typeset -g _ZSH_UI_ACCENT=$'\e[1;38;5;212m'
  typeset -g _ZSH_UI_HEADING=$'\e[1;38;5;75m'
  typeset -g _ZSH_UI_MUTED=$'\e[38;5;245m'
  typeset -g _ZSH_UI_INFO=$'\e[1;38;5;81m'
  typeset -g _ZSH_UI_OK=$'\e[1;38;5;42m'
  typeset -g _ZSH_UI_WARN=$'\e[1;38;5;214m'
  typeset -g _ZSH_UI_ERROR=$'\e[1;38;5;196m'
}

# -----------------------------------------------------------------------------
# _zsh_ui_log
# @internal
# @description Prints a compact leveled log line using native ANSI styling;
# Gum is intentionally not spawned for per-line output.
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
# @description Prints a native horizontal rule clamped to a practical width;
# the default character matches the resolved plain or styled UI mode.
# @arg $1 string Optional rule character.
# @arg $2 integer Optional explicit width; defaults to COLUMNS.
# -----------------------------------------------------------------------------
_zsh_ui_rule() {
  emulate -L zsh
  local char="${1:-}"
  if [[ -z "$char" ]]; then
    _zsh_ui_resolve_mode || return $?
    char="-"
    [[ "$REPLY" == plain ]] || char="─"
  fi
  local -i width="${2:-${COLUMNS:-80}}"
  (( width > 0 )) || width=80
  (( width < 40 )) && width=40
  (( width > 240 )) && width=240
  printf '%s\n' "${(pl:$width::$char:)}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_heading
# @internal
# @description Prints a title and optional subtitle; Gum is invoked at most
# once, while ANSI and plain modes remain shell-native.
# @arg $1 string Title text.
# @arg $2 string Optional subtitle text.
# -----------------------------------------------------------------------------
_zsh_ui_heading() {
  emulate -L zsh
  local title="$1"
  local subtitle="${2:-}"
  local content="$title"
  [[ -z "$subtitle" ]] || content+=$'\n'"$subtitle"

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum ]]; then
    CLICOLOR_FORCE=1 command gum style \
      --bold --foreground 212 "$content" 2>/dev/null && return 0
    mode="ansi"
  fi

  _zsh_ui_set_palette "$mode"
  print -r -- "${_ZSH_UI_ACCENT}${title}${_ZSH_UI_RESET}"
  [[ -z "$subtitle" ]] ||
    print -r -- "${_ZSH_UI_MUTED}${subtitle}${_ZSH_UI_RESET}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_section
# @internal
# @description Prints a section label using native output in every UI mode.
# @arg $1 string Section title.
# -----------------------------------------------------------------------------
_zsh_ui_section() {
  emulate -L zsh
  local title="$1"
  _zsh_ui_resolve_mode || return $?
  _zsh_ui_set_palette "$REPLY"
  print -r -- "${_ZSH_UI_HEADING}${title}${_ZSH_UI_RESET}"
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
    "${_ZSH_UI_MUTED}  ${(pl:$rule_width::$rule_character:)}${_ZSH_UI_RESET}"
}

# -----------------------------------------------------------------------------
# _zsh_ui_card
# @internal
# @description Prints a compact information card; Gum is invoked at most once.
# @arg $1 string Card title.
# @arg $@ string Optional body lines.
# -----------------------------------------------------------------------------
_zsh_ui_card() {
  emulate -L zsh
  local title="$1"
  shift
  local content="$title"
  local line
  for line in "$@"; do
    content+=$'\n'"$line"
  done

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum ]]; then
    local -i width=${COLUMNS:-80}
    (( width < 50 )) && width=50
    (( width > 100 )) && width=100
    CLICOLOR_FORCE=1 command gum style \
      --border rounded \
      --border-foreground 212 \
      --padding '1 2' \
      --width "$width" \
      "$content" 2>/dev/null && return 0
    mode="ansi"
  fi

  _zsh_ui_set_palette "$mode"
  print -r -- "${_ZSH_UI_ACCENT}${title}${_ZSH_UI_RESET}"
  (( $# == 0 )) || print -r -- ""
  for line in "$@"; do
    print -r -- "$line"
  done
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
# @description Renders tab-separated rows as a static Gum table, falling back
# to an aligned Zsh-native table when Gum is unavailable or fails.
# @arg $1 string Tab-separated column headings.
# @arg $@ string Tab-separated data rows.
# @exitcode 2 If the header is missing or the UI style is invalid.
# -----------------------------------------------------------------------------
_zsh_ui_table() {
  emulate -L zsh
  (( $# )) || return 2

  local header="$1"
  shift
  local -a raw_rows=("$@") rows=()
  local -a raw_columns=("${(@ps:\t:)header}") columns=()
  local -a raw_fields sanitized_fields
  local raw_row field

  for field in "${raw_columns[@]}"; do
    _zsh_ui_sanitize_text "$field"
    columns+=("$REPLY")
  done
  header="${(pj:\t:)columns}"

  for raw_row in "${raw_rows[@]}"; do
    raw_fields=("${(@ps:\t:)raw_row}")
    sanitized_fields=()
    for field in "${raw_fields[@]}"; do
      _zsh_ui_sanitize_text "$field"
      sanitized_fields+=("$REPLY")
    done
    rows+=("${(pj:\t:)sanitized_fields}")
  done

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum ]]; then
    local input="${(j:\n:)rows}"
    if print -r -- "$input" | CLICOLOR_FORCE=1 command gum table \
        --print \
        --separator $'\t' \
        --columns "${(j:,:)columns}" \
        --border rounded \
        --border.foreground 212 \
        --header.foreground 75 2>/dev/null; then
      return 0
    fi
    mode="ansi"
  fi

  _zsh_ui_set_palette "$mode"
  local -a lines=("$header" "${rows[@]}")
  local -a widths=()
  local line
  local -a fields
  local -i column_index line_index

  for line in "${lines[@]}"; do
    fields=("${(@ps:\t:)line}")
    for (( column_index = 1;
        column_index <= ${#columns[@]};
        column_index++ )); do
      field="${fields[$column_index]-}"
      (( ${#field} > ${widths[$column_index]:-0} )) &&
        widths[$column_index]=${#field}
    done
  done

  for (( line_index = 1; line_index <= ${#lines[@]}; line_index++ )); do
    fields=("${(@ps:\t:)lines[$line_index]}")
    (( line_index == 1 )) && printf '%s' "$_ZSH_UI_HEADING"
    for (( column_index = 1;
        column_index <= ${#columns[@]};
        column_index++ )); do
      field="${fields[$column_index]-}"
      if (( column_index < ${#columns[@]} )); then
        printf '%-*s  ' "${widths[$column_index]}" "$field"
      else
        printf '%s' "$field"
      fi
    done
    (( line_index == 1 )) && printf '%s' "$_ZSH_UI_RESET"
    printf '\n'
  done
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
  local prompt="${1:-Continue?}"
  local reply

  if [[ ! -t 0 ]]; then
    _zsh_ui_log error "Cannot prompt: stdin is not a terminal."
    return 1
  fi

  _zsh_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum && -t 1 ]]; then
    command gum confirm --default=false "$prompt"
    return $?
  fi

  _zsh_ui_set_palette "$mode"
  printf '%s%s [y/N]: %s' "$_ZSH_UI_WARN" "$prompt" "$_ZSH_UI_RESET"
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
    command gum spin --spinner dot --title "$label" -- "$@"
  else
    _zsh_ui_log info "$label"
    command "$@"
  fi
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
# @description Prints a bordered title block with an optional subtitle.
# @arg $1 string Title text.
# @arg $2 string Optional subtitle text.
# -----------------------------------------------------------------------------
_shared_banner() {
  local title="$1"
  local subtitle="${2:-}"
  _shared_rule "="
  _zsh_ui_heading "$title" "$subtitle"
  _shared_rule "="
  printf "\n"
}

# -----------------------------------------------------------------------------
# _shared_section
# @internal
# @description Prints a section label followed by a rule.
# @arg $1 string Section title.
# -----------------------------------------------------------------------------
_shared_section() {
  local ZSH_UI_STYLE="${ZSH_UI_STYLE:-auto}"
  _zsh_ui_section "$1"
  _shared_rule "-"
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
