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
  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
  local build_dir
  build_dir=$(_cp_get_active_build_dir) || {
    _cp_error "No active build profile found. Run 'cppconf' first."
    return 1
  }

  echo "${C_CYAN}Building target: ${C_BOLD}$target_name${C_RESET} (${C_YELLOW}${build_dir}${C_RESET})..."

  # Record start time for total build duration.
  local start_time=$EPOCHREALTIME

  # Check if timing is enabled in CMake cache.
  local timing_enabled=false
  if [ -f "$build_dir/CMakeCache.txt" ]; then
    if grep -q "CP_ENABLE_TIMING:BOOL=ON" "$build_dir/CMakeCache.txt" 2>/dev/null; then
      timing_enabled=true
    fi
  fi

  # Capture both stdout and stderr to analyze build output. With gum, a
  # spinner is displayed while the output is piped through for capture.
  local build_output
  build_output=$(_cp_spin "Building ${target_name}..." cmake --build "$build_dir" --target "$target_name" -j)
  local build_status=$?

  # Calculate total build time.
  local end_time=$EPOCHREALTIME
  local elapsed_ms elapsed_str
  _cp_elapsed_ms "$start_time" "$end_time"; elapsed_ms=$REPLY
  _cp_format_ms "$elapsed_ms"; elapsed_str=$REPLY

  # Handle build failures with full error output.
  if [ $build_status -ne 0 ]; then
    echo ""
    _cp_rule "Build failed" red
    echo "$build_output"
    _cp_rule "" red
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
      _cp_box_top "Compilation time statistics" cyan
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
      if [ -f "$build_dir/CMakeCache.txt" ] && grep -q "clang" "$build_dir/CMakeCache.txt"; then
        echo ""
        echo -e " Clang compilation finished."
        echo -e " ${C_CYAN}Note: To analyze the detailed trace with Perfetto UI, run:${C_RESET}"
        echo -e "   ${C_BOLD}${C_GREEN}cpptrace $target_name${C_RESET}"
      fi

      echo ""
      _cp_box_bottom "Compilation finished; linking next." cyan
      echo ""
    fi

    # 4. Print the linking line and anything after it.
    echo "$build_output" | sed -n '/Linking CXX executable/,$p'
  else
    # Target up-to-date - show only the summary line.
    echo "$build_output" | tail -n 1
  fi

  # Display total build time.
  printf "${C_MUTED}Total build time: %s${C_RESET}\n" "$elapsed_str"

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
  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
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
#   cppgo [--force] [target] [input_file]
# -----------------------------------------------------------------------------
function cppgo() {
  _check_initialized || return 1
  local force_rebuild=0
  local input_override=""
  local -a positional=()
  local arg

  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --force)
        force_rebuild=1
        shift
        ;;
      --input)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          _cp_error "'--input' requires a filename argument."
          echo "Usage: cppgo [--force] [--input <file>] [target] [input_file]" >&2
          return 1
        fi
        input_override="$2"
        shift 2
        ;;
      --)
        shift
        while [ $# -gt 0 ]; do
          positional+=("$1")
          shift
        done
        ;;
      -*)
        _cp_error "Unknown option '$arg'."
        echo "Usage: cppgo [--force] [--input <file>] [target] [input_file]" >&2
        return 1
        ;;
      *)
        positional+=("$arg")
        shift
        ;;
    esac
  done

  if (( ${#positional[@]} > 2 )); then
    _cp_error "Too many arguments."
    echo "Usage: cppgo [--force] [--input <file>] [target] [input_file]" >&2
    return 1
  fi

  if [ -n "$input_override" ] && [ -n "${positional[2]:-}" ]; then
    _cp_error "Specify input either via '--input <file>' or positional arg, not both."
    return 1
  fi

  local target_name
  target_name=$(_normalize_target_name "${positional[1]:-$(_get_default_target)}")
  local exec_path="./bin/$target_name"

  # Default to the problem's own input file if a second argument isn't given.
  local input_file=${input_override:-${positional[2]:-"${target_name}.in"}}
  local input_path="input_cases/$input_file"

  if [ "$force_rebuild" -eq 1 ]; then
    local source_file
    source_file=$(_resolve_target_source "$target_name")
    if [ -z "$source_file" ]; then
      _cp_error "Source file for target '$target_name' not found."
      return 1
    fi
    echo "${C_YELLOW}Forcing rebuild for '$source_file' by updating its timestamp...${C_RESET}"
    touch "$source_file"
  fi

  echo "${C_CYAN}Building target '${C_BOLD}$target_name${C_CYAN}'...${C_RESET}"
  if cppbuild "$target_name"; then
    echo ""
    _cp_rule "Running ${target_name}"

    # Track execution time.
    local start_time=$EPOCHREALTIME

    local exit_code=0
    if [ -f "$input_path" ]; then
      echo "(input from ${C_YELLOW}$input_path${C_RESET})"
      _run_with_timeout 5s "$exec_path" < "$input_path"
      exit_code=$?
    else
      if [ -n "${positional[2]:-}" ]; then # Warn if a specific file was requested but not found.
        _cp_warn "Input file '$input_path' not found."
      fi
      _run_with_timeout 5s "$exec_path"
      exit_code=$?
    fi

    local end_time=$EPOCHREALTIME
    local elapsed_ms elapsed_str
    _cp_elapsed_ms "$start_time" "$end_time"; elapsed_ms=$REPLY
    _cp_format_ms "$elapsed_ms"; elapsed_str=$REPLY

    # Check if the program was terminated due to timeout.
    if [ $exit_code -eq 124 ]; then
      _cp_warn "Program terminated after 5-second timeout"
    elif [ $exit_code -ne 0 ] && [ $exit_code -ne 124 ]; then
      echo "${C_RED}Program exited with code $exit_code${C_RESET}"
    fi

    _cp_rule "Finished"
    printf "${C_MUTED}Execution time: %s${C_RESET}\n" "$elapsed_str"
    return "$exit_code"
  else
    echo "${C_RED}Build failed!${C_RESET}" >&2
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
  cppgo --force "$@"
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
  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
  local exec_path="./bin/$target_name"

  echo "${C_CYAN}Building target '${C_BOLD}$target_name${C_CYAN}'...${C_RESET}"
  if cppbuild "$target_name"; then
    echo ""
    _cp_rule "Interactive: ${target_name}"
    echo "${C_YELLOW}Enter input (Ctrl+D when done):${C_RESET}"
    "$exec_path"
    local run_status=$?
    _cp_rule "Finished"
    return "$run_status"
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
  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
  local exec_path="./bin/$target_name"
  local input_dir="input_cases"
  local output_dir="output_cases"

  if ! cppbuild "$target_name"; then
    echo "${C_RED}Build failed!${C_RESET}" >&2
    return 1
  fi

  # Collect test cases using common naming conventions:
  #   target.in
  #   target.1.in / target.01.in
  #   target_01.in
  #   target-01.in
  local -a test_files=(
    "$input_dir"/${target_name}.in(N)
    "$input_dir"/${target_name}.*.in(Nn)
    "$input_dir"/${target_name}_*.in(Nn)
    "$input_dir"/${target_name}-*.in(Nn)
  )
  # Remove duplicates while preserving first-seen order.
  typeset -U test_files

  if (( ${#test_files} == 0 )); then
    echo "${C_YELLOW}No test cases found for '$target_name'.${C_RESET}"
    echo "${C_YELLOW}Checked: ${target_name}.in, ${target_name}.*.in, ${target_name}_*.in, ${target_name}-*.in${C_RESET}"
    return 0
  fi

  local passed=0
  local failed=0
  local total=0
  local missing_expected=0
  local judge_timeout="${CP_JUDGE_TIMEOUT:-5s}"
  # Per-test tab-separated rows for the final summary table, and the tone
  # each verdict reads in.
  local -a result_rows=() result_tones=()

  if ! _get_timeout_cmd >/dev/null 2>&1; then
    _cp_error "No timeout command found ('timeout' or 'gtimeout')."
    echo "${C_YELLOW}Install coreutils (macOS): brew install coreutils${C_RESET}" >&2
    return 1
  fi

  local test_in
  for test_in in "${test_files[@]}"; do
    local test_case_base
    test_case_base=$(basename "$test_in" .in)
    local output_case="$output_dir/${test_case_base}.exp"
    local temp_out
    temp_out=$(mktemp "${TMPDIR:-/tmp}/cppjudge.XXXXXX") || {
      _cp_error "Unable to create a temporary judge output file."
      return 1
    }

    ((total++))
    echo -n "Testing $(basename "$test_in")... "

    # Measure execution time and enforce a timeout for sample judging.
    local start_time=$EPOCHREALTIME
    _run_with_timeout "$judge_timeout" "$exec_path" < "$test_in" > "$temp_out"
    local run_status=$?
    local end_time=$EPOCHREALTIME
    local elapsed_ms
    _cp_elapsed_ms "$start_time" "$end_time"
    printf -v elapsed_ms '%.0f' "$REPLY"

    if [ $run_status -eq 124 ] || [ $run_status -eq 137 ]; then
      echo "${C_BOLD}${C_RED}TIMEOUT${C_RESET} (${elapsed_ms}ms, limit ${judge_timeout})"
      ((failed++))
      result_rows+=(
        "$(basename "$test_in")"$'\t'"TIMEOUT"$'\t'"${elapsed_ms}ms"
      )
      result_tones+=(error)
      rm -f -- "$temp_out"
      continue
    elif [ $run_status -ne 0 ]; then
      echo "${C_BOLD}${C_RED}RUNTIME ERROR${C_RESET} (exit ${run_status}, ${elapsed_ms}ms)"
      ((failed++))
      result_rows+=(
        "$(basename "$test_in")"$'\t'\
"RUNTIME ERROR (exit ${run_status})"$'\t'"${elapsed_ms}ms"
      )
      result_tones+=(error)
      if [ -s "$temp_out" ]; then
        _cp_rule "Partial output" yellow
        cat "$temp_out"
        _cp_rule "" yellow
      fi
      rm -f -- "$temp_out"
      continue
    fi

    # Check if expected output file exists.
    if [ ! -f "$output_case" ]; then
      echo "${C_BOLD}${C_YELLOW}WARNING: Expected output file '$(basename "$output_case")' not found.${C_RESET}"
      ((missing_expected++))
      result_rows+=(
        "$(basename "$test_in")"$'\t'\
"NO EXPECTED OUTPUT"$'\t'"${elapsed_ms}ms"
      )
      result_tones+=(warn)
      rm -f -- "$temp_out"
      continue
    fi

    # Use diff with -w (ignore all whitespace) and -B (ignore blank lines).
    if diff -wB "$temp_out" "$output_case" >/dev/null; then
      echo "${C_BOLD}${C_GREEN}PASSED${C_RESET} (${elapsed_ms}ms)"
      ((passed++))
      result_rows+=("$(basename "$test_in")"$'\t'"PASSED"$'\t'"${elapsed_ms}ms")
      result_tones+=(ok)
    else
      echo "${C_BOLD}${C_RED}FAILED${C_RESET} (${elapsed_ms}ms)"
      ((failed++))
      result_rows+=("$(basename "$test_in")"$'\t'"FAILED"$'\t'"${elapsed_ms}ms")
      result_tones+=(error)
      _cp_rule "Your output" yellow
      cat "$temp_out"
      _cp_rule "Expected" yellow
      cat "$output_case"
      _cp_rule "" yellow
    fi
    rm -f -- "$temp_out"
  done

  # Summary: one marked row per case, then the counts.
  echo ""
  _cp_section "Test summary" "$target_name"
  _cp_ui_table --tones "${(j:,:)result_tones}" --status 2 --align llr \
    $'Case\tVerdict\tTime' "${result_rows[@]}"
  echo ""
  local hint=""
  (( failed )) && hint="Each failing case printed its output above"
  _cp_ui_width
  _cp_ui_call _zsh_ui_summary --width "$REPLY" --hint "$hint" \
    "ok"$'\t'"$passed"$'\t'"passed" \
    "error"$'\t'"$failed"$'\t'"failed" \
    "warn"$'\t'"$missing_expected"$'\t'"without expected output"

  if [ $failed -gt 0 ] || [ $missing_expected -gt 0 ]; then
    return 1
  fi
  return 0
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
  if (( $# > 2 )); then
    _cp_error "Usage: cppstress [target] [iterations]"
    return 64
  fi
  _check_initialized || return 1
  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
  local iterations=${2:-100}
  local exec_path="./bin/$target_name"

  if [[ ! "$iterations" == <-> ]] || [ "$iterations" -le 0 ]; then
    _cp_error "The iteration count must be a positive integer (got '$iterations')."
    return 1
  fi

  if ! cppbuild "$target_name"; then
    echo "${C_RED}Build failed!${C_RESET}" >&2
    return 1
  fi

  echo "${C_CYAN}Stress testing '$target_name' for $iterations iterations...${C_RESET}"

  local failed=0
  local i
  for (( i = 1; i <= iterations; i++ )); do
    printf "\rIteration %d/%d... " "$i" "$iterations"

    # Run with empty input and check for crashes.
    if ! _run_with_timeout 2s "$exec_path" < /dev/null > /dev/null 2>&1; then
      ((failed++))
      echo "${C_RED}Failed at iteration $i${C_RESET}"
    fi
  done

  echo ""
  if [ $failed -eq 0 ]; then
    echo "${C_GREEN}All $iterations iterations completed successfully!${C_RESET}"
    return 0
  else
    echo "${C_RED}$failed iterations failed out of $iterations${C_RESET}"
    return 1
  fi
}

# ============================================================================ #
# End of 20-build-run.zsh
