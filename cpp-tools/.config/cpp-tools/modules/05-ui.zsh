# ============================================================================ #
# +++++++++++++++++++++++++++++ SHARED UI LAYER ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Terminal output primitives shared by every cpp-tools command. Gum is
# optional and reserved for interactions, spinners, and larger visual blocks;
# routine output remains Zsh-native and always has ANSI/plain fallbacks.
# ============================================================================ #

: "${CP_UI_STYLE:=auto}"
: "${CP_UI_WIDTH:=auto}"

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
# _cp_ui_set_palette
# -----------------------------------------------------------------------------
# Install the shared ANSI palette for ansi/gum modes or empty values for plain.
# -----------------------------------------------------------------------------
_cp_ui_set_palette() {
  emulate -L zsh
  local mode="$1"

  if [[ "$mode" == plain ]]; then
    typeset -g C_RESET="" C_BOLD="" C_RED="" C_GREEN=""
    typeset -g C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
    return 0
  fi

  typeset -g C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
  typeset -g C_RED=$'\e[31m' C_GREEN=$'\e[32m'
  typeset -g C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
  typeset -g C_MAGENTA=$'\e[35m' C_CYAN=$'\e[36m'
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
# Resolve the requested UI width, clamp it to 40-160 columns, and store it in
# REPLY. CP_UI_WIDTH accepts an integer or "auto".
# -----------------------------------------------------------------------------
_cp_ui_width() {
  emulate -L zsh
  local requested="${1:-${CP_UI_WIDTH:-auto}}"
  local -i width

  if [[ "$requested" == auto || -z "$requested" ]]; then
    width=${COLUMNS:-80}
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
# _cp_repeat
# -----------------------------------------------------------------------------
# Store a repeated glyph string in REPLY without spawning a subprocess.
# -----------------------------------------------------------------------------
_cp_repeat() {
  emulate -L zsh
  local glyph="$1"
  local -i count="${2:-0}"
  REPLY=""
  (( count > 0 )) || return 0
  printf -v REPLY "%${count}s" ""
  REPLY="${REPLY// /$glyph}"
}

# -----------------------------------------------------------------------------
# _cp_banner_line
# -----------------------------------------------------------------------------
# Compose a width-aware native banner used by existing command output.
# -----------------------------------------------------------------------------
_cp_banner_line() {
  emulate -L zsh
  local edge_l="$1" edge_r="$2" title="$3" color_name="$4"
  local color
  local label left right
  local -i width left_fill=6 right_fill

  _cp_ui_refresh || return $?
  case "$color_name" in
    blue) color="$C_BLUE" ;;
    cyan) color="$C_CYAN" ;;
    green) color="$C_GREEN" ;;
    yellow) color="$C_YELLOW" ;;
    red) color="$C_RED" ;;
    magenta) color="$C_MAGENTA" ;;
    *) return 2 ;;
  esac
  _cp_ui_width || return $?
  width=$REPLY
  _cp_ui_sanitize_text "$title"
  title="$REPLY"

  if [[ -n "$title" ]]; then
    label=" $title "
    right_fill=$(( width - ${#edge_l} - ${#edge_r} - left_fill -
      ${#label} ))
    if (( right_fill < 2 )); then
      printf '%s%s%s%s\n' "$color" "$C_BOLD" "$title" "$C_RESET"
      return 0
    fi
    _cp_repeat "─" "$left_fill"
    left="$REPLY"
    _cp_repeat "─" "$right_fill"
    right="$REPLY"
    printf '%s%s%s%s%s%s%s%s\n' \
      "$color" "$edge_l" "$left" "$C_BOLD$label$C_RESET" \
      "$color" "$right" "$edge_r" "$C_RESET"
    return 0
  fi

  _cp_repeat "─" $(( width - ${#edge_l} - ${#edge_r} ))
  printf '%s%s%s%s%s\n' \
    "$color" "$edge_l" "$REPLY" "$edge_r" "$C_RESET"
}

_cp_box_top() {
  _cp_banner_line "╔═══" "═══╗" "${1:-}" "${2:-blue}"
}

_cp_box_bottom() {
  _cp_banner_line "╚═══" "═══╝" "${1:-}" "${2:-blue}"
}

_cp_rule() {
  _cp_banner_line "════" "════" "${1:-}" "${2:-blue}"
}

_cp_header() {
  _cp_rule "$1" "${2:-blue}"
}

# -----------------------------------------------------------------------------
# _cp_heading / _cp_section
# -----------------------------------------------------------------------------
# Render larger headings with at most one Gum process; section labels stay
# native because spawning Gum for individual lines adds no value.
# -----------------------------------------------------------------------------
_cp_heading() {
  emulate -L zsh
  local title="$1" subtitle="${2:-}" content
  _cp_ui_sanitize_text "$title"
  title="$REPLY"
  _cp_ui_sanitize_text "$subtitle"
  subtitle="$REPLY"
  content="$title"
  [[ -z "$subtitle" ]] || content+=$'\n'"$subtitle"

  _cp_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum ]]; then
    CLICOLOR_FORCE=1 command gum style \
      --bold --foreground 6 "$content" 2>/dev/null && return 0
    mode="ansi"
  fi

  _cp_ui_set_palette "$mode"
  print -r -- "${C_BOLD}${C_CYAN}${title}${C_RESET}"
  [[ -z "$subtitle" ]] || print -r -- "$subtitle"
}

_cp_section() {
  _cp_ui_refresh || return $?
  _cp_ui_sanitize_text "$1"
  print -r -- "${C_BOLD}${C_BLUE}${REPLY}${C_RESET}"
}

# -----------------------------------------------------------------------------
# _cp_ui_table
# -----------------------------------------------------------------------------
# Render tab-separated rows with Gum when the complete table fits. Narrow
# terminals receive a native key/value layout instead of clipped columns.
# -----------------------------------------------------------------------------
_cp_ui_table() {
  emulate -L zsh
  (( $# )) || return 2

  local header="$1"
  shift
  local -a raw_rows=("$@") rows=()
  local -a columns=("${(@ps:\t:)header}")
  local -a fields sanitized_fields widths=()
  local row field line
  local -i column_index line_index table_width=0 max_width

  for row in "${raw_rows[@]}"; do
    fields=("${(@ps:\t:)row}")
    sanitized_fields=()
    for field in "${fields[@]}"; do
      _cp_ui_sanitize_text "$field"
      sanitized_fields+=("$REPLY")
    done
    rows+=("${(pj:\t:)sanitized_fields}")
  done

  local -a lines=("$header" "${rows[@]}")
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

  for (( column_index = 1;
      column_index <= ${#columns[@]};
      column_index++ )); do
    (( table_width += ${widths[$column_index]:-0} ))
  done
  (( table_width += (${#columns[@]} - 1) * 3 ))
  _cp_ui_width || return $?
  max_width=$REPLY

  _cp_ui_resolve_mode || return $?
  local mode="$REPLY"
  if [[ "$mode" == gum && $table_width -le $(( max_width - 4 )) ]]; then
    local input="${(j:\n:)rows}"
    if print -r -- "$input" | CLICOLOR_FORCE=1 command gum table \
        --print \
        --separator $'\t' \
        --columns "${(j:,:)columns}" \
        --border rounded \
        --border.foreground 6 \
        --header.foreground 4 2>/dev/null; then
      return 0
    fi
    mode="ansi"
  fi

  _cp_ui_set_palette "$mode"
  if (( table_width > max_width )); then
    for row in "${rows[@]}"; do
      fields=("${(@ps:\t:)row}")
      for (( column_index = 1;
          column_index <= ${#columns[@]};
          column_index++ )); do
        printf '  %s%s:%s %s\n' \
          "$C_BOLD$C_BLUE" "$columns[$column_index]" "$C_RESET" \
          "${fields[$column_index]-}"
      done
      print -r -- ""
    done
    return 0
  fi

  for (( line_index = 1; line_index <= ${#lines[@]}; line_index++ )); do
    fields=("${(@ps:\t:)lines[$line_index]}")
    (( line_index == 1 )) && printf '%s%s' "$C_BOLD" "$C_BLUE"
    for (( column_index = 1;
        column_index <= ${#columns[@]};
        column_index++ )); do
      field="${fields[$column_index]-}"
      if (( column_index < ${#columns[@]} )); then
        printf '%-*s   ' "${widths[$column_index]}" "$field"
      else
        printf '%s' "$field"
      fi
    done
    (( line_index == 1 )) && printf '%s' "$C_RESET"
    printf '\n'
    if (( line_index == 1 )); then
      _cp_repeat "─" "$table_width"
      print -r -- "$REPLY"
    fi
  done
}

# -----------------------------------------------------------------------------
# _cp_ui_card
# -----------------------------------------------------------------------------
# Render a structured block with one Gum invocation and a native fallback.
# Body lines may contain palette escapes produced by trusted cpp-tools code.
# -----------------------------------------------------------------------------
_cp_ui_card() {
  emulate -L zsh
  local title="$1"
  shift
  local content line mode
  local -i width card_width

  _cp_ui_resolve_mode || return $?
  mode="$REPLY"
  _cp_ui_set_palette "$mode"
  _cp_ui_sanitize_text "$title"
  title="$REPLY"
  content="${C_BOLD}${C_CYAN}${title}${C_RESET}"
  for line in "$@"; do
    content+=$'\n'"$line"
  done

  _cp_ui_width || return $?
  width=$REPLY
  card_width=$(( width - 2 ))

  if [[ "$mode" == gum ]]; then
    CLICOLOR_FORCE=1 command gum style \
      --no-strip-ansi \
      --border rounded \
      --border-foreground 6 \
      --padding '1 2' \
      --width "$card_width" \
      "$content" 2>/dev/null && return 0
    _cp_ui_set_palette ansi
  fi

  print -r -- "${C_BOLD}${C_CYAN}${title}${C_RESET}"
  (( $# == 0 )) || print -r -- ""
  for line in "$@"; do
    print -r -- "$line"
  done
}

# -----------------------------------------------------------------------------
# _cp_kv and status helpers
# -----------------------------------------------------------------------------
_cp_kv() {
  _cp_ui_refresh || return $?
  _cp_ui_sanitize_text "$1"
  local label="$REPLY"
  _cp_ui_sanitize_text "$2"
  printf '    %s%-16s%s %s%s%s\n' \
    "$C_CYAN" "$label" "$C_RESET" "$C_YELLOW" "$REPLY" "$C_RESET"
}

_cp_success() {
  _cp_ui_refresh || return $?
  _cp_ui_sanitize_text "$*"
  print -r -- "${C_BOLD}${C_GREEN}${REPLY}${C_RESET}"
}

_cp_error() {
  _cp_ui_refresh || return $?
  _cp_ui_sanitize_text "$*"
  print -u2 -r -- "${C_BOLD}${C_RED}${REPLY}${C_RESET}"
}

_cp_warn() {
  _cp_ui_refresh || return $?
  _cp_ui_sanitize_text "$*"
  print -r -- "${C_YELLOW}${REPLY}${C_RESET}"
}

_cp_info() {
  _cp_ui_refresh || return $?
  _cp_ui_sanitize_text "$*"
  print -r -- "${C_CYAN}${REPLY}${C_RESET}"
}

# -----------------------------------------------------------------------------
# _cp_confirm / _cp_choose / _cp_spin
# -----------------------------------------------------------------------------
_cp_confirm() {
  emulate -L zsh
  local prompt="$1" default_answer="${2:-no}" response=""
  [[ "$default_answer" == yes || "$default_answer" == no ]] || return 2
  _cp_ui_sanitize_text "$prompt"
  prompt="$REPLY"

  if [[ ! -t 0 ]]; then
    [[ "$default_answer" == yes ]]
    return $?
  fi

  if _cp_ui_gum_for_fd 2 && [[ -t 0 ]]; then
    if [[ "$default_answer" == yes ]]; then
      GUM_CONFIRM_PROMPT_FOREGROUND=6 \
        GUM_CONFIRM_SELECTED_BACKGROUND=4 \
        command gum confirm --default=true "$prompt"
    else
      GUM_CONFIRM_PROMPT_FOREGROUND=6 \
        GUM_CONFIRM_SELECTED_BACKGROUND=4 \
        command gum confirm --default=false "$prompt"
    fi
    return $?
  fi

  if [[ "$default_answer" == yes ]]; then
    printf '%s (Y/n): ' "$prompt"
    read -r response || response=""
    [[ "$response" != [Nn] ]]
  else
    printf '%s (y/N): ' "$prompt"
    read -r response || response=""
    [[ "$response" == [Yy] ]]
  fi
}

_cp_choose() {
  emulate -L zsh
  local header="$1"
  shift
  (( $# )) || return 2
  _cp_ui_gum_for_fd 2 && [[ -t 0 ]] || return 1
  _cp_ui_sanitize_text "$header"
  GUM_CHOOSE_CURSOR_FOREGROUND=6 \
    GUM_CHOOSE_HEADER_FOREGROUND=4 \
    command gum choose --header "$REPLY" "$@"
}

_cp_spin() {
  emulate -L zsh
  local title="$1"
  shift
  (( $# )) || return 2
  _cp_ui_sanitize_text "$title"
  title="$REPLY"

  if _cp_ui_gum_for_fd 2; then
    local output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/cp-spin.XXXXXX") || {
      _cp_error "Unable to create the spinner output buffer."
      return 1
    }
    GUM_SPIN_SPINNER_FOREGROUND=6 \
      GUM_SPIN_TITLE_FOREGROUND=6 \
      command gum spin \
      --spinner line \
      --title "$title" \
      -- zsh -c \
      'output_file="$1"; shift; "$@" > "$output_file" 2>&1' \
      cp-spin "$output_file" "$@" >&2
    local command_status=$?
    if ! command cat -- "$output_file"; then
      (( command_status == 0 )) && command_status=1
    fi
    rm -f -- "$output_file"
    return "$command_status"
  fi

  "$@" 2>&1
}

_cp_ui_refresh && _cp_ui_width || {
  print -u2 -r -- "cpp-tools: invalid CP_UI_STYLE or CP_UI_WIDTH setting"
  return 2
}

# ============================================================================ #
# End of 05-ui.zsh
