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
  local sep="${C_CYAN}  ───────────────────────────────────────────────────────────────────────────${C_RESET}"
  cat << EOF

${C_BOLD}${C_CYAN}  cpp-tools${C_RESET}${C_BOLD} · Competitive Programming Utilities${C_RESET}
${sep}

${C_BOLD}  Setup & Configuration${C_RESET}
    ${C_GREEN}cppinit${C_RESET}                               Initialize or verify a project directory
    ${C_GREEN}cppnew${C_RESET}     ${C_YELLOW}[name] [template]${C_RESET}          Create a .cpp from template (default/pbds/advanced/base)
    ${C_GREEN}cppdelete${C_RESET}  ${C_YELLOW}[name...]${C_RESET}                  Delete one or more problems (interactive)
    ${C_GREEN}cppbatch${C_RESET}   ${C_YELLOW}[count] [template]${C_RESET}         Create multiple problems at once (A, B, C, …)
    ${C_GREEN}cppconf${C_RESET}    ${C_YELLOW}[build-type] [compiler]${C_RESET}    (Re)configure the project build
               ${C_YELLOW}[timing=on/off] [pch=on/off/auto]${C_RESET}   flags: ${C_YELLOW}[-b] [-c] [--timing] [--pch] [--pch-rebuild]${C_RESET}
    ${C_GREEN}cppcontest${C_RESET} ${C_YELLOW}[dir_name]${C_RESET}                 Create a new contest directory and initialize it

${sep}
${C_BOLD}  Build, Run & Test${C_RESET}
    ${C_GREEN}cppbuild${C_RESET}    ${C_YELLOW}[name]${C_RESET}                    Build a target (defaults to most recent)
    ${C_GREEN}cpprun${C_RESET}      ${C_YELLOW}[name]${C_RESET}                    Run a compiled target
    ${C_GREEN}cppgo${C_RESET}       ${C_YELLOW}[--force] [name] [input]${C_RESET}  Build and run (uses <name>.in by default)
    ${C_GREEN}cppforcego${C_RESET}  ${C_YELLOW}[name]${C_RESET}                    Force-rebuild and run (updates timestamp)
    ${C_GREEN}cppi${C_RESET}        ${C_YELLOW}[name]${C_RESET}                    Interactive mode: build and run with stdin
    ${C_GREEN}cppjudge${C_RESET}    ${C_YELLOW}[name]${C_RESET}                    Test against ${C_YELLOW}name.in${C_RESET} / ${C_YELLOW}name.*.in${C_RESET} / ${C_YELLOW}name_*.in${C_RESET}
    ${C_GREEN}cppstress${C_RESET}   ${C_YELLOW}[name] [n]${C_RESET}                Stress-test a solution for n iterations (default: 100)

${sep}
${C_BOLD}  Compiler Selection${C_RESET}
    ${C_GREEN}cppgcc${C_RESET}      ${C_YELLOW}[build-type]${C_RESET}              Configure with GCC (default: Debug)
    ${C_GREEN}cppclang${C_RESET}    ${C_YELLOW}[build-type]${C_RESET}              Configure with Clang (default: Debug)
    ${C_GREEN}cppprof${C_RESET}                               Configure profiling build (Clang + timing)
    ${C_GREEN}cppinfo${C_RESET}                               Show current compiler and build configuration

${sep}
${C_BOLD}  Utilities${C_RESET}
    ${C_GREEN}cppfocus${C_RESET}    ${C_YELLOW}[name|--clear]${C_RESET}            Pin or clear the default target
    ${C_GREEN}cppwatch${C_RESET}    ${C_YELLOW}[name]${C_RESET}                    Auto-rebuild on file change (requires fswatch)
    ${C_GREEN}cppclean${C_RESET}                              Remove build artifacts
    ${C_GREEN}cppdeepclean${C_RESET}                          Remove all generated files (interactive)
    ${C_GREEN}cppstats${C_RESET}                              Show timing statistics for problems
    ${C_GREEN}cpparchive${C_RESET}                            Create a compressed archive of the contest
    ${C_GREEN}cppdiag${C_RESET}                               Display detailed toolchain diagnostic info
    ${C_GREEN}cppcheck${C_RESET}                              Check template system and environment health
    ${C_GREEN}cpphelp${C_RESET}                               Show this help message

${sep}
${C_BOLD}  Submission Preparation${C_RESET}
    ${C_GREEN}cppsubmit${C_RESET}     ${C_YELLOW}[--strict] [name]${C_RESET}           Generate a single-file submission
    ${C_GREEN}cpptestsubmit${C_RESET} ${C_YELLOW}[--strict] [name] [input]${C_RESET}   Test the generated submission file
    ${C_GREEN}cppfull${C_RESET}       ${C_YELLOW}[name] [input]${C_RESET}              Full workflow: dev test → generate → test submission

${sep}
${C_BOLD}  Aliases & Shortcuts${C_RESET}
    ${C_GREEN}cppgo_A${C_RESET}, ${C_GREEN}cppgo_B${C_RESET}, …                   Quick run for problem_A, problem_B, …
    ${C_GREEN}cppgo_A1${C_RESET}, ${C_GREEN}cppgo_A2${C_RESET}, …                 Quick run for numbered variants (problem_A1, …)

    ${C_BOLD}Short:${C_RESET}  ${C_GREEN}cppc${C_RESET}=cppconf  ${C_GREEN}cppb${C_RESET}=cppbuild  ${C_GREEN}cppr${C_RESET}=cpprun  ${C_GREEN}cppg${C_RESET}=cppgo

${sep}
${C_BOLD}  Workspace${C_RESET}
    Root:        ${C_CYAN}${CP_WORKSPACE_ROOT}${C_RESET}
    Algorithms:  ${C_CYAN}${CP_ALGORITHMS_DIR}${C_RESET}
    Entrypoint:  ${C_CYAN}cpptools <cmd>${C_RESET}

  ${C_CYAN}·${C_RESET} Commands default to the focused target or the most recently modified .cpp file.
  ${C_CYAN}·${C_RESET} Workspace protection prevents initialization outside the CP directory.

EOF
}

# Display load message only if not in quiet mode.
: "${CP_QUIET_LOAD:=0}"
if [ "$CP_QUIET_LOAD" = "0" ]; then
  echo "${C_GREEN}Competitive Programming utilities loaded. Type 'cpphelp' for commands.${C_RESET}"
fi

# ============================================================================ #
# End of 70-help.zsh
