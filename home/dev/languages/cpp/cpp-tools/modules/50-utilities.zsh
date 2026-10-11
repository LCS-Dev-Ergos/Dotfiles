# ============================================================================ #
# ++++++++++++++++++++++++++++++++ UTILITIES +++++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Maintenance utilities for cpp-tools projects.
# Includes cleaning, watching, statistics, archiving, and diagnostics.
#
# Functions:
#   - cppclean      Remove build artifacts safely.
#   - cppdeepclean  Remove all generated files.
#   - cppfocus      Pin the default target used by build/run commands.
#   - cppwatch      Auto-build on file changes.
#   - cppstats      Show problem timing statistics.
#   - cpparchive    Create a contest archive.
#   - cppdiag       Display environment diagnostics.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cppclean
# -----------------------------------------------------------------------------
# Remove build artifacts safely from the project.
#
# Usage:
#   cppclean [--yes|-y]
# -----------------------------------------------------------------------------
function cppclean() {
  local assume_yes=0
  case "$#:${1:-}" in
    0:) ;;
    1:-y|1:--yes) assume_yes=1 ;;
    *)
      _cp_error "Usage: cppclean [-y|--yes]"
      return 64
      ;;
  esac

  _check_workspace || return 1
  if [ ! -f "CMakeLists.txt" ]; then
    _cp_error "No CMakeLists.txt found in $(pwd). Aborting clean to avoid accidental deletion."
    return 1
  fi

  if [ "$assume_yes" -eq 0 ]; then
    if ! _cp_confirm \
      "Remove build artifacts in $(basename "$(pwd)")?" yes
    then
      echo "Clean cancelled."
      # Without a terminal nothing was asked; unattended runs pass --yes.
      [[ -t 0 ]] || return 1
      return 0
    fi
  fi

  _cp_info "Cleaning project..."
  if ! rm -rf -- build bin lib; then
    _cp_error "Unable to remove one or more build directories."
    return 1
  fi
  if ! rm -f -- .statistics/active_build_dir; then
    _cp_error "Unable to remove the active build metadata."
    return 1
  fi
  # Also remove the symlink if it exists in the root.
  if [ -L "compile_commands.json" ]; then
    rm -- "compile_commands.json" || return 1
  fi
  _cp_success "Project cleaned."
}

# -----------------------------------------------------------------------------
# cppdeepclean
# -----------------------------------------------------------------------------
# Remove all generated files while keeping source and test data.
# -----------------------------------------------------------------------------
function cppdeepclean() {
  _check_workspace || return 1
  if [ ! -f "CMakeLists.txt" ]; then
    _cp_error "No CMakeLists.txt found in $(pwd). Aborting deep clean to avoid accidental deletion."
    return 1
  fi
  _cp_warn "This will remove all generated files except source code and test cases."
  if _cp_confirm "Are you sure?" no; then
    cppclean --yes || return 1
    if ! rm -f -- \
        CMakeLists.txt gcc-toolchain.cmake clang-toolchain.cmake .clangd \
        .statistics/contest_metadata .statistics/problem_times \
        .statistics/last_config .statistics/active_build_dir \
        .contest_metadata .problem_times ||
      ! rm -rf -- .cache
    then
      _cp_error "Unable to remove one or more generated project files."
      return 1
    fi
    _cp_success "Deep clean complete."
  else
    echo "Deep clean cancelled."
    # Without a terminal nothing was asked.
    [[ -t 0 ]] || return 1
  fi
}

# -----------------------------------------------------------------------------
# cppfocus
# -----------------------------------------------------------------------------
# Set, clear, or inspect the focused target used by default commands.
#
# Usage:
#   cppfocus <target>
#   cppfocus --clear
#   cppfocus
# -----------------------------------------------------------------------------
function cppfocus() {
  _check_workspace || return 1

  if [ $# -eq 0 ]; then
    if [ -n "${CP_FOCUSED_TARGET:-}" ]; then
      echo "${C_GREEN}Focused target:${C_RESET} ${CP_FOCUSED_TARGET}"
    else
      echo "${C_YELLOW}No focused target is set.${C_RESET}"
    fi
    echo "${C_CYAN}Current default resolution:${C_RESET} $(_get_default_target)"
    return 0
  fi

  if [ "$1" = "--clear" ]; then
    unset CP_FOCUSED_TARGET
    echo "${C_GREEN}Focused target cleared.${C_RESET}"
    return 0
  fi

  local target_name source_file
  target_name=$(_normalize_target_name "$1")
  source_file=$(_resolve_target_source "$target_name")
  if [ -z "$source_file" ]; then
    _cp_error "Source file for target '$target_name' not found."
    return 1
  fi

  export CP_FOCUSED_TARGET="$target_name"
  echo "${C_GREEN}Focused target set to '${CP_FOCUSED_TARGET}'.${C_RESET}"
}

# -----------------------------------------------------------------------------
# cppwatch
# -----------------------------------------------------------------------------
# Watch a source file and rebuild automatically on changes.
#
# Usage:
#   cppwatch [target]
# -----------------------------------------------------------------------------
function cppwatch() {
  _check_initialized || return 1
  local target_name
  target_name=$(_normalize_target_name "${1:-$(_get_default_target)}")
  local source_file

  # Find the actual source file extension.
  source_file=$(_resolve_target_source "$target_name")
  if [ -z "$source_file" ]; then
    _cp_error "Source file for target '$target_name' not found."
    return 1
  fi

  if ! command -v fswatch &> /dev/null; then
    _cp_error "'fswatch' is not installed. Add it to the system package configuration."
    return 1
  fi

  _cp_info "Watching '$source_file' to rebuild target '$target_name'. Press Ctrl+C to stop."
  # Initial build (cppbuild shows a spinner per iteration when gum is active).
  cppbuild "$target_name"

  fswatch -o "$source_file" | while read -r; do
    _cp_info "Change detected in '$source_file'. Rebuilding..."
    cppbuild "$target_name"
  done
}

# -----------------------------------------------------------------------------
# cppstats
# -----------------------------------------------------------------------------
# Display elapsed time statistics for problems in the contest.
# -----------------------------------------------------------------------------
function cppstats() {
  if [ ! -f ".statistics/problem_times" ]; then
    echo "${C_YELLOW}No timing data available for this contest.${C_RESET}"
    return 0
  fi

  local current_time problem action timestamp elapsed
  local -a rows=()
  current_time=$(date +%s)

  while IFS=: read -r problem action timestamp _; do
    if [ "$action" = "START" ] && [[ "$timestamp" == <-> ]]; then
      elapsed=$((current_time - timestamp))
      rows+=("$problem"$'\t'"$(_format_duration $elapsed) ago")
    fi
  done < .statistics/problem_times

  if (( ${#rows[@]} == 0 )); then
    _cp_warn "No active problem timing entries were found."
    return 0
  fi

  _cp_heading "Problem statistics" "${#rows[@]} active problem(s)"
  _cp_ui_table $'Problem\tElapsed' "${rows[@]}"
}

# -----------------------------------------------------------------------------
# cpparchive
# -----------------------------------------------------------------------------
# Archive the current contest directory with exclusions.
#
# Usage:
#   cpparchive [--yes|-y]
# -----------------------------------------------------------------------------
function cpparchive() {
  local assume_yes=0
  case "$#:${1:-}" in
    0:) ;;
    1:-y|1:--yes) assume_yes=1 ;;
    *)
      _cp_error "Usage: cpparchive [-y|--yes]"
      return 64
      ;;
  esac
  _check_workspace || return 1
  if [[ ! -f CMakeLists.txt ]]; then
    _cp_error "CMakeLists.txt not found; refusing to archive this directory."
    return 1
  fi

  local contest_name
  contest_name=$(basename "$(pwd)")
  local archive_name
  archive_name="${contest_name}_$(date +%Y%m%d_%H%M%S).tar.gz"

  if (( ! assume_yes )) && ! _cp_confirm \
    "Archive contest '$contest_name' to '../$archive_name'?" yes
  then
    echo "Archive cancelled."
    # Without a terminal nothing was asked; unattended runs pass --yes.
    [[ -t 0 ]] || return 1
    return 0
  fi

  _cp_info "Archiving contest to '$archive_name'..."

  # Create archive excluding build artifacts.
  if ! tar -czf "../$archive_name" \
      --exclude="build" \
      --exclude="bin" \
      --exclude="lib" \
      --exclude="*.dSYM" \
      --exclude=".git" \
      .
  then
    _cp_error "Failed to create '../$archive_name'."
    return 1
  fi

  _cp_success "Contest archived to '../$archive_name'"
}

# -----------------------------------------------------------------------------
# cppdiag
# -----------------------------------------------------------------------------
# Display detailed diagnostics for tools, workspace, and compilers.
# -----------------------------------------------------------------------------
function cppdiag() {
  emulate -L zsh
  if (( $# )); then
    _cp_error "Usage: cppdiag"
    return 64
  fi

  # Rows: group, tone (ok, warn, error or muted), check, detail.
  local -a rows=()
  local group="System"
  _cp_report_row $group muted "Kernel" "$(uname -srm)"
  _cp_report_row $group muted "Shell" "$SHELL"
  [[ -z "${ZSH_VERSION-}" ]] || _cp_report_row $group muted "Zsh" "$ZSH_VERSION"
  [[ -z "${BASH_VERSION-}" ]] || _cp_report_row $group muted "Bash" "$BASH_VERSION"
  _cp_report_row $group muted "cpp-tools" "$SCRIPT_DIR"

  group="Workspace"
  _cp_report_row $group muted "Root" "$CP_WORKSPACE_ROOT"
  _cp_report_row $group muted "Algorithms" "$CP_ALGORITHMS_DIR"
  if _check_workspace >/dev/null 2>&1; then
    _cp_report_row $group ok "Location" "inside the workspace"
  else
    _cp_report_row $group warn "Location" "outside the workspace"
  fi

  # Each tool: its path and first version line, or why its absence matters.
  group="Tools"
  local GXX_PATH CLANGXX_PATH tool tool_path required why
  GXX_PATH=$(_cp_find_gxx)
  CLANGXX_PATH=$(command -v clang++)
  for tool required why in \
      g++ error "required" \
      clang++ warn "optional; sanitizers on macOS need it" \
      cmake error "required" \
      clangd warn "optional; editor support needs it" \
      fswatch warn "optional; cppwatch needs it" \
      timeout error "required; install coreutils"; do
    case "$tool" in
      g++) tool_path="$GXX_PATH" ;;
      clang++) tool_path="$CLANGXX_PATH" ;;
      timeout) tool_path=$(command -v timeout || command -v gtimeout) ;;
      *) tool_path=$(command -v "$tool") ;;
    esac
    if [[ -z "$tool_path" ]]; then
      _cp_report_row $group "$required" "$tool" "not found ($why)"
    elif [[ "$tool" == (fswatch|timeout) ]]; then
      _cp_report_row $group ok "$tool" "$tool_path"
    else
      _cp_report_row $group ok "$tool" \
        "$("$tool_path" --version 2>/dev/null | head -n 1) · $tool_path"
    fi
  done
  if [[ -n "$CLANGXX_PATH" ]]; then
    if "$CLANGXX_PATH" --version 2>/dev/null | grep -q "Apple"; then
      _cp_report_row $group muted "clang++ kind" "Apple Clang (Xcode)"
    else
      _cp_report_row $group muted "clang++ kind" "LLVM Clang"
    fi
  fi

  group="Project"
  if [[ -f CMakeLists.txt ]]; then
    _cp_report_row $group ok "CMakeLists.txt" "${PWD/#$HOME/~}"
    local active_build_dir cached_compiler
    active_build_dir=$(_cp_get_active_build_dir 2>/dev/null || true)
    if [[ -n "$active_build_dir" && -f "$active_build_dir/CMakeCache.txt" ]]; then
      cached_compiler=$(grep -E '^CMAKE_CXX_COMPILER:(FILEPATH|PATH|STRING)=' \
        "$active_build_dir/CMakeCache.txt" | head -n1 | cut -d'=' -f2-)
      _cp_report_row $group ok "Active build" "$active_build_dir"
      _cp_report_row $group muted "Cached compiler" "$cached_compiler"
    else
      _cp_report_row $group warn "Active build" "no CMake cache; cppconf creates it"
    fi
    if [[ -f .clangd ]]; then
      _cp_report_row $group ok ".clangd" "found"
    else
      _cp_report_row $group muted ".clangd" "none in this project"
    fi
    local metadata="" name created
    [[ -f .statistics/contest_metadata ]] && metadata=.statistics/contest_metadata
    [[ -z "$metadata" && -f .contest_metadata ]] && metadata=.contest_metadata
    if [[ -n "$metadata" ]]; then
      name=$(grep -m1 "CONTEST_NAME" "$metadata" | cut -d'=' -f2-)
      created=$(grep -m1 "CREATED" "$metadata" | cut -d'=' -f2-)
      _cp_report_row $group muted "Contest" "${name//\"/}${created:+ · created ${created//\"/}}"
    fi
    local -a cpp_files=(./*.cpp(N.))
    _cp_report_row $group muted "C++ files" "${#cpp_files}"
  else
    _cp_report_row $group muted "CMakeLists.txt" \
      "not inside a project directory"
  fi

  # Compile small probes with the toolchains found above.
  group="Compiler features"
  local probe_dir
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/cp_diag.XXXXXX") || {
    _cp_error "Unable to create the diagnostic probe directory."
    return 1
  }
  if [[ -n "$GXX_PATH" ]]; then
    print -rl -- '#include <bits/stdc++.h>' \
      '#include <ext/pb_ds/assoc_container.hpp>' \
      'using namespace std;' 'using namespace __gnu_pbds;' \
      'int main() { cout << "OK" << endl; return 0; }' >| "$probe_dir/gcc.cpp"
    if "$GXX_PATH" -std=c++23 "$probe_dir/gcc.cpp" -o "$probe_dir/gcc" \
        2>/dev/null; then
      _cp_report_row "$group" ok "GCC" "bits/stdc++.h, PBDS and C++23 compile"
    else
      _cp_report_row "$group" error "GCC" \
        "bits/stdc++.h, PBDS or C++23 failed to compile"
    fi
  fi
  if [[ -n "$CLANGXX_PATH" ]]; then
    # Prefer the project link, then the centralized header.
    local pch_include_dir=""
    if [[ -f algorithms/PCH.h ]]; then
      pch_include_dir="./algorithms"
    elif [[ -f "$CP_ALGORITHMS_DIR/libs/PCH.h" ]]; then
      pch_include_dir="$CP_ALGORITHMS_DIR/libs"
    fi
    if [[ -z "$pch_include_dir" ]]; then
      _cp_report_row "$group" warn "Clang PCH.h" \
        "not found in the project or the central libraries"
    else
      print -rl -- '#define USE_CLANG_SANITIZE' '#include "PCH.h"' \
        'using namespace std;' \
        'int main() { cout << "OK" << endl; return 0; }' >| "$probe_dir/pch.cpp"
      if "$CLANGXX_PATH" -std=c++23 -I"$pch_include_dir" -I"$CP_ALGORITHMS_DIR" \
          "$probe_dir/pch.cpp" -o "$probe_dir/pch" 2>/dev/null; then
        _cp_report_row "$group" ok "Clang PCH.h" "compiles with C++23"
      else
        _cp_report_row "$group" warn "Clang PCH.h" \
          "failed to compile: $pch_include_dir/PCH.h"
      fi
    fi
    printf '#include <iostream>\nint main(){return 0;}\n' >| "$probe_dir/san.cpp"
    local sanitizer label
    for sanitizer label in address AddressSanitizer undefined UBSanitizer; do
      if "$CLANGXX_PATH" -fsanitize="$sanitizer" "$probe_dir/san.cpp" \
          -o "$probe_dir/san" 2>/dev/null; then
        _cp_report_row "$group" ok "$label" "available"
      else
        _cp_report_row "$group" error "$label" "not available"
      fi
    done
  fi
  rm -rf -- "$probe_dir"

  # Diagnostics describe; cpphealth is the check that fails.
  _cp_report "Diagnostics" "cpphealth checks what is required" "${rows[@]}"
  return 0
}

# ============================================================================ #
# End of 50-utilities.zsh
