# ============================================================================ #
# ++++++++++++++++++++++++++++ SUBMISSION HELPERS ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Submission generation and validation for cpp-tools workflows.
# Includes flattener integration, compilation verification, and health checks.
#
# Functions:
#   - cppsubmit                       Generate a submission file.
#   - _verify_submission_compilation  Validate submission compiles.
#   - _offer_clipboard_copy           Offer clipboard copy prompt.
#   - cpptestsubmit                   Compile and test submission file.
#   - cppfull                         Run full workflow (dev/test/submission).
#   - cppcheck                        Validate environment and templates.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cppsubmit
# -----------------------------------------------------------------------------
# Generate a single-file submission using the flattener system.
#
# Usage:
#   cppsubmit [--strict] [target]
# -----------------------------------------------------------------------------
function cppsubmit() {
  _check_initialized || return 1
  local strict_mode=0
  while (( $# )); do
    case "$1" in
      --strict)
        strict_mode=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        _cp_error "Unknown option: $1"
        return 64
        ;;
      *) break ;;
    esac
  done
  if (( $# > 1 )); then
    _cp_error "Usage: cppsubmit [--strict] [target]"
    return 64
  fi
  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
  local problem_brief
  local solution_file
  local submission_dir="$SUBMISSIONS_DIR"
  local submission_file="$submission_dir/${target_name}_sub.cpp"
  local flattener_script="$SCRIPTS_DIR/flattener.py"

  # Check that the solution file exists.
  solution_file=$(_resolve_target_source "$target_name")
  if [ -z "$solution_file" ]; then
    echo -e "${C_RED}Error: No source file found for target '$target_name' (.cpp/.cc/.cxx)${C_RESET}" >&2
    return 1
  fi

  # Submission generation requires the configured flattener.
  if [ ! -f "$flattener_script" ]; then
    _cp_error "Flattener not found at '$flattener_script'."
    return 1
  fi

  problem_brief=$(_problem_brief "$target_name")

  # Create submissions directory if needed.
  mkdir -p "$submission_dir" || {
    _cp_error "Unable to create the submissions directory."
    return 1
  }

  echo -e "${C_CYAN}Generating submission for '${C_BOLD}$target_name${C_RESET}${C_CYAN}' using modular template system...${C_RESET}"

  # Generate submission header with metadata.
  local header_file
  header_file=$(mktemp "${TMPDIR:-/tmp}/cp_sub_header.XXXXXX") || {
    echo -e "${C_RED}Error: Unable to create temporary header file${C_RESET}" >&2
    return 1
  }
  if ! cat > "$header_file" << EOF
//===----------------------------------------------------------------------===//
/**
 * @file: ${target_name}_sub.cpp
 * @generated: $(date '+%Y-%m-%d %H:%M:%S')
 * @source: $solution_file
 * @author: C.L.
 *
 * @brief: ${problem_brief}
 */
//===----------------------------------------------------------------------===//
/* Included library and Compiler Optimizations */

EOF
  then
    rm -f -- "$header_file"
    _cp_error "Unable to render the submission header."
    return 1
  fi

  # Run the Python flattener with proper path context.
  echo -e "${C_BLUE}Running template flattener...${C_RESET}"

  local flattened_tmp
  flattened_tmp=$(mktemp "${TMPDIR:-/tmp}/cp_sub_flattened.XXXXXX") || {
    echo -e "${C_RED}Error: Unable to create temporary flattened file${C_RESET}" >&2
    rm -f -- "$header_file"
    return 1
  }

  local flattener_err
  flattener_err=$(mktemp "${TMPDIR:-/tmp}/cp_sub_flattener_error.XXXXXX") || {
    echo -e "${C_RED}Error: Unable to create temporary error log${C_RESET}" >&2
    rm -f -- "$header_file" "$flattened_tmp"
    return 1
  }

  # Scope PYTHONPATH to this invocation only; exporting it would permanently
  # mutate the interactive shell and grow on every cppsubmit call.
  if PYTHONPATH="$SCRIPTS_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$flattener_script" "$solution_file" > "$flattened_tmp" 2>"$flattener_err"; then
    # Assemble beside the destination and replace it atomically. A failed
    # render must never truncate a previously verified submission.
    local submission_tmp
    submission_tmp=$(mktemp \
      "$submission_dir/.${target_name}_sub.cpp.XXXXXX") || {
      rm -f -- "$flattened_tmp" "$header_file" "$flattener_err"
      _cp_error "Unable to create the temporary submission file."
      return 1
    }
    if ! cat "$header_file" "$flattened_tmp" > "$submission_tmp" ||
      ! mv -- "$submission_tmp" "$submission_file"
    then
      rm -f -- "$submission_tmp" "$flattened_tmp" \
        "$header_file" "$flattener_err"
      _cp_error "Unable to assemble the generated submission."
      return 1
    fi
    rm -f -- "$flattened_tmp" "$header_file" "$flattener_err"

    # Calculate and display statistics.
    local file_size
    file_size=$(wc -c < "$submission_file")
    local line_count
    line_count=$(wc -l < "$submission_file")
    # Note: grep -c prints the count even when it is 0 (exiting 1), so a
    # '|| echo 0' fallback would produce "0\n0". Default only when empty.
    local template_lines
    template_lines=$(grep -c "^//" "$submission_file" 2>/dev/null)
    template_lines=${template_lines:-0}
    local code_lines=$((line_count - template_lines))

    _cp_success "✓ Submission generated successfully"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "File:" "${C_BOLD}$submission_file${C_RESET}"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Size:" "$(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "$file_size bytes")"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Lines:" "$line_count total ($code_lines code, $template_lines comments)"

    # Verify compilation with the generated file.
    if _verify_submission_compilation "$submission_file" "$strict_mode"; then
      echo -e "${C_GREEN}✓ Compilation verification passed${C_RESET}"
    else
      echo -e "${C_RED}⚠ Warning: Compilation verification failed${C_RESET}"
      echo -e "${C_YELLOW}  Review the generated file for potential issues${C_RESET}"
    fi

    # Offer clipboard integration.
    _offer_clipboard_copy "$submission_file"

    return 0
  else
    _cp_error "Error: Flattener failed to process the file"
    if [ -f "$flattener_err" ]; then
      echo -e "${C_RED}Error details:${C_RESET}"
      cat "$flattener_err" >&2
    fi
    rm -f -- "$header_file" "$flattened_tmp" "$flattener_err"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# _verify_submission_compilation
# -----------------------------------------------------------------------------
# Run a syntax-only compilation check for a generated submission file.
#
# Usage:
#   _verify_submission_compilation <submission_file> [strict_mode]
# -----------------------------------------------------------------------------
function _verify_submission_compilation() {
  local submission_file="$1"
  local strict_mode="${2:-0}"

  # Find available g++ compiler (validated, newest first).
  local gxx_compiler
  gxx_compiler=$(_cp_find_gxx)

  if [ -z "$gxx_compiler" ]; then
    echo "${C_YELLOW}Warning: No g++ compiler found for verification${C_RESET}" >&2
    return 1
  fi

  local -a verify_flags=()
  if [ "$strict_mode" -eq 1 ]; then
    # Judge-like verification (closer to Codeforces defaults).
    verify_flags=(-std=gnu++20 -O2 -DNDEBUG -Wall -Wextra -Wshadow -Wconversion)
  else
    verify_flags=(-std=c++23 -O2 -DNDEBUG)
  fi

  # Attempt syntax-only compilation with selected flags.
  if "$gxx_compiler" "${verify_flags[@]}" -fsyntax-only "$submission_file" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# _offer_clipboard_copy
# -----------------------------------------------------------------------------
# Offer to copy a file to the system clipboard if available.
#
# Usage:
#   _offer_clipboard_copy <file>
# -----------------------------------------------------------------------------
function _offer_clipboard_copy() {
  local file="$1"

  # Detect available clipboard command.
  local clipboard_cmd=()
  local clipboard_name=""

  if command -v pbcopy &> /dev/null; then
    clipboard_cmd=(pbcopy)
    clipboard_name="macOS clipboard"
  elif command -v xclip &> /dev/null; then
    clipboard_cmd=(xclip -selection clipboard)
    clipboard_name="X11 clipboard"
  elif command -v wl-copy &> /dev/null; then
    clipboard_cmd=(wl-copy)
    clipboard_name="Wayland clipboard"
  else
    return 0
  fi

  # Skip prompt in non-interactive environments.
  if [ ! -t 0 ]; then
    return 0
  fi

  echo ""
  printf "Copy to %s? [y/N]: " "$clipboard_name"
  read -r REPLY || return 0
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if "${clipboard_cmd[@]}" < "$file"; then
      echo -e "${C_GREEN}✓ Copied to $clipboard_name${C_RESET}"
    else
      echo -e "${C_RED}Failed to copy to clipboard${C_RESET}"
    fi
  fi
}

# -----------------------------------------------------------------------------
# cpptestsubmit
# -----------------------------------------------------------------------------
# Compile and test the generated submission against inputs.
#
# Usage:
#   cpptestsubmit [--no-generate] [--strict] [target] [input]
# -----------------------------------------------------------------------------
function cpptestsubmit() {
  _check_initialized || return 1
  local generate_submission=1
  local strict_mode=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --no-generate)
        generate_submission=0
        shift
        ;;
      --strict)
        strict_mode=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        _cp_error "Unknown option: $1"
        return 64
        ;;
      *)
        break
        ;;
    esac
  done

  if (( $# > 2 )); then
    _cp_error \
      "Usage: cpptestsubmit [--no-generate] [--strict] [target] [input]"
    return 64
  fi

  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")

  # Generate submission first unless already generated by caller.
  if [ "$generate_submission" -eq 1 ]; then
    if [ "$strict_mode" -eq 1 ]; then
      if ! cppsubmit --strict "$target_name"; then
        return 1
      fi
    elif ! cppsubmit "$target_name"; then
      return 1
    fi
  fi

  local submission_file="$SUBMISSIONS_DIR/${target_name}_sub.cpp"
  local test_binary="./bin/${target_name}_submission"
  local input_file=${2:-"${target_name}.in"}
  local input_path="input_cases/$input_file"

  if [ ! -f "$submission_file" ]; then
    echo -e "${C_RED}Error: Submission file '$submission_file' not found${C_RESET}" >&2
    return 1
  fi

  echo ""
  echo -e "${C_CYAN}Testing submission file...${C_RESET}"

  # Ensure bin directory exists.
  mkdir -p "$(dirname "$test_binary")" || {
    _cp_error "Unable to create the submission test directory."
    return 1
  }

  # Find available g++ compiler (validated, newest first).
  local gxx_compiler
  gxx_compiler=$(_cp_find_gxx)

  if [ -z "$gxx_compiler" ]; then
    echo "${C_RED}Error: No g++ compiler found${C_RESET}" >&2
    return 1
  fi

  # Compile with timing information.
  echo -e "${C_BLUE}Compiling submission...${C_RESET}"
  local start_time=$EPOCHREALTIME

  local compile_err_log
  compile_err_log=$(mktemp "${TMPDIR:-/tmp}/cp_compile_error.XXXXXX") || {
    echo "${C_RED}Error: Unable to create temporary log file${C_RESET}" >&2
    return 1
  }

  local -a compile_flags=()
  if [ "$strict_mode" -eq 1 ]; then
    compile_flags=(-std=gnu++20 -O2 -DNDEBUG -Wall -Wextra -Wshadow -Wconversion)
  else
    compile_flags=(-std=c++23 -O2 -DNDEBUG -march=native)
  fi

  if "$gxx_compiler" "${compile_flags[@]}" -I"$CP_ALGORITHMS_DIR" \
    "$submission_file" -o "$test_binary" 2>"$compile_err_log"; then

    local end_time=$EPOCHREALTIME
    local elapsed_str
    _cp_elapsed_ms "$start_time" "$end_time"
    _cp_format_ms "$REPLY"; elapsed_str=$REPLY

    printf "${C_GREEN}✓ Submission compiled successfully in %s${C_RESET}\n" "$elapsed_str"

    # Test execution with input and propagate runtime failures to callers.
    local execution_status=0
    if [ -f "$input_path" ]; then
      echo -e "${C_BLUE}Testing with input from $input_path:${C_RESET}"
      _cp_rule "" cyan

      # Run with timeout and capture output.
      local run_output
      run_output=$(_run_with_timeout 2s "$test_binary" < "$input_path" 2>&1)
      local exit_code=$?
      echo "$run_output" | head -n 50

      _cp_rule "" cyan

      if [ "$exit_code" -eq 124 ]; then
        echo -e "${C_YELLOW}⚠ Execution timeout (2s limit exceeded)${C_RESET}"
        execution_status=1
      elif [ "$exit_code" -ne 0 ]; then
        echo -e "${C_RED}⚠ Program exited with code $exit_code${C_RESET}"
        execution_status=1
      else
        echo -e "${C_GREEN}✓ Execution completed successfully${C_RESET}"
      fi
    else
      echo -e "${C_YELLOW}No input file found at '$input_path'${C_RESET}"
      echo -e "${C_YELLOW}Running without input (5s timeout)...${C_RESET}"
      _run_with_timeout 5s "$test_binary"
      local exit_code=$?
      if [ "$exit_code" -ne 0 ]; then
        _cp_error "Submission execution failed with status $exit_code."
        execution_status=1
      fi
    fi

    # Cleanup binary.
    rm -f -- "$test_binary"
  else
    echo -e "${C_RED}✗ Submission compilation failed${C_RESET}" >&2
    echo -e "${C_RED}Compilation errors:${C_RESET}"
    cat "$compile_err_log" >&2
    rm -f -- "$compile_err_log"
    return 1
  fi
  rm -f -- "$compile_err_log"
  return "$execution_status"
}

# -----------------------------------------------------------------------------
# cppfull
# -----------------------------------------------------------------------------
# Run development test, generate submission, and test submission.
#
# Usage:
#   cppfull [--strict] [target] [input]
# -----------------------------------------------------------------------------
function cppfull() {
  _check_initialized || return 1
  local strict_mode=0
  local target_name input_name

  # Parse optional --strict flag.
  while [ $# -gt 0 ]; do
    case "$1" in
      --strict)
        strict_mode=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo -e "${C_RED}Error: Unknown option '$1'.${C_RESET}" >&2
        return 64
        ;;
      *)
        break
        ;;
    esac
  done

  if (( $# > 2 )); then
    _cp_error "Usage: cppfull [--strict] [target] [input]"
    return 64
  fi

  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
  input_name=${2:-"${target_name}.in"}

  _cp_rule "FULL WORKFLOW: ${target_name}"

  # Step 1: Development version test.
  echo -e "\n${C_CYAN}[1/3] Testing development version...${C_RESET}"
  if ! cppgo "$target_name" "$input_name"; then
    echo -e "${C_RED}✗ Development version failed${C_RESET}" >&2
    return 1
  fi
  echo -e "${C_GREEN}✓ Development test passed${C_RESET}"

  # Step 2: Generate submission.
  echo -e "\n${C_CYAN}[2/3] Generating submission...${C_RESET}"
  if [ "$strict_mode" -eq 1 ]; then
    if ! cppsubmit --strict "$target_name"; then
      echo -e "${C_RED}✗ Submission generation failed${C_RESET}" >&2
      return 1
    fi
  else
    if ! cppsubmit "$target_name"; then
      echo -e "${C_RED}✗ Submission generation failed${C_RESET}" >&2
      return 1
    fi
  fi

  # Step 3: Test submission.
  echo -e "\n${C_CYAN}[3/3] Testing submission...${C_RESET}"
  if [ "$strict_mode" -eq 1 ]; then
    if ! cpptestsubmit --no-generate --strict "$target_name" "$input_name"; then
      echo -e "${C_RED}✗ Submission test failed${C_RESET}" >&2
      return 1
    fi
  else
    if ! cpptestsubmit --no-generate "$target_name" "$input_name"; then
      echo -e "${C_RED}✗ Submission test failed${C_RESET}" >&2
      return 1
    fi
  fi

  # Summary with file information.
  local submission_file="$SUBMISSIONS_DIR/${target_name}_sub.cpp"
  local file_size
  file_size=$(wc -c < "$submission_file" 2>/dev/null || echo "0")

  echo ""
  _cp_rule "✓ WORKFLOW COMPLETE" green
  echo -e "${C_YELLOW}📁 Submission: $submission_file${C_RESET}"
  echo -e "${C_YELLOW}📊 Size: $(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "$file_size bytes")${C_RESET}"
  echo -e "${C_YELLOW}📋 Ready for contest submission${C_RESET}"

  # Final clipboard offer.
  _offer_clipboard_copy "$submission_file"
}

# -----------------------------------------------------------------------------
# cppcheck
# -----------------------------------------------------------------------------
# Check template system, compilers, and workspace configuration health.
# -----------------------------------------------------------------------------
function cppcheck() {
  if (( $# )); then
    _cp_error "Usage: cppcheck"
    return 64
  fi
  _cp_rule "TEMPLATE SYSTEM HEALTH" cyan

  local all_good=true
  local warnings=0

  # Check workspace configuration.
  echo -e "${C_BLUE}Workspace Configuration:${C_RESET}"
  if [ -n "$CP_WORKSPACE_ROOT" ] && [ -d "$CP_WORKSPACE_ROOT" ]; then
    echo -e "${C_GREEN}  ✓ Workspace root: $CP_WORKSPACE_ROOT${C_RESET}"
  else
    echo -e "${C_RED}  ✗ Workspace root not configured or missing${C_RESET}"
    all_good=false
  fi

  if [ -n "$CP_ALGORITHMS_DIR" ] && [ -d "$CP_ALGORITHMS_DIR" ]; then
    echo -e "${C_GREEN}  ✓ Algorithms directory: $CP_ALGORITHMS_DIR${C_RESET}"
  else
    echo -e "${C_RED}  ✗ Algorithms directory not configured or missing${C_RESET}"
    all_good=false
  fi

  # Check template system components.
  echo -e "\n${C_BLUE}Template System Components:${C_RESET}"

  # Check the required flattener pipeline.
  if [ -f "$SCRIPTS_DIR/flattener.py" ]; then
    echo -e "${C_GREEN}  ✓ Flattener script found${C_RESET}"
    if python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
      echo -e "${C_GREEN}  ✓ Python 3 available${C_RESET}"
    else
      echo -e "${C_RED}  ✗ Python 3 not available${C_RESET}"
      all_good=false
    fi
  else
    echo -e "${C_RED}  ✗ Flattener script not found${C_RESET}"
    all_good=false
  fi

  # Check templates directory.
  if [ -d "$TEMPLATES_DIR" ]; then
    local -a template_files=("$TEMPLATES_DIR"/*.hpp(N))
    local template_count=${#template_files[@]}
    echo -e "${C_GREEN}  ✓ Templates directory: $template_count files${C_RESET}"
  else
    echo -e "${C_YELLOW}  ⚠ Templates directory not found (optional)${C_RESET}"
    warnings=$((warnings + 1))
  fi

  # Check modules directory.
  if [ -d "$MODULES_DIR" ]; then
    local -a module_files=("$MODULES_DIR"/*.hpp(N))
    local module_count=${#module_files[@]}
    echo -e "${C_GREEN}  ✓ Modules directory: $module_count files${C_RESET}"
  else
    echo -e "${C_YELLOW}  ⚠ Modules directory not found (optional)${C_RESET}"
    warnings=$((warnings + 1))
  fi

  # Check compiler and tools.
  echo -e "\n${C_BLUE}Development Tools:${C_RESET}"

  local active_build_dir compiler_path compiler_version
  active_build_dir=$(_cp_get_active_build_dir 2>/dev/null || true)
  compiler_path=""
  if [ -n "$active_build_dir" ] && [ -f "$active_build_dir/CMakeCache.txt" ]; then
    compiler_path=$(grep -E '^CMAKE_CXX_COMPILER:(FILEPATH|PATH|STRING)=' "$active_build_dir/CMakeCache.txt" | head -n1 | cut -d'=' -f2-)
  fi
  if [ -z "$compiler_path" ]; then
    compiler_path=$(command -v g++ 2>/dev/null || true)
  fi

  if [ -n "$compiler_path" ] && [ -x "$compiler_path" ]; then
    compiler_version=$("$compiler_path" --version 2>/dev/null | head -n1)
    echo -e "${C_GREEN}  ✓ Compiler: $compiler_version${C_RESET}"
    if [ -n "$active_build_dir" ]; then
      echo -e "${C_GREEN}  ✓ Active build compiler source: $active_build_dir/CMakeCache.txt${C_RESET}"
    else
      echo -e "${C_YELLOW}  ⚠ No active build cache found; using compiler from PATH${C_RESET}"
      warnings=$((warnings + 1))
    fi

    # Check C++ standard support with the same compiler configured for the active build.
    if echo | "$compiler_path" -std=c++23 -x c++ - -fsyntax-only &>/dev/null; then
      echo -e "${C_GREEN}  ✓ C++23 support available${C_RESET}"
    elif echo | "$compiler_path" -std=c++20 -x c++ - -fsyntax-only &>/dev/null; then
      echo -e "${C_YELLOW}  ⚠ C++20 available (C++23 not supported)${C_RESET}"
      warnings=$((warnings + 1))
    else
      echo -e "${C_RED}  ✗ Modern C++ standards not supported${C_RESET}"
      all_good=false
    fi
  else
    echo -e "${C_RED}  ✗ Unable to resolve a usable C++ compiler${C_RESET}"
    all_good=false
  fi

  if command -v python3 &> /dev/null; then
    local python_version
    python_version=$(python3 --version 2>&1)
    echo -e "${C_GREEN}  ✓ Python: $python_version${C_RESET}"
  else
    echo -e "${C_YELLOW}  ⚠ Python 3 not found (required for new features)${C_RESET}"
    warnings=$((warnings + 1))
  fi

  # Summary.
  echo ""
  _cp_rule "" cyan
  if $all_good; then
    if [ $warnings -eq 0 ]; then
      echo -e "${C_GREEN}${C_BOLD}✓ All systems fully operational${C_RESET}"
    else
      echo -e "${C_GREEN}${C_BOLD}✓ Core systems operational${C_RESET}"
      echo -e "${C_YELLOW}  $warnings warning(s) for optional features${C_RESET}"
    fi
    return 0
  else
    echo -e "${C_RED}${C_BOLD}✗ Critical issues detected${C_RESET}"
    echo -e "${C_YELLOW}  Please resolve the issues marked with ✗${C_RESET}"
    return 1
  fi
}

# ============================================================================ #
# End of 30-submission.zsh
