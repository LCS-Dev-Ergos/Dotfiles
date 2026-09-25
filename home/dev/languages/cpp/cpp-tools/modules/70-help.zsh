# ============================================================================ #
# +++++++++++++++++++++++++++++++ HELP & USAGE +++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Canonical command reference and startup messaging for cpp-tools. Every UI
# mode consumes the same registry, preventing Gum and fallback output drift.
# ============================================================================ #

typeset -ga _CP_HELP_SECTIONS=(
  "Setup & Configuration"
  "Build, Run & Test"
  "Compiler Selection"
  "Utilities"
  "Submission Preparation"
  "Aliases & Shortcuts"
)

typeset -ga _CP_HELP_ROWS=()

_cp_help_register() {
  _CP_HELP_ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4")
}

_cp_help_register \
  "Setup & Configuration" "cppinit" "" \
  "Initialize or verify a project."
_cp_help_register \
  "Setup & Configuration" "cppnew" "[--no-config] [name] [template]" \
  "Create a source file from a selected template."
_cp_help_register \
  "Setup & Configuration" "cppdelete" \
  "[-y|--yes] [--no-config] <target...>" \
  "Delete problems and their generated files."
_cp_help_register \
  "Setup & Configuration" "cppbatch" "[count] [template]" \
  "Create sequential lettered problems."
_cp_help_register \
  "Setup & Configuration" "cppconf" \
  "[options] [build-type] [compiler]" \
  "Configure the active CMake build profile."
_cp_help_register \
  "Setup & Configuration" "cppcontest" "<directory>" \
  "Create and initialize a contest directory."

_cp_help_register \
  "Build, Run & Test" "cppbuild" "[target]" "Build a target."
_cp_help_register \
  "Build, Run & Test" "cpprun" "[target]" "Run a compiled target."
_cp_help_register \
  "Build, Run & Test" "cppgo" \
  "[--force] [--input file] [target] [input]" \
  "Build and run a target with optional input."
_cp_help_register \
  "Build, Run & Test" "cppforcego" "[target] [input]" \
  "Force a rebuild, then run the target."
_cp_help_register \
  "Build, Run & Test" "cppi" "[target]" \
  "Build and run with terminal input."
_cp_help_register \
  "Build, Run & Test" "cppjudge" "[target]" \
  "Run all discovered sample cases."
_cp_help_register \
  "Build, Run & Test" "cppstress" "[target] [iterations]" \
  "Repeat execution with a timeout."

_cp_help_register \
  "Compiler Selection" "cppgcc" "[build-type]" "Configure with GCC."
_cp_help_register \
  "Compiler Selection" "cppclang" "[build-type]" \
  "Configure with Clang."
_cp_help_register \
  "Compiler Selection" "cppprof" "" "Configure a profiling build."
_cp_help_register \
  "Compiler Selection" "cppinfo" "" \
  "Show the active build configuration."

_cp_help_register \
  "Utilities" "cppfocus" "[target|--clear]" \
  "Pin or clear the default target."
_cp_help_register \
  "Utilities" "cppwatch" "[target]" \
  "Rebuild when the source changes."
_cp_help_register \
  "Utilities" "cppclean" "[-y|--yes]" "Remove build artifacts."
_cp_help_register \
  "Utilities" "cppdeepclean" "" "Remove all generated project files."
_cp_help_register \
  "Utilities" "cppstats" "" "Show elapsed problem times."
_cp_help_register \
  "Utilities" "cpparchive" "" "Archive the current contest."
_cp_help_register \
  "Utilities" "cppdiag" "" "Inspect the toolchain and environment."
_cp_help_register \
  "Utilities" "cppcheck" "" "Validate templates and required tools."
_cp_help_register \
  "Utilities" "cpphelp" "" "Show this command reference."

_cp_help_register \
  "Submission Preparation" "cppsubmit" "[--strict] [target]" \
  "Generate a single-file submission."
_cp_help_register \
  "Submission Preparation" "cpptestsubmit" \
  "[--no-generate] [--strict] [target] [input]" \
  "Compile and test a submission."
_cp_help_register \
  "Submission Preparation" "cppfull" \
  "[--strict] [target] [input]" \
  "Run the complete submission workflow."

_cp_help_register \
  "Aliases & Shortcuts" "cppgo_A ... cppgo_H" "" \
  "Run lettered problems."
_cp_help_register \
  "Aliases & Shortcuts" "cppgo_A1, cppgo_A2, ..." "" \
  "Run numbered variants."
_cp_help_register \
  "Aliases & Shortcuts" "cppc / cppb / cppr / cppg" "" \
  "Short command aliases."

unfunction _cp_help_register

# -----------------------------------------------------------------------------
# cpphelp
# -----------------------------------------------------------------------------
# Render the command registry using the same visual grammar as zfuncs: a compact
# heading, light rules, uppercase categories, and borderless command rows.
# Narrow terminals use two-line records without dropping descriptions.
# -----------------------------------------------------------------------------
function cpphelp() {
  emulate -L zsh
  if (( $# )); then
    _cp_error "Usage: cpphelp"
    return 64
  fi

  _cp_ui_refresh || return $?
  _cp_ui_resolve_mode || return $?
  local mode="$REPLY"
  _cp_ui_width || return $?
  local -i width=$REPLY
  local section row row_section command arguments description syntax
  local -a fields
  local -i name_width=10 arguments_width=0 description_width=0

  for row in "${_CP_HELP_ROWS[@]}"; do
    fields=("${(@ps:\t:)row}")
    command="${fields[2]-}"
    arguments="${fields[3]-}"
    description="${fields[4]-}"
    (( ${#command} > name_width )) && name_width=${#command}
    (( ${#arguments} > arguments_width )) &&
      arguments_width=${#arguments}
    (( ${#description} > description_width )) &&
      description_width=${#description}
  done

  local -i wide_required=$(( name_width + arguments_width +
    description_width + 6 ))
  local -i wide=0
  (( wide_required <= width )) && wide=1

  local rule_character="-" rule_color="" muted="" reset=""
  if [[ "$mode" != plain ]]; then
    rule_character="─"
    rule_color=$'\e[38;5;245m'
    muted=$'\e[38;5;252m'
    reset="$C_RESET"
    _cp_heading \
      "CPP-TOOLS" \
      "${#_CP_HELP_ROWS[@]} commands · "\
"${#_CP_HELP_SECTIONS[@]} categories · "\
"cpptools <command>"
  else
    print -r -- "CPP-TOOLS"
    print -r -- \
      "${#_CP_HELP_ROWS[@]} commands · "\
"${#_CP_HELP_SECTIONS[@]} categories · "\
"cpptools <command>"
  fi

  _cp_repeat "$rule_character" "$width"
  print -r -- "${rule_color}${REPLY}${reset}"
  print -r -- ""

  for section in "${_CP_HELP_SECTIONS[@]}"; do
    local category_title="${(U)section}"
    local -i category_rule_width=$(( ${#category_title} + 4 ))
    (( category_rule_width < 24 )) && category_rule_width=24
    (( category_rule_width > 48 )) && category_rule_width=48
    (( category_rule_width > width - 2 )) &&
      category_rule_width=$(( width - 2 ))
    _cp_repeat "$rule_character" "$category_rule_width"
    local category_rule="$REPLY"

    if [[ "$mode" == plain ]]; then
      print -r -- "$category_title"
      print -r -- "  $category_rule"
    else
      _cp_section "$category_title" || return $?
      print -r -- "${rule_color}  ${category_rule}${reset}"
    fi

    for row in "${_CP_HELP_ROWS[@]}"; do
      fields=("${(@ps:\t:)row}")
      row_section="${fields[1]-}"
      [[ "$row_section" == "$section" ]] || continue
      command="${fields[2]-}"
      arguments="${fields[3]-}"
      description="${fields[4]-}"

      _cp_ui_sanitize_text "$command"
      command="$REPLY"
      _cp_ui_sanitize_text "$arguments"
      arguments="$REPLY"
      _cp_ui_sanitize_text "$description"
      description="$REPLY"

      if (( wide )); then
        printf '  %s%-*s%s  %s%-*s%s  %s%s%s\n' \
          "$C_CYAN" "$name_width" "$command" "$C_RESET" \
          "$C_YELLOW" "$arguments_width" "$arguments" "$C_RESET" \
          "$muted" "$description" "$reset"
      else
        syntax="  ${C_CYAN}${command}${C_RESET}"
        [[ -z "$arguments" ]] ||
          syntax+=" ${C_YELLOW}${arguments}${C_RESET}"
        print -r -- "$syntax"
        print -r -- "    ${muted}${description}${reset}"
      fi
    done
    print -r -- ""
  done

  local root algorithms
  _cp_ui_sanitize_text "$CP_WORKSPACE_ROOT"
  root="$REPLY"
  _cp_ui_sanitize_text "$CP_ALGORITHMS_DIR"
  algorithms="$REPLY"
  local workspace_title="WORKSPACE"
  _cp_repeat "$rule_character" 24
  local workspace_rule="$REPLY"
  if [[ "$mode" == plain ]]; then
    print -r -- "$workspace_title"
    print -r -- "  $workspace_rule"
  else
    _cp_section "$workspace_title" || return $?
    print -r -- "${rule_color}  ${workspace_rule}${reset}"
  fi
  print -r -- "  ${C_CYAN}Root${C_RESET}        $root"
  print -r -- "  ${C_CYAN}Algorithms${C_RESET}  $algorithms"
  print -r -- ""
  print -r -- \
    "${muted}Commands use the focused target or newest source. "\
"Workspace checks guard every mutation.${reset}"
  print -r -- ""
}

# Display the load message only when explicitly enabled.
: "${CP_QUIET_LOAD:=0}"
if [[ "$CP_QUIET_LOAD" == 0 ]]; then
  _cp_success "Competitive Programming utilities loaded. Run cpphelp."
fi

# ============================================================================ #
# End of 70-help.zsh
