# ============================================================================ #
# +++++++++++++++++++++++++++++++ HELP & USAGE +++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Help output and startup messaging for cpp-tools.
#
# Functions:
#   - cpphelp  Display the full command reference.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cpphelp
# -----------------------------------------------------------------------------
# Print a formatted command reference for cpp-tools.
# -----------------------------------------------------------------------------
function cpphelp() {
  cat << EOF
${C_BOLD}Enhanced CMake Utilities for Competitive Programming:${C_RESET}

${C_BOLD}${C_CYAN}[ SETUP & CONFIGURATION ]${C_RESET}
  ${C_GREEN}cppinit${C_RESET}                       - Initializes or verifies a project directory (workspace-protected).
  ${C_GREEN}cppnew${C_RESET} ${C_YELLOW}[name] [template]${C_RESET}      - Creates a new .cpp file from a template ('default', 'pbds', 'advanced', 'base').
  ${C_GREEN}cppdelete${C_RESET} ${C_YELLOW}[name...]${C_RESET}           - Deletes one or more problems (space/comma-separated, interactive).
  ${C_GREEN}cppbatch${C_RESET} ${C_YELLOW}[count] [tpl]${C_RESET}        - Creates multiple problems at once (A, B, C, ...).
  ${C_GREEN}cppconf${C_RESET} ${C_YELLOW}[type] [compiler] ${C_RESET}    - (Re)configures the project (Debug/Release/Sanitize, gcc/clang/auto, timing reports).
          ${C_YELLOW}[timing=on/off]${C_RESET}
  ${C_GREEN}cppcontest${C_RESET} ${C_YELLOW}[dir_name]${C_RESET}         - Creates a new contest directory and initializes it.

${C_BOLD}${C_CYAN}[ BUILD, RUN, TEST ]${C_RESET}
  ${C_GREEN}cppbuild${C_RESET} ${C_YELLOW}[name]${C_RESET}               - Builds a target (defaults to most recent).
  ${C_GREEN}cpprun${C_RESET} ${C_YELLOW}[name]${C_RESET}                 - Runs a target's executable.
  ${C_GREEN}cppgo${C_RESET} ${C_YELLOW}[name] [input]${C_RESET}          - Builds and runs. Uses '<name>.in' by default.
  ${C_GREEN}cppforcego${C_RESET} ${C_YELLOW}[name]${C_RESET}             - Force rebuild and run (updates timestamp).
  ${C_GREEN}cppi${C_RESET} ${C_YELLOW}[name]${C_RESET}                   - Interactive mode: builds and runs with manual input.
  ${C_GREEN}cppjudge${C_RESET} ${C_YELLOW}[name]${C_RESET}               - Tests against all sample cases with timing info.
  ${C_GREEN}cppstress${C_RESET} ${C_YELLOW}[name] [n]${C_RESET}          - Stress tests a solution for n iterations (default: 100).

${C_BOLD}${C_CYAN}[ COMPILER SELECTION ]${C_RESET}
  ${C_GREEN}cppgcc${C_RESET} ${C_YELLOW}[type]${C_RESET}                 - Configure with GCC compiler (defaults to Debug).
  ${C_GREEN}cppclang${C_RESET} ${C_YELLOW}[type]${C_RESET}               - Configure with Clang compiler (defaults to Debug).
  ${C_GREEN}cppprof${C_RESET}                       - Configure profiling build with Clang and timing enabled.
  ${C_GREEN}cppinfo${C_RESET}                       - Shows current compiler and build configuration.

${C_BOLD}${C_CYAN}[ UTILITIES ]${C_RESET}
  ${C_GREEN}cppwatch${C_RESET} ${C_YELLOW}[name]${C_RESET}               - Auto-rebuilds a target on file change (requires fswatch).
  ${C_GREEN}cppclean${C_RESET}                      - Removes build artifacts.
  ${C_GREEN}cppdeepclean${C_RESET}                  - Removes all generated files (interactive).
  ${C_GREEN}cppstats${C_RESET}                      - Shows timing statistics for problems.
  ${C_GREEN}cpparchive${C_RESET}                    - Creates a compressed archive of the contest.
  ${C_GREEN}cppdiag${C_RESET}                       - Displays detailed diagnostic info about the toolchain.
  ${C_GREEN}cpphelp${C_RESET}                       - Shows this help message.
${C_BOLD}${C_CYAN}[ SUBMISSION PREPARATION ]${C_RESET}
  ${C_GREEN}cppsubmit${C_RESET} ${C_YELLOW}[name]${C_RESET}              - Generates a single-file submission (flattener-based).
  ${C_GREEN}cpptestsubmit${C_RESET} ${C_YELLOW}[name] [input]${C_RESET}  - Tests the generated submission file.
  ${C_GREEN}cppfull${C_RESET} ${C_YELLOW}[name] [input]${C_RESET}        - Full workflow: test dev version, generate submission, test submission.
  ${C_GREEN}cppcheck${C_RESET}                      - Checks the health of the template system and environment.

${C_BOLD}${C_CYAN}[ QUICK ACCESS ALIASES ]${C_RESET}
  ${C_GREEN}cppgo_A${C_RESET}, ${C_GREEN}cppgo_B${C_RESET}, etc.        - Quick run for problem_A, problem_B, etc.
  ${C_GREEN}cppgo_A1${C_RESET}, ${C_GREEN}cppgo_A2${C_RESET}, etc.      - Quick run for numbered variants (problem_A1, problem_A2, etc.).

  Short aliases:
    ${C_GREEN}cppc${C_RESET}=cppconf, ${C_GREEN}cppb${C_RESET}=cppbuild, ${C_GREEN}cppr${C_RESET}=cpprun, ${C_GREEN}cppg${C_RESET}=cppgo, and more.

${C_BOLD}${C_MAGENTA}[ WORKSPACE INFO ]${C_RESET}
  Workspace Root: ${C_CYAN}${CP_WORKSPACE_ROOT}${C_RESET}
  Algorithms Dir: ${C_CYAN}${CP_ALGORITHMS_DIR}${C_RESET}

* Most commands default to the most recently modified C++ source file.
* Workspace protection prevents accidental initialization outside CP directory.
EOF
}

# Display load message only if not in quiet mode.
: "${CP_QUIET_LOAD:=0}"
if [ "$CP_QUIET_LOAD" = "0" ]; then
  echo "${C_GREEN}Competitive Programming utilities loaded. Type 'cpphelp' for commands.${C_RESET}"
fi

# ============================================================================ #
# End of 70-help.zsh
