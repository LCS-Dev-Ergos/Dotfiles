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
#   - cpphealth                       Validate environment and templates.
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
    _cp_error "No source file found for target '$target_name' (.cpp/.cc/.cxx)"
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
    _cp_error "Unable to create temporary header file"
    return 1
  }
  if ! cat > "$header_file" << EOF
//===----------------------------------------------------------------------===//
/**
 * @file: ${target_name}_sub.cpp
 * @generated: $(date '+%Y-%m-%d %H:%M:%S') by CPP-Tools Submission Generator
 * @source: $solution_file
 *
 * @brief: ${problem_brief}
 */
//===----------------------------------------------------------------------===//

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
    _cp_error "Unable to create temporary flattened file"
    rm -f -- "$header_file"
    return 1
  }

  local flattener_err
  flattener_err=$(mktemp "${TMPDIR:-/tmp}/cp_sub_flattener_error.XXXXXX") || {
    _cp_error "Unable to create temporary error log"
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

    _cp_success "Submission generated successfully."
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "File:" "${C_BOLD}$submission_file${C_RESET}"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Size:" "$(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "$file_size bytes")"
    printf "${C_YELLOW}  %-6s %s${C_RESET}\n" "Lines:" "$line_count total ($code_lines code, $template_lines comments)"

    # Verify compilation with the generated file.
    if _verify_submission_compilation "$submission_file" "$strict_mode"; then
      _cp_success "Compilation verification passed"
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
    _cp_warn "No g++ compiler found for verification"
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
      _cp_success "Copied to $clipboard_name"
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
    _cp_error "Submission file '$submission_file' not found"
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
    _cp_error "No g++ compiler found"
    return 1
  fi

  # Compile with timing information.
  echo -e "${C_BLUE}Compiling submission...${C_RESET}"
  local start_time=$EPOCHREALTIME

  local compile_err_log
  compile_err_log=$(mktemp "${TMPDIR:-/tmp}/cp_compile_error.XXXXXX") || {
    _cp_error "Unable to create temporary log file"
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
        _cp_warn "Execution timeout (2s limit exceeded)"
        execution_status=1
      elif [ "$exit_code" -ne 0 ]; then
        echo -e "${C_RED}⚠ Program exited with code $exit_code${C_RESET}"
        execution_status=1
      else
        _cp_success "Execution completed successfully"
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
    _cp_error "Submission compilation failed"
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
        _cp_error "Unknown option '$1'."
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

  _cp_rule "Full workflow: ${target_name}"

  # Step 1: Development version test.
  echo -e "\n${C_CYAN}[1/3] Testing development version...${C_RESET}"
  if ! cppgo "$target_name" "$input_name"; then
    _cp_error "Development version failed"
    return 1
  fi
  _cp_success "Development test passed"

  # Step 2: Generate submission.
  echo -e "\n${C_CYAN}[2/3] Generating submission...${C_RESET}"
  if [ "$strict_mode" -eq 1 ]; then
    if ! cppsubmit --strict "$target_name"; then
      _cp_error "Submission generation failed"
      return 1
    fi
  else
    if ! cppsubmit "$target_name"; then
      _cp_error "Submission generation failed"
      return 1
    fi
  fi

  # Step 3: Test submission.
  echo -e "\n${C_CYAN}[3/3] Testing submission...${C_RESET}"
  if [ "$strict_mode" -eq 1 ]; then
    if ! cpptestsubmit --no-generate --strict "$target_name" "$input_name"; then
      _cp_error "Submission test failed"
      return 1
    fi
  else
    if ! cpptestsubmit --no-generate "$target_name" "$input_name"; then
      _cp_error "Submission test failed"
      return 1
    fi
  fi

  # Summary with file information.
  local submission_file="$SUBMISSIONS_DIR/${target_name}_sub.cpp"
  local file_size
  file_size=$(wc -c < "$submission_file" 2>/dev/null || echo "0")

  echo ""
  _cp_rule "Workflow complete" green
  echo -e "${C_YELLOW}📁 Submission: $submission_file${C_RESET}"
  echo -e "${C_YELLOW}📊 Size: $(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "$file_size bytes")${C_RESET}"
  echo -e "${C_YELLOW}📋 Ready for contest submission${C_RESET}"

  # Final clipboard offer.
  _offer_clipboard_copy "$submission_file"
}

# -----------------------------------------------------------------------------
# cpphealth
# -----------------------------------------------------------------------------
# Check the workspace, the template system and the tools, then report them
# like devdoctor: a framed header, one counted section per group, a marker per
# check and a summary. Fails when a required check fails; optional features
# only warn.
# -----------------------------------------------------------------------------
function cpphealth() {
  emulate -L zsh
  if (( $# )); then
    _cp_error "Usage: cpphealth"
    return 64
  fi

  # Rows: group, tone (ok, warn, error or muted), check, detail.
  local -a rows=()
  local tab=$'\t'
  if [[ -n "$CP_WORKSPACE_ROOT" && -d "$CP_WORKSPACE_ROOT" ]]; then
    _cp_report_row Workspace ok "Workspace root" "$CP_WORKSPACE_ROOT"
  else
    _cp_report_row Workspace error "Workspace root" "not configured or missing"
  fi
  if [[ -n "$CP_ALGORITHMS_DIR" && -d "$CP_ALGORITHMS_DIR" ]]; then
    _cp_report_row Workspace ok "Algorithms directory" "$CP_ALGORITHMS_DIR"
  else
    _cp_report_row Workspace error "Algorithms directory" \
      "not configured or missing"
  fi

  if [[ -f "$SCRIPTS_DIR/flattener.py" ]]; then
    _cp_report_row Templates ok "Flattener script" "$SCRIPTS_DIR/flattener.py"
    if python3 -c "import sys; sys.exit(0)" 2>/dev/null; then
      _cp_report_row Templates ok "Python 3" "runs the flattener"
    else
      _cp_report_row Templates error "Python 3" "not available"
    fi
  else
    _cp_report_row Templates error "Flattener script" "not found"
  fi
  local directory label
  for label directory in \
      "Templates directory" "$TEMPLATES_DIR" \
      "Modules directory" "$MODULES_DIR"; do
    if [[ -d "$directory" ]]; then
      local -a headers=("$directory"/*.hpp(N))
      _cp_report_row Templates ok "$label" "${#headers} files"
    else
      _cp_report_row Templates warn "$label" "not found (optional)"
    fi
  done

  local active_build_dir cached_compiler compiler_path compiler_version
  active_build_dir=$(_cp_get_active_build_dir 2>/dev/null || true)
  if [[ -n "$active_build_dir" && -f "$active_build_dir/CMakeCache.txt" ]]; then
    cached_compiler=$(grep -E '^CMAKE_CXX_COMPILER:(FILEPATH|PATH|STRING)=' \
      "$active_build_dir/CMakeCache.txt" | head -n1 | cut -d'=' -f2-)
    _cp_report_row Tools muted "Cached build compiler (not executed)" \
      "$cached_compiler"
  fi
  # Diagnostics may inspect an unbuilt project. Only the user's selected
  # PATH toolchain is executable here; project metadata is display data.
  compiler_path=$(_cp_find_gxx 2>/dev/null || true)
  if [[ -n "$compiler_path" && -x "$compiler_path" ]]; then
    compiler_version=$("$compiler_path" --version 2>/dev/null | head -n1)
    _cp_report_row Tools ok "PATH compiler" "$compiler_version"
    if [[ -n "$active_build_dir" ]]; then
      _cp_report_row Tools ok "Active build cache" \
        "$active_build_dir/CMakeCache.txt"
    else
      _cp_report_row Tools warn "Active build cache" \
        "none found; the PATH compiler is used"
    fi
    # Probe standard support with the PATH toolchain, never the cached path.
    if print | "$compiler_path" -std=c++23 -x c++ - -fsyntax-only &>/dev/null
    then
      _cp_report_row Tools ok "C++ standard" "C++23 support available"
    elif print | "$compiler_path" -std=c++20 -x c++ - -fsyntax-only &>/dev/null
    then
      _cp_report_row Tools warn "C++ standard" "C++20 only; C++23 is not supported"
    else
      _cp_report_row Tools error "C++ standard" "no modern standard is supported"
    fi
  else
    _cp_report_row Tools error "PATH compiler" "no usable C++ compiler found"
  fi
  if (( $+commands[python3] )); then
    _cp_report_row Tools ok "Python" "$(python3 --version 2>&1)"
  else
    _cp_report_row Tools warn "Python" "not found (required for new features)"
  fi
  local -a tones=("${(@)${(@)rows#*$tab}%%$tab*}")
  local hint="all systems operational"
  (( ${tones[(I)warn]} )) && hint="warnings never fail cpphealth"
  (( ${tones[(I)error]} )) && hint="resolve the failing checks first"
  _cp_report "Health check" "$hint" "${rows[@]}"
}

# ============================================================================ #
# End of 30-submission.zsh
