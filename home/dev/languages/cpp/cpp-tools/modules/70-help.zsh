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
  "Utilities" "cpparchive" "[-y|--yes]" "Archive the current contest."
_cp_help_register \
  "Utilities" "cppdiag" "" "Inspect the toolchain and environment."
_cp_help_register \
  "Utilities" "cpphealth" "" "Validate templates and required tools."
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
# Render the command registry in the shared terminal style, like zfuncs: a
# framed title, uppercase categories with their command counts, and
# borderless command rows. Narrow terminals use two-line records without
# dropping descriptions. Plain output keeps the same order and nothing else.
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
  local -A section_count=()
  # The syntax column holds the command and its arguments together.
  local -i syntax_width=10 description_width=0

  for row in "${_CP_HELP_ROWS[@]}"; do
    fields=("${(@ps:\t:)row}")
    syntax="${fields[2]-}${fields[3]:+ ${fields[3]}}"
    description="${fields[4]-}"
    (( section_count[${fields[1]-}]++ ))
    (( ${#syntax} > syntax_width )) && syntax_width=${#syntax}
    (( ${#description} > description_width )) &&
      description_width=${#description}
  done

  # Styled rows sit one indent in under their category and keep a right
  # margin; plain rows keep two spaces.
  local indent="  " muted="" reset=""
  local -i margin=0
  if [[ "$mode" != plain ]]; then
    indent="${(l:$(( _ZSH_UI_GUTTER + _ZSH_UI_INDENT )):: :)}"
    margin=$_ZSH_UI_GUTTER
    muted="$C_MUTED"
    reset="$C_RESET"
  fi
  # Two columns when the description keeps a readable width: styled output
  # wraps it within its column, plain output only when it fits whole.
  local -i room=$(( width - ${#indent} - syntax_width - 2 - margin ))
  local -i wide=0
  if [[ "$mode" == plain ]]; then
    (( room >= description_width )) && wide=1
  else
    (( room >= 24 )) && wide=1
  fi
  local -a wrapped
  local piece
  local continuation="${(l:$(( ${#indent} + syntax_width + 2 )):: :)}"

  local subtitle="${#_CP_HELP_ROWS[@]} commands · "
  subtitle+="${#_CP_HELP_SECTIONS[@]} categories · cpptools <command>"
  if [[ "$mode" != plain ]]; then
    _cp_heading "CPP-TOOLS" "$subtitle" || return $?
  else
    print -r -- "CPP-TOOLS"
    print -r -- "$subtitle"
    _cp_ui_call _zsh_ui_rule - "$width"
  fi
  print -r -- ""

  for section in "${_CP_HELP_SECTIONS[@]}"; do
    _cp_ui_call _zsh_ui_subsection "${(U)section}" "$width" \
      "${section_count[$section]}" || return $?

    for row in "${_CP_HELP_ROWS[@]}"; do
      fields=("${(@ps:\t:)row}")
      row_section="${fields[1]-}"
      [[ "$row_section" == "$section" ]] || continue
      _cp_ui_sanitize_text "${fields[2]-}"
      command="$REPLY"
      _cp_ui_sanitize_text "${fields[3]-}"
      arguments="$REPLY"
      _cp_ui_sanitize_text "${fields[4]-}"
      description="$REPLY"

      syntax="${C_CYAN}${command}${C_RESET}${arguments:+ $arguments}"
      if (( wide )); then
        _zsh_ui_wrap "$room" "$description"
        wrapped=("${reply[@]}")
        local -i pad=$(( syntax_width - ${#command} - ${#arguments} -
          ${#arguments:+1} + 2 ))
        print -r -- "${indent}${syntax}${(l:$pad:: :)}${muted}${wrapped[1]}${reset}"
        for piece in "${(@)wrapped[2,-1]}"; do
          print -r -- "${continuation}${muted}${piece}${reset}"
        done
      else
        print -r -- "${indent}${syntax}"
        print -r -- "${indent}  ${muted}${description}${reset}"
      fi
    done
    print -r -- ""
  done

  _cp_ui_call _zsh_ui_subsection "WORKSPACE" "$width" || return $?
  _cp_ui_call _zsh_ui_definition_list \
    "Root"$'\t'"$CP_WORKSPACE_ROOT" \
    "Algorithms"$'\t'"$CP_ALGORITHMS_DIR" || return $?
  print -r -- ""
  print -r -- "${indent}${muted}Commands use the focused target or newest"\
" source. Workspace checks guard every mutation.${reset}"
  print -r -- ""
}

# Display the load message only when explicitly enabled.
: "${CP_QUIET_LOAD:=0}"
if [[ "$CP_QUIET_LOAD" == 0 ]]; then
  _cp_success "Competitive Programming utilities loaded. Run cpphelp."
fi

# ============================================================================ #
# End of 70-help.zsh
