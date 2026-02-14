# ============================================================================ #
# ++++++++++++++++++++++++++++ SUBMISSION HELPERS ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Submission generation and validation for cpp-tools workflows.
# Includes flattener integration, compilation verification, and health checks.
#
# Functions:
#   - cppsubmit                     Generate a submission file.
#   - _verify_submission_compilation Validate submission compiles.
#   - _offer_clipboard_copy          Offer clipboard copy prompt.
#   - cpptestsubmit                  Compile and test submission file.
#   - cppfull                        Run full workflow (dev/test/submission).
#   - cppcheck                       Validate environment and templates.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cppsubmit
# -----------------------------------------------------------------------------
# Generate a single-file submission using the flattener system.
#
# Usage:
#   cppsubmit [target]
# -----------------------------------------------------------------------------
function cppsubmit() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  local problem_brief
  local solution_file="${target_name}.cpp"
  local submission_dir="$SUBMISSIONS_DIR"
  local submission_file="$submission_dir/${target_name}_sub.cpp"
  local flattener_script="$SCRIPTS_DIR/flattener.py"

  # Validate that we are in a valid workspace.
  if [[ ! "$PWD" == "$CP_WORKSPACE_ROOT"* ]]; then
    echo -e "${C_RED}Error: Not in a valid CP workspace directory${C_RESET}" >&2
    echo -e "${C_YELLOW}Current directory: $PWD${C_RESET}" >&2
    echo -e "${C_YELLOW}Expected workspace: $CP_WORKSPACE_ROOT${C_RESET}" >&2
    return 1
  fi

  # Check that the solution file exists.
  if [ ! -f "$solution_file" ]; then
    echo -e "${C_RED}Error: Solution file '$solution_file' not found${C_RESET}" >&2
    return 1
  fi

  # Check if the new flattener system is available.
  if [ ! -f "$flattener_script" ]; then
    echo -e "${C_YELLOW}Warning: New flattener not found at '$flattener_script'${C_RESET}"
    return 1
  fi

  problem_brief=$(_problem_brief "$target_name")

  # Create submissions directory if needed.
  mkdir -p "$submission_dir"

  echo -e "${C_CYAN}Generating submission for '${C_BOLD}$target_name${C_RESET}${C_CYAN}' using modular template system...${C_RESET}"

  # Generate submission header with metadata.
  local header_file
  header_file=$(mktemp "/tmp/${target_name}_header.XXXXXX") || {
    echo -e "${C_RED}Error: Unable to create temporary header file${C_RESET}" >&2
    return 1
  }
  cat > "$header_file" << EOF
//===----------------------------------------------------------------------===//
/**
 * @file: ${target_name}_sub.cpp
 * @generated: $(date '+%Y-%m-%d %H:%M:%S')
 * @source: $solution_file
 * @author: Costantino Lombardi
 *
 * @brief: ${problem_brief}
 */
//===----------------------------------------------------------------------===//
/* Included library and Compiler Optimizations */
EOF

  # Run the Python flattener with proper path context.
  echo -e "${C_BLUE}Running template flattener...${C_RESET}"

  # Set PYTHONPATH to include the scripts directory for module imports.
  export PYTHONPATH="$SCRIPTS_DIR:$PYTHONPATH"

  local flattened_tmp
  flattened_tmp=$(mktemp "/tmp/${target_name}_flattened.XXXXXX") || {
    echo -e "${C_RED}Error: Unable to create temporary flattened file${C_RESET}" >&2
    rm -f -- "$header_file"
    return 1
  }

  local flattener_err
  flattener_err=$(mktemp "/tmp/flattener_error.XXXXXX") || {
    echo -e "${C_RED}Error: Unable to create temporary error log${C_RESET}" >&2
    rm -f -- "$header_file" "$flattened_tmp"
    return 1
  }

  if python3 "$flattener_script" "$solution_file" > "$flattened_tmp" 2>"$flattener_err"; then
    # Combine header with flattened content.
    cat "$header_file" "$flattened_tmp" > "$submission_file"
    rm -f -- "$flattened_tmp" "$header_file" "$flattener_err"

    # Calculate and display statistics.
    local file_size
    file_size=$(wc -c < "$submission_file")
    local line_count
    line_count=$(wc -l < "$submission_file")
    local template_lines
    template_lines=$(grep -c "^//" "$submission_file" 2>/dev/null || echo 0)
    local code_lines=$((line_count - template_lines))

    echo -e "${C_GREEN}✓ Submission generated successfully${C_RESET}"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "File:" "${C_BOLD}$submission_file${C_RESET}"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Size:" "$(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "$file_size bytes")"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Lines:" "$line_count total ($code_lines code, $template_lines comments)"

    # Verify compilation with the generated file.
    if _verify_submission_compilation "$submission_file"; then
      echo -e "${C_GREEN}✓ Compilation verification passed${C_RESET}"
    else
      echo -e "${C_RED}⚠ Warning: Compilation verification failed${C_RESET}"
      echo -e "${C_YELLOW}  Review the generated file for potential issues${C_RESET}"
    fi

    # Offer clipboard integration.
    _offer_clipboard_copy "$submission_file"

    return 0
  else
    echo -e "${C_RED}Error: Flattener failed to process the file${C_RESET}" >&2
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
#   _verify_submission_compilation <submission_file>
# -----------------------------------------------------------------------------
function _verify_submission_compilation() {
  local submission_file="$1"

  # Find available g++ compiler.
  local gxx_compiler
  gxx_compiler=$(command -v g++-15 || command -v g++-14 || command -v g++-13 || command -v g++)

  if [ -z "$gxx_compiler" ]; then
    echo "${C_YELLOW}Warning: No g++ compiler found for verification${C_RESET}" >&2
    return 1
  fi

  # Attempt syntax-only compilation with competition flags.
  if "$gxx_compiler" -std=c++23 -O2 -DNDEBUG -fsyntax-only "$submission_file" 2>/dev/null; then
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
  echo
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
#   cpptestsubmit [target] [input]
# -----------------------------------------------------------------------------
function cpptestsubmit() {
  _check_initialized || return 1
  local generate_submission=1

  if [ "${1:-}" = "--no-generate" ]; then
    generate_submission=0
    shift
  fi

  local target_name=${1:-$(_get_default_target)}

  # Generate submission first unless already generated by caller.
  if [ "$generate_submission" -eq 1 ]; then
    if ! cppsubmit "$target_name"; then
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
  mkdir -p "$(dirname "$test_binary")"

  # Find available g++ compiler.
  local gxx_compiler
  gxx_compiler=$(command -v g++-15 || command -v g++-14 || command -v g++-13 || command -v g++)

  if [ -z "$gxx_compiler" ]; then
    echo "${C_RED}Error: No g++ compiler found${C_RESET}" >&2
    return 1
  fi

  # Compile with timing information.
  echo -e "${C_BLUE}Compiling submission...${C_RESET}"
  local start_time=$EPOCHREALTIME

  local compile_err_log
  compile_err_log=$(mktemp "/tmp/cp_compile_error.XXXXXX") || {
    echo "${C_RED}Error: Unable to create temporary log file${C_RESET}" >&2
    return 1
  }

  if "$gxx_compiler" -std=c++23 -O2 -DNDEBUG -march=native \
    -I"$CP_ALGORITHMS_DIR" \
    "$submission_file" -o "$test_binary" 2>"$compile_err_log"; then

    local end_time=$EPOCHREALTIME
    local elapsed_sec=$(( end_time - start_time ))

    if (( elapsed_sec < 1 )); then
      printf "${C_GREEN}✓ Submission compiled successfully in %.2fms${C_RESET}\n" $(( elapsed_sec * 1000 ))
    else
      printf "${C_GREEN}✓ Submission compiled successfully in %.2fs${C_RESET}\n" $elapsed_sec
    fi

    # Test execution with input.
    if [ -f "$input_path" ]; then
      echo -e "${C_BLUE}Testing with input from $input_path:${C_RESET}"
      echo -e "${C_CYAN}╔═══──────────────────────────────────────────═══╗${C_RESET}"

      # Run with timeout and capture output.
      local run_output
      run_output=$(_run_with_timeout 2s "$test_binary" < "$input_path" 2>&1)
      local exit_code=$?
      echo "$run_output" | head -n 50

      echo -e "${C_CYAN}╚═══──────────────────────────────────────────═══╝${C_RESET}"

      if [ "$exit_code" -eq 124 ]; then
        echo -e "${C_YELLOW}⚠ Execution timeout (2s limit exceeded)${C_RESET}"
      elif [ "$exit_code" -ne 0 ]; then
        echo -e "${C_RED}⚠ Program exited with code $exit_code${C_RESET}"
      else
        echo -e "${C_GREEN}✓ Execution completed successfully${C_RESET}"
      fi
    else
      echo -e "${C_YELLOW}No input file found at '$input_path'${C_RESET}"
      echo -e "${C_YELLOW}Running without input (5s timeout)...${C_RESET}"
      _run_with_timeout 5s "$test_binary"
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
}

# -----------------------------------------------------------------------------
# cppfull
# -----------------------------------------------------------------------------
# Run development test, generate submission, and test submission.
#
# Usage:
#   cppfull [target] [input]
# -----------------------------------------------------------------------------
function cppfull() {
  _check_initialized || return 1
  local target_name=${1:-$(_get_default_target)}
  local input_name=${2:-"${target_name}.in"}

  echo -e "${C_BLUE}╔═══──────────────────────────────────────────═══╗${C_RESET}"
  echo -e "${C_BLUE}${C_BOLD} FULL WORKFLOW: $(printf "%-20s" "$target_name")${C_RESET}"
  echo -e "${C_BLUE}╚═══──────────────────────────────────────────═══╝${C_RESET}"

  # Step 1: Development version test.
  echo ""
  echo -e "${C_CYAN}[1/3] Testing development version...${C_RESET}"
  if ! cppgo "$target_name" "$input_name"; then
    echo -e "${C_RED}✗ Development version failed${C_RESET}" >&2
    return 1
  fi
  echo -e "${C_GREEN}✓ Development test passed${C_RESET}"

  # Step 2: Generate submission.
  echo ""
  echo -e "${C_CYAN}[2/3] Generating submission...${C_RESET}"
  if ! cppsubmit "$target_name"; then
    echo -e "${C_RED}✗ Submission generation failed${C_RESET}" >&2
    return 1
  fi

  # Step 3: Test submission.
  echo ""
  echo -e "${C_CYAN}[3/3] Testing submission...${C_RESET}"
  if ! cpptestsubmit --no-generate "$target_name" "$input_name"; then
    echo -e "${C_RED}✗ Submission test failed${C_RESET}" >&2
    return 1
  fi

  # Summary with file information.
  local submission_file="$SUBMISSIONS_DIR/${target_name}_sub.cpp"
  local file_size
  file_size=$(wc -c < "$submission_file" 2>/dev/null || echo "0")

  echo ""
  echo -e "${C_GREEN}${C_BOLD}╔═══──────────────────────────────────────────═══╗${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}  ✓ Full workflow completed successfully${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}╚═══──────────────────────────────────────────═══╝${C_RESET}"
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
  echo -e "${C_CYAN}${C_BOLD}Checking template system health...${C_RESET}"
  echo -e "${C_CYAN}╔═══──────────────────────────────────────────═══╗${C_RESET}"

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

  # Check for new modular system.
  if [ -f "$SCRIPTS_DIR/flattener.py" ]; then
    echo -e "${C_GREEN}  ✓ Flattener script found${C_RESET}"
    if python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
      echo -e "${C_GREEN}  ✓ Python 3 available${C_RESET}"
    else
      echo -e "${C_RED}  ✗ Python 3 not available${C_RESET}"
      all_good=false
    fi
  else
    echo -e "${C_YELLOW}  ⚠ Flattener script not found (using legacy system)${C_RESET}"
    warnings=$((warnings + 1))
  fi

  # Check templates directory.
  if [ -d "$TEMPLATES_DIR" ]; then
    local template_count
    template_count=$(find "$TEMPLATES_DIR" -maxdepth 1 -name "*.hpp" 2>/dev/null | wc -l)
    echo -e "${C_GREEN}  ✓ Templates directory: $template_count files${C_RESET}"
  else
    echo -e "${C_YELLOW}  ⚠ Templates directory not found (optional)${C_RESET}"
    warnings=$((warnings + 1))
  fi

  # Check modules directory.
  if [ -d "$MODULES_DIR" ]; then
    local module_count
    module_count=$(find "$MODULES_DIR" -maxdepth 1 -name "*.hpp" 2>/dev/null | wc -l)
    echo -e "${C_GREEN}  ✓ Modules directory: $module_count files${C_RESET}"
  else
    echo -e "${C_YELLOW}  ⚠ Modules directory not found (optional)${C_RESET}"
    warnings=$((warnings + 1))
  fi

  # Check legacy system fallback.
  local legacy_build="$SCRIPTS_DIR/build_template.sh"
  if [ -f "$legacy_build" ]; then
    echo -e "${C_GREEN}  ✓ Legacy build script available (fallback)${C_RESET}"
  else
    echo -e "${C_YELLOW}  ⚠ Legacy build script not found${C_RESET}"
    warnings=$((warnings + 1))
  fi

  # Check compiler and tools.
  echo -e "\n${C_BLUE}Development Tools:${C_RESET}"

  if command -v g++ &> /dev/null; then
    local gcc_version
    gcc_version=$(g++ --version | head -n1)
    echo -e "${C_GREEN}  ✓ Compiler: $gcc_version${C_RESET}"

    # Check C++ standard support.
    if echo | g++ -std=c++23 -x c++ - -fsyntax-only &>/dev/null; then
      echo -e "${C_GREEN}  ✓ C++23 support available${C_RESET}"
    elif echo | g++ -std=c++20 -x c++ - -fsyntax-only &>/dev/null; then
      echo -e "${C_YELLOW}  ⚠ C++20 available (C++23 not supported)${C_RESET}"
      warnings=$((warnings + 1))
    else
      echo -e "${C_RED}  ✗ Modern C++ standards not supported${C_RESET}"
      all_good=false
    fi
  else
    echo -e "${C_RED}  ✗ g++ compiler not found${C_RESET}"
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
  echo -e "\n${C_CYAN}╚═══──────────────────────────────────────────═══╝${C_RESET}"
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
