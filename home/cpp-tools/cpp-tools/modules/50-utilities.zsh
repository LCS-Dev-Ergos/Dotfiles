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
    echo "${C_RED}Error: No CMakeLists.txt found in $(pwd). Aborting clean to avoid accidental deletion.${C_RESET}" >&2
    return 1
  fi

  if [ "$assume_yes" -eq 0 ]; then
    if ! _cp_confirm \
      "Remove build artifacts in $(basename "$(pwd)")?" yes
    then
      echo "Clean cancelled."
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
    echo "${C_RED}Error: No CMakeLists.txt found in $(pwd). Aborting deep clean to avoid accidental deletion.${C_RESET}" >&2
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
    echo "${C_RED}Error: Source file for target '$target_name' not found.${C_RESET}" >&2
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
    echo "${C_RED}Error: Source file for target '$target_name' not found.${C_RESET}" >&2
    return 1
  fi

  if ! command -v fswatch &> /dev/null; then
    echo "${C_RED}Error: 'fswatch' is not installed. Please run 'brew install fswatch'.${C_RESET}" >&2
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
# -----------------------------------------------------------------------------
function cpparchive() {
  if (( $# )); then
    _cp_error "Usage: cpparchive"
    return 64
  fi
  _check_workspace || return 1
  if [[ ! -f CMakeLists.txt ]]; then
    _cp_error "CMakeLists.txt not found; refusing to archive this directory."
    return 1
  fi

  local contest_name
  contest_name=$(basename "$(pwd)")
  local archive_name
  archive_name="${contest_name}_$(date +%Y%m%d_%H%M%S).tar.gz"

  if ! _cp_confirm \
    "Archive contest '$contest_name' to '../$archive_name'?" yes
  then
    echo "Archive cancelled."
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
  if (( $# )); then
    _cp_error "Usage: cppdiag"
    return 64
  fi
  echo "${C_BOLD}Running Competitive Programming Environment Diagnostics...${C_RESET}"

  echo ""
  _cp_header "SYSTEM & SHELL"
  # Display OS and shell information.
  uname -a
  echo "Shell: $SHELL"
  [ -n "$BASH_VERSION" ] && echo "Bash Version: $BASH_VERSION"
  [ -n "$ZSH_VERSION" ] && echo "Zsh Version: $ZSH_VERSION"
  echo "Script Directory: $SCRIPT_DIR"

  echo ""
  _cp_header "WORKSPACE CONFIGURATION"
  echo "CP Workspace Root: ${C_CYAN}$CP_WORKSPACE_ROOT${C_RESET}"
  echo "Algorithms Directory: ${C_CYAN}$CP_ALGORITHMS_DIR${C_RESET}"

  # Check if we're in the workspace.
  if _check_workspace >/dev/null 2>&1; then
    echo "Current Location: ${C_GREEN}Inside workspace${C_RESET}"
  else
    echo "Current Location: ${C_YELLOW}Outside workspace${C_RESET}"
  fi

  echo ""
  _cp_header "CORE TOOLS"

  # Check for g++ (validated, newest first).
  local GXX_PATH
  GXX_PATH=$(_cp_find_gxx)
  if [ -n "$GXX_PATH" ]; then
    local gxx_version
    gxx_version=$("$GXX_PATH" --version 2>/dev/null | head -n 1)
    echo "${C_GREEN}g++:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $GXX_PATH"
    echo "   ${C_CYAN}Version:${C_RESET} $gxx_version"
  else
    echo "${C_RED}g++: Not found!${C_RESET}"
  fi

  # Check for clang++
  local CLANGXX_PATH
  CLANGXX_PATH=$(command -v clang++)
  if [ -n "$CLANGXX_PATH" ]; then
    local clangxx_version
    clangxx_version=$("$CLANGXX_PATH" --version 2>/dev/null | head -n 1)
    echo "${C_GREEN}clang++:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $CLANGXX_PATH"
    echo "   ${C_CYAN}Version:${C_RESET} $clangxx_version"

    # Check if it's Apple Clang or LLVM Clang.
    if "$CLANGXX_PATH" --version | grep -q "Apple"; then
      echo "   ${C_CYAN}Type:${C_RESET} Apple Clang (Xcode)"
    else
      echo "   ${C_CYAN}Type:${C_RESET} LLVM Clang"
    fi
  else
    echo "${C_YELLOW}clang++: Not found (optional, needed for sanitizers on macOS)${C_RESET}"
  fi

  # Check for cmake.
  local CMAKE_PATH
  CMAKE_PATH=$(command -v cmake)
  if [ -n "$CMAKE_PATH" ]; then
    echo "${C_GREEN}cmake:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $CMAKE_PATH"
    echo "   ${C_CYAN}Version:${C_RESET} $("$CMAKE_PATH" --version | head -n 1)"
  else
    echo "${C_RED}cmake: Not found!${C_RESET}"
  fi

  # Check for clangd.
  local CLANGD_PATH
  CLANGD_PATH=$(command -v clangd)
  if [ -n "$CLANGD_PATH" ]; then
    echo "${C_GREEN}clangd:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $CLANGD_PATH"
    echo "   ${C_CYAN}Version:${C_RESET} $("$CLANGD_PATH" --version | head -n 1)"
  else
    echo "${C_RED}clangd: Not found!${C_RESET}"
  fi

  # Check for fswatch (optional).
  local FSWATCH_PATH
  FSWATCH_PATH=$(command -v fswatch)
  if [ -n "$FSWATCH_PATH" ]; then
    echo "${C_GREEN}fswatch:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $FSWATCH_PATH"
  else
    echo "${C_YELLOW}fswatch: Not found (optional, needed for cppwatch)${C_RESET}"
  fi

  # Check timeout command (required by cppgo/cppstress/cppjudge workflows).
  local TIMEOUT_PATH
  TIMEOUT_PATH=$(command -v timeout || command -v gtimeout)
  if [ -n "$TIMEOUT_PATH" ]; then
    echo "${C_GREEN}timeout:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $TIMEOUT_PATH"
  else
    echo "${C_RED}timeout/gtimeout: Not found (required). Install coreutils.${C_RESET}"
  fi

  echo ""
  _cp_header "PROJECT CONFIGURATION (in $(pwd))"
  if [ -f "CMakeLists.txt" ]; then
    echo "${C_GREEN}Found CMakeLists.txt${C_RESET}"

    # Check CMake Cache for the configured compiler.
    local active_build_dir
    active_build_dir=$(_cp_get_active_build_dir 2>/dev/null || true)
    if [ -n "$active_build_dir" ] && [ -f "$active_build_dir/CMakeCache.txt" ]; then
      local cached_compiler
      cached_compiler=$(grep -E '^CMAKE_CXX_COMPILER:(FILEPATH|PATH|STRING)=' "$active_build_dir/CMakeCache.txt" | head -n1 | cut -d'=' -f2-)
      echo "   ${C_CYAN}CMake Cached CXX Compiler:${C_RESET} $cached_compiler"
      echo "   ${C_CYAN}Active Build Dir:${C_RESET} $active_build_dir"
    else
      echo "   ${C_YELLOW}Info: No CMake cache found. Run 'cppconf' to generate it.${C_RESET}"
    fi

    # Display .clangd configuration if it exists.
    if [ -f ".clangd" ]; then
      echo "${C_GREEN}Found .clangd config${C_RESET}"
    else
      echo "   ${C_YELLOW}Info: No .clangd config file found in this project.${C_RESET}"
    fi

    # Check for metadata files.
    if [ -f ".statistics/contest_metadata" ]; then
      echo "${C_GREEN}Found contest metadata${C_RESET}"
      grep "CONTEST_NAME" .statistics/contest_metadata | sed 's/^/   /'
      grep "CREATED" .statistics/contest_metadata | sed 's/^/   /'
    elif [ -f ".contest_metadata" ]; then
      # Legacy compatibility path.
      echo "${C_GREEN}Found legacy contest metadata${C_RESET}"
      grep "CONTEST_NAME" .contest_metadata | sed 's/^/   /'
      grep "CREATED" .contest_metadata | sed 's/^/   /'
    fi

    # Count problems.
    local cpp_count
    local -a cpp_files=(./*.cpp(N.))
    cpp_count=${#cpp_files[@]}
    echo "   ${C_CYAN}C++ files:${C_RESET} $cpp_count"

  else
    echo "${C_RED}Not inside a project directory (CMakeLists.txt not found).${C_RESET}"
  fi

  echo ""
  _cp_header "COMPILER FEATURES CHECK"

  # Test with GCC if available.
  if [ -n "$GXX_PATH" ]; then
    echo "${C_CYAN}Testing GCC features:${C_RESET}"
    local test_file test_bin
    test_file=$(mktemp "${TMPDIR:-/tmp}/cp_gcc_test_XXXXXX.cpp") || {
      _cp_error "Unable to create the GCC diagnostic source file."
      return 1
    }
    test_bin=$(mktemp "${TMPDIR:-/tmp}/cp_gcc_test_XXXXXX") || {
      rm -f -- "$test_file"
      _cp_error "Unable to create the GCC diagnostic binary."
      return 1
    }
    cat > "$test_file" << 'EOF'
#include <bits/stdc++.h>
#include <ext/pb_ds/assoc_container.hpp>
using namespace std;
using namespace __gnu_pbds;
int main() { cout << "OK" << endl; return 0; }
EOF

    if "$GXX_PATH" -std=c++23 "$test_file" -o "$test_bin" 2>/dev/null; then
      echo "  ${C_GREEN}bits/stdc++.h: Available${C_RESET}"
      echo "  ${C_GREEN}PBDS: Available${C_RESET}"
      echo "  ${C_GREEN}C++23: Supported${C_RESET}"
    else
      echo "  ${C_RED}Some GCC features may not be available. Check your installation.${C_RESET}"
    fi
    rm -f -- "$test_file" "$test_bin"
  fi

  # Test with Clang if available.
  if [ -n "$CLANGXX_PATH" ]; then
    echo ""
    echo "${C_CYAN}Testing Clang features:${C_RESET}"

    # Test PCH.h compatibility.
    local test_pch test_pch_bin
    test_pch=$(mktemp "${TMPDIR:-/tmp}/cp_clang_test_XXXXXX.cpp") || {
      _cp_error "Unable to create the Clang diagnostic source file."
      return 1
    }
    test_pch_bin=$(mktemp "${TMPDIR:-/tmp}/cp_clang_test_XXXXXX") || {
      rm -f -- "$test_pch"
      _cp_error "Unable to create the Clang diagnostic binary."
      return 1
    }
    cat > "$test_pch" << 'EOF'
#define USE_CLANG_SANITIZE
#include "PCH.h"
using namespace std;
int main() { cout << "OK" << endl; return 0; }
EOF

    # Prefer the project link, then test the centralized header directly.
    local pch_header="" pch_include_dir=""
    if [ -f "algorithms/PCH.h" ]; then
      pch_header="algorithms/PCH.h"
      pch_include_dir="./algorithms"
    elif [ -f "$CP_ALGORITHMS_DIR/libs/PCH.h" ]; then
      pch_header="$CP_ALGORITHMS_DIR/libs/PCH.h"
      pch_include_dir="$CP_ALGORITHMS_DIR/libs"
    fi
    if [ -n "$pch_header" ]; then
      if "$CLANGXX_PATH" -std=c++23 -I"$pch_include_dir" \
        -I"$CP_ALGORITHMS_DIR" \
        "$test_pch" -o "$test_pch_bin" 2>/dev/null
      then
        echo "  ${C_GREEN}PCH.h: Compatible${C_RESET}"
        echo "  ${C_GREEN}C++23: Supported${C_RESET}"
      else
        echo "  ${C_YELLOW}PCH.h compilation failed.${C_RESET}"
        echo "    Header: $pch_header"
      fi
    else
      echo "  ${C_YELLOW}PCH.h: Not found.${C_RESET}"
      echo "    Checked project and central libraries."
    fi

    # Test sanitizer support.
    local test_san san_bin
    test_san=$(mktemp "${TMPDIR:-/tmp}/cp_clang_san_XXXXXX.cpp") || {
      rm -f -- "$test_pch" "$test_pch_bin"
      _cp_error "Unable to create the sanitizer diagnostic source file."
      return 1
    }
    san_bin=$(mktemp "${TMPDIR:-/tmp}/cp_clang_san_XXXXXX") || {
      rm -f -- "$test_pch" "$test_pch_bin" "$test_san"
      _cp_error "Unable to create the sanitizer diagnostic binary."
      return 1
    }
    printf "#include <iostream>\nint main(){return 0;}" > "$test_san"
    if "$CLANGXX_PATH" -fsanitize=address "$test_san" -o "$san_bin" 2>/dev/null; then
      echo "  ${C_GREEN}AddressSanitizer: Available${C_RESET}"
    else
      echo "  ${C_RED}AddressSanitizer: Not available${C_RESET}"
    fi

    if "$CLANGXX_PATH" -fsanitize=undefined "$test_san" -o "$san_bin" 2>/dev/null; then
      echo "  ${C_GREEN}UBSanitizer: Available${C_RESET}"
    else
      echo "  ${C_RED}UBSanitizer: Not available${C_RESET}"
    fi

    rm -f -- "$test_pch" "$test_pch_bin" "$test_san" "$san_bin"
  fi

  echo ""
}

# ============================================================================ #
# End of 50-utilities.zsh
