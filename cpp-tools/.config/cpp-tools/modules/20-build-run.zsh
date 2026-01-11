# ============================================================================ #
# +++++++++++++++++++++++++++++++ BUILD & RUN ++++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Build, run, and test workflows for cpp-tools projects.
# Handles compilation, execution, stress testing, and judging.
#
# Functions:
#   - cppbuild    Build a target with formatted output.
#   - cpprun      Run a compiled binary (build if needed).
#   - cppgo       Build and run with optional input.
#   - cppforcego  Force rebuild and run by touching source.
#   - cppi        Run in interactive mode.
#   - cppjudge    Compare output against sample cases.
#   - cppstress   Stress test a target with timeouts.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cppbuild
# -----------------------------------------------------------------------------
# Build a target and print structured output, timing, and stats.
#
# Usage:
#   cppbuild [target]
# -----------------------------------------------------------------------------
function cppbuild() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  echo "${C_CYAN}Building target: ${C_BOLD}$target_name${C_RESET}..."

  # Record start time for total build duration.
  local start_time=$EPOCHREALTIME

  # Check if timing is enabled in CMake cache.
  local timing_enabled=false
  if [ -f "build/CMakeCache.txt" ]; then
    if grep -q "CP_ENABLE_TIMING:BOOL=ON" build/CMakeCache.txt 2>/dev/null; then
      timing_enabled=true
    fi
  fi

  # Capture both stdout and stderr to analyze build output.
  local build_output
  build_output=$(cmake --build build --target "$target_name" -j 2>&1)
  local build_status=$?

  # Calculate total build time.
  local end_time=$EPOCHREALTIME
  local elapsed_sec=$(( end_time - start_time ))
  local elapsed_str

  if (( elapsed_sec < 1 )); then
    printf -v elapsed_str "%.2fms" $(( elapsed_sec * 1000 ))
  else
    printf -v elapsed_str "%.2fs" $elapsed_sec
  fi

  # Handle build failures with full error output.
  if [ $build_status -ne 0 ]; then
    echo ""
    echo "${C_BOLD}${C_RED}╔═══--------- BUILD FAILED ---------═══╗${C_RESET}"
    echo "$build_output"
    printf "${C_RED}Build failed after %s${C_RESET}\n" "$elapsed_str"
    return 1
  fi

  # Show detailed output only if actual compilation occurred.
  if [[ "$build_output" == *"Building CXX object"* ]]; then
    # Real compilation happened - format the output for better readability.

    # 1. Print everything up to the compilation line.
    echo "$build_output" | sed -n '/Building CXX object/q;p'

    # 2. Print the compilation line itself.
    echo "$build_output" | grep "Building CXX object"

    # 3. Print timing statistics only if timing is enabled.
    if [ "$timing_enabled" = true ]; then
      echo ""
      echo "${C_BOLD}${C_CYAN}╔═══--------------------- Compilation Time Statistics ----------------------═══╗${C_RESET}"
      echo ""

      # Universal timing report finder for both GCC and Clang.
      local timing_report
      timing_report=$(echo "$build_output" | sed -n '/Time variable/,/TOTAL/p; /Pass execution timing report/,$p')

      if [ -n "$timing_report" ]; then
        # Extract only the relevant parts, stopping before the linking phase.
        echo "$timing_report" | sed '/Linking CXX executable/q'
      else
        echo " Compilation finished. (Timing report not found in output)."
      fi

      # Check if this is a Clang build and add trace analysis note.
      if [ -f "build/CMakeCache.txt" ] && grep -q "clang" build/CMakeCache.txt; then
        echo ""
        echo -e " Clang compilation finished."
        echo -e " ${C_CYAN}Note: To analyze the detailed trace with Perfetto UI, run:${C_RESET}"
        echo -e "   ${C_BOLD}${C_GREEN}cpptrace $target_name${C_RESET}"
      fi

      echo ""
      echo "${C_BOLD}${C_CYAN}╚═══--------------- Compilation Finished, Proceeding to Link ---------------═══╝${C_RESET}"
      echo ""
    fi

    # 4. Print the linking line and anything after it.
    echo "$build_output" | sed -n '/Linking CXX executable/,$p'
  else
    # Target up-to-date - show only the summary line.
    echo "$build_output" | tail -n 1
  fi

  # Display total build time.
  printf "${C_MAGENTA}Total build time: %s${C_RESET}\n" "$elapsed_str"

  return 0
}

# -----------------------------------------------------------------------------
# cpprun
# -----------------------------------------------------------------------------
# Run a compiled target, building it if necessary.
#
# Usage:
#   cpprun [target]
# -----------------------------------------------------------------------------
function cpprun() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  local exec_path="./bin/$target_name"

  if [ ! -f "$exec_path" ]; then
    echo "${C_YELLOW}Executable '$exec_path' not found. Building first...${C_RESET}"
    if ! cppbuild "$target_name"; then
      echo "${C_RED}Build failed!${C_RESET}" >&2
      return 1
    fi
  fi

  echo "${C_BLUE}Running '$exec_path'...${C_RESET}"
  "$exec_path"
}

# -----------------------------------------------------------------------------
# cppgo
# -----------------------------------------------------------------------------
# Build and run a target with optional input file redirection.
#
# Usage:
#   cppgo [target] [input_file]
# -----------------------------------------------------------------------------
function cppgo() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  local exec_path="./bin/$target_name"

  # Default to the problem's own input file if a second argument isn't given.
  local input_file=${2:-"${target_name}.in"}
  local input_path="input_cases/$input_file"

  echo "${C_CYAN}Building target '${C_BOLD}$target_name${C_CYAN}'...${C_RESET}"
  if cppbuild "$target_name"; then
    echo ""
    echo "${C_BLUE}════-------------------------------------════${C_RESET}"
    echo "${C_BLUE}${C_BOLD}RUNNING: $target_name${C_RESET}"

    # Track execution time.
    local start_time=$EPOCHREALTIME

    local exit_code=0
    if [ -f "$input_path" ]; then
      echo "(input from ${C_YELLOW}$input_path${C_RESET})"
      _run_with_timeout 5s "$exec_path" < "$input_path"
      exit_code=$?
    else
      if [ -n "$2" ]; then # Warn if a specific file was requested but not found.
        echo "${C_YELLOW}Warning: Input file '$input_path' not found.${C_RESET}" >&2
      fi
      _run_with_timeout 5s "$exec_path"
      exit_code=$?
    fi

    local end_time=$EPOCHREALTIME
    local elapsed_sec=$(( end_time - start_time ))

    # Check if the program was terminated due to timeout.
    if [ $exit_code -eq 124 ]; then
      echo "${C_YELLOW}⚠ Program terminated after 5-second timeout${C_RESET}"
    elif [ $exit_code -ne 0 ] && [ $exit_code -ne 124 ]; then
      echo "${C_RED}Program exited with code $exit_code${C_RESET}"
    fi

    echo "${C_BLUE}════------------- FINISHED --------------════${C_RESET}"
    if (( elapsed_sec < 1 )); then
      printf "${C_MAGENTA}Execution time: %.2fms${C_RESET}\n" $(( elapsed_sec * 1000 ))
    else
      printf "${C_MAGENTA}Execution time: %.2fs${C_RESET}\n" $elapsed_sec
    fi
  else
    echo "${C_RED}Build failed!${C_RESET}\n" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# cppforcego
# -----------------------------------------------------------------------------
# Force a rebuild by touching the source file, then run it.
#
# Usage:
#   cppforcego [target]
# -----------------------------------------------------------------------------
function cppforcego() {
  local target
  target=$(_get_default_target)
  local exec_name
  exec_name=$(echo "${1:-$target}" | sed -E 's/\.(cpp|cc|cxx)$//')

  # Find the source file corresponding to the target.
  local source_file
  for ext in cpp cc cxx; do
    if [ -f "${exec_name}.${ext}" ]; then
      source_file="${exec_name}.${ext}"
      break
    fi
  done

  if [ -z "$source_file" ]; then
    echo "Error: Source file for target '$exec_name' not found."
    return 1
  fi

  echo "Forcing rebuild for '$source_file' by updating its timestamp..."
  # 'touch' updates the file's modification time, making the build system
  # think it's new and needs to be recompiled.
  touch "$source_file"

  # Now, run the regular cppgo command.
  cppgo "$@"
}

# -----------------------------------------------------------------------------
# cppi
# -----------------------------------------------------------------------------
# Run a target in interactive mode (stdin from terminal).
#
# Usage:
#   cppi [target]
# -----------------------------------------------------------------------------
function cppi() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  local exec_path="./bin/$target_name"

  echo "${C_CYAN}Building target '${C_BOLD}$target_name${C_CYAN}'...${C_RESET}"
  if cppbuild "$target_name"; then
    echo ""
    echo "${C_BLUE}════-------------------------------------════${C_RESET}"
    echo "${C_BLUE}${C_BOLD}INTERACTIVE MODE: $target_name${C_RESET}"
    echo "${C_YELLOW}Enter input (Ctrl+D when done):${C_RESET}"
    "$exec_path"
    echo "${C_BLUE}════------------- FINISHED --------------════${C_RESET}"
  else
    echo "${C_RED}Build failed!${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# cppjudge
# -----------------------------------------------------------------------------
# Compare program output against sample input/output cases.
#
# Usage:
#   cppjudge [target]
# -----------------------------------------------------------------------------
function cppjudge() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  local exec_path="./bin/$target_name"
  local input_dir="input_cases"
  local output_dir="output_cases"

  if ! cppbuild "$target_name"; then
    echo "${C_RED}Build failed!${C_RESET}" >&2
    return 1
  fi

  # Check for test cases using Zsh globs.
  local test_files=()

  # Check for numbered test cases: target.1.in, target.2.in, etc.
  # (N): null glob (empty if no match)
  # n: numeric sort order
  test_files=( "$input_dir"/${target_name}.*.in(Nn) )

  # If no numbered test cases found, check for single test case.
  if (( ${#test_files} == 0 )) && [[ -f "$input_dir/${target_name}.in" ]]; then
    test_files+=("$input_dir/${target_name}.in")
  fi

  if (( ${#test_files} == 0 )); then
    echo "${C_YELLOW}No test cases found for '$target_name' (looked for '${target_name}.*.in' and '${target_name}.in')${C_RESET}"
    return 0
  fi

  local passed=0
  local failed=0
  local total=0

  for test_in in "${test_files[@]}"; do
    local test_case_base
    test_case_base=$(basename "$test_in" .in)
    local output_case="$output_dir/${test_case_base}.exp"
    local temp_out
    temp_out=$(mktemp)

    ((total++))
    echo -n "Testing $(basename "$test_in")... "
    echo ""

    # Measure execution time.
    local start_time=$EPOCHREALTIME
    "$exec_path" < "$test_in" > "$temp_out"
    local end_time=$EPOCHREALTIME
    local elapsed_ms
    printf -v elapsed_ms "%.0f" $(( (end_time - start_time) * 1000 ))

    # Check if expected output file exists.
    if [ ! -f "$output_case" ]; then
      echo "${C_BOLD}${C_YELLOW}WARNING: Expected output file '$(basename "$output_case")' not found.${C_RESET}"
      rm -f -- "$temp_out"
      continue
    fi

    # Use diff with -w (ignore all whitespace) and -B (ignore blank lines).
    if diff -wB "$temp_out" "$output_case" >/dev/null; then
      echo "${C_BOLD}${C_GREEN}PASSED${C_RESET} (${elapsed_ms}ms)"
      ((passed++))
    else
      echo "${C_BOLD}${C_RED}FAILED${C_RESET} (${elapsed_ms}ms)"
      ((failed++))
      echo "${C_BOLD}${C_YELLOW}════------------ YOUR OUTPUT ------------════${C_RESET}"
      cat "$temp_out"
      echo "${C_BOLD}${C_YELLOW}╠═══------------- EXPECTED --------------═══╣${C_RESET}"
      cat "$output_case"
      echo "${C_BOLD}${C_YELLOW}════-------------------------------------════${C_RESET}"
    fi
    rm -f -- "$temp_out"
  done

  # Summary.
  echo ""
  echo "${C_BOLD}${C_BLUE}════----------- TEST SUMMARY ------------════${C_RESET}"
  echo "${C_GREEN}Passed: $passed/$total${C_RESET}"
  if [ $failed -gt 0 ]; then
    echo "${C_RED}Failed: $failed/$total${C_RESET}"
  fi
  echo "${C_BOLD}${C_BLUE}════-------------------------------------════${C_RESET}"
}

# -----------------------------------------------------------------------------
# cppstress
# -----------------------------------------------------------------------------
# Run a target repeatedly with timeout to detect crashes.
#
# Usage:
#   cppstress [target] [iterations]
# -----------------------------------------------------------------------------
function cppstress() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  local iterations=${2:-100}
  local exec_path="./bin/$target_name"

  if ! cppbuild "$target_name"; then
    echo "${C_RED}Build failed!${C_RESET}" >&2
    return 1
  fi

  echo "${C_CYAN}Stress testing '$target_name' for $iterations iterations...${C_RESET}"

  local failed=0
  for i in $(seq 1 "$iterations"); do
    printf "\rIteration %d/%d... " "$i" "$iterations"

    # Run with empty input and check for crashes.
    if ! _run_with_timeout 2 "$exec_path" < /dev/null > /dev/null 2>&1; then
      ((failed++))
      echo "${C_RED}Failed at iteration $i${C_RESET}"
    fi
  done

  echo ""
  if [ $failed -eq 0 ]; then
    echo "${C_GREEN}All $iterations iterations completed successfully!${C_RESET}"
  else
    echo "${C_RED}$failed iterations failed out of $iterations${C_RESET}"
  fi
}

# ============================================================================ #
# End of 20-build-run.zsh
