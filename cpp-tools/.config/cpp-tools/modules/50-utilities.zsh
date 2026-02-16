# ============================================================================ #
# ++++++++++++++++++++++++++++++++ UTILITIES +++++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Maintenance utilities for cpp-tools projects.
# Includes cleaning, watching, statistics, archiving, and diagnostics.
#
# Functions:
#   - cppclean     Remove build artifacts safely.
#   - cppdeepclean Remove all generated files.
#   - cppfocus     Pin the default target used by build/run commands.
#   - cppwatch     Auto-build on file changes.
#   - cppstats     Show problem timing statistics.
#   - cpparchive   Create a contest archive.
#   - cppdiag      Display environment diagnostics.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cppclean
# -----------------------------------------------------------------------------
# Remove build artifacts safely from the project.
# -----------------------------------------------------------------------------
function cppclean() {
  _check_workspace || return 1
  if [ ! -f "CMakeLists.txt" ]; then
    echo "${C_RED}Error: No CMakeLists.txt found in $(pwd). Aborting clean to avoid accidental deletion.${C_RESET}" >&2
    return 1
  fi
  echo "${C_CYAN}Cleaning project...${C_RESET}"
  rm -rf -- build bin lib
  rm -f -- .statistics/active_build_dir
  # Also remove the symlink if it exists in the root.
  if [ -L "compile_commands.json" ]; then
    rm -- "compile_commands.json"
  fi
  echo "Project cleaned."
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
  echo "${C_YELLOW}This will remove all generated files except source code and test cases.${C_RESET}"
  echo -n "Are you sure? (y/N): "
  read -r response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    cppclean
    rm -f -- CMakeLists.txt gcc-toolchain.cmake clang-toolchain.cmake .clangd
    rm -f -- .statistics/contest_metadata .statistics/problem_times .statistics/last_config .statistics/active_build_dir
    rm -f -- .contest_metadata .problem_times
    rm -rf -- .cache
    echo "${C_GREEN}Deep clean complete.${C_RESET}"
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
  local target_name=${1:-$(_get_default_target)}
  local source_file

  # Find the actual source file extension.
  if [ -f "${target_name}.cpp" ]; then source_file="${target_name}.cpp";
  elif [ -f "${target_name}.cc" ]; then source_file="${target_name}.cc";
  elif [ -f "${target_name}.cxx" ]; then source_file="${target_name}.cxx";
  else
    echo "${C_RED}Error: Source file for target '$target_name' not found.${C_RESET}" >&2
    return 1
  fi

  if ! command -v fswatch &> /dev/null; then
    echo "${C_RED}Error: 'fswatch' is not installed. Please run 'brew install fswatch'.${C_RESET}" >&2
    return 1
  fi

  echo "${C_CYAN}Watching '$source_file' to rebuild target '$target_name'. Press Ctrl+C to stop.${C_RESET}"
  # Initial build.
  cppbuild "$target_name"

  fswatch -o "$source_file" | while read -r; do cppbuild "$target_name"; done
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

  echo "${C_BOLD}${C_BLUE}╔═══─────────── PROBLEM STATISTICS ───────────═══╗${C_RESET}"
  echo ""

  local current_time
  current_time=$(date +%s)
  while IFS=: read -r problem action timestamp _; do
    if [ "$action" = "START" ] && [[ "$timestamp" == <-> ]]; then
      local elapsed=$((current_time - timestamp))
      echo "${C_CYAN}$problem${C_RESET}: Started $(_format_duration $elapsed) ago"
    fi
  done < .statistics/problem_times

  echo ""
  echo "${C_BOLD}${C_BLUE}╚═══──────────────────────────────────────────═══╝${C_RESET}"
}

# -----------------------------------------------------------------------------
# cpparchive
# -----------------------------------------------------------------------------
# Archive the current contest directory with exclusions.
# -----------------------------------------------------------------------------
function cpparchive() {
  local contest_name
  contest_name=$(basename "$(pwd)")
  local archive_name
  archive_name="${contest_name}_$(date +%Y%m%d_%H%M%S).tar.gz"

  echo "${C_CYAN}Archiving contest to '$archive_name'...${C_RESET}"

  # Create archive excluding build artifacts.
  tar -czf "../$archive_name" \
    --exclude="build" \
    --exclude="bin" \
    --exclude="lib" \
    --exclude="*.dSYM" \
    --exclude=".git" \
    .

  echo "${C_GREEN}Contest archived to '../$archive_name'${C_RESET}"
}

# -----------------------------------------------------------------------------
# cppdiag
# -----------------------------------------------------------------------------
# Display detailed diagnostics for tools, workspace, and compilers.
# -----------------------------------------------------------------------------
function cppdiag() {
  # Helper function to print formatted headers.
  _print_header() {
    echo ""
    echo "${C_BOLD}${C_BLUE}╔═══─────────── $1 ───────────═══╗${C_RESET}"
  }

  echo "${C_BOLD}Running Competitive Programming Environment Diagnostics...${C_RESET}"

  _print_header "SYSTEM & SHELL"
  # Display OS and shell information.
  uname -a
  echo "Shell: $SHELL"
  [ -n "$BASH_VERSION" ] && echo "Bash Version: $BASH_VERSION"
  [ -n "$ZSH_VERSION" ] && echo "Zsh Version: $ZSH_VERSION"
  echo "Script Directory: $SCRIPT_DIR"

  _print_header "WORKSPACE CONFIGURATION"
  echo "CP Workspace Root: ${C_CYAN}$CP_WORKSPACE_ROOT${C_RESET}"
  echo "Algorithms Directory: ${C_CYAN}$CP_ALGORITHMS_DIR${C_RESET}"

  # Check if we're in the workspace.
  local current_dir
  current_dir="$(pwd)"
  if [[ "$current_dir" == "$CP_WORKSPACE_ROOT"* ]]; then
    echo "Current Location: ${C_GREEN}Inside workspace${C_RESET}"
  else
    echo "Current Location: ${C_YELLOW}Outside workspace${C_RESET}"
  fi

  _print_header "CORE TOOLS"

  # Check for g++
  local GXX_PATH
  GXX_PATH=$(command -v g++-15 || command -v g++-14 || command -v g++-13 || command -v g++)
  if [ -n "$GXX_PATH" ]; then
    echo "${C_GREEN}g++:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $GXX_PATH"
    echo "   ${C_CYAN}Version:${C_RESET} $($GXX_PATH --version | head -n 1)"
  else
    echo "${C_RED}g++: Not found!${C_RESET}"
  fi

  # Check for clang++
  local CLANGXX_PATH
  CLANGXX_PATH=$(command -v clang++)
  if [ -n "$CLANGXX_PATH" ]; then
    echo "${C_GREEN}clang++:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $CLANGXX_PATH"
    echo "   ${C_CYAN}Version:${C_RESET} $($CLANGXX_PATH --version | head -n 1)"

    # Check if it's Apple Clang or LLVM Clang.
    if $CLANGXX_PATH --version | grep -q "Apple"; then
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
    echo "   ${C_CYAN}Version:${C_RESET} $($CMAKE_PATH --version | head -n 1)"
  else
    echo "${C_RED}cmake: Not found!${C_RESET}"
  fi

  # Check for clangd.
  local CLANGD_PATH
  CLANGD_PATH=$(command -v clangd)
  if [ -n "$CLANGD_PATH" ]; then
    echo "${C_GREEN}clangd:${C_RESET}"
    echo "   ${C_CYAN}Path:${C_RESET} $CLANGD_PATH"
    echo "   ${C_CYAN}Version:${C_RESET} $($CLANGD_PATH --version | head -n 1)"
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

  _print_header "PROJECT CONFIGURATION (in $(pwd))"
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
    cpp_count=$(find . -maxdepth 1 -name "*.cpp" -type f 2>/dev/null | wc -l)
    echo "   ${C_CYAN}C++ files:${C_RESET} $cpp_count"

  else
    echo "${C_RED}Not inside a project directory (CMakeLists.txt not found).${C_RESET}"
  fi

  _print_header "COMPILER FEATURES CHECK"

  # Test with GCC if available.
  if [ -n "$GXX_PATH" ]; then
    echo "${C_CYAN}Testing GCC features:${C_RESET}"
    local test_file="/tmp/cp_gcc_test_$.cpp"
    cat > "$test_file" << 'EOF'
#include <bits/stdc++.h>
#include <ext/pb_ds/assoc_container.hpp>
using namespace std;
using namespace __gnu_pbds;
int main() { cout << "OK" << endl; return 0; }
EOF

    if $GXX_PATH -std=c++23 "$test_file" -o /tmp/cp_gcc_test_$ 2>/dev/null; then
      echo "  ${C_GREEN}bits/stdc++.h: Available${C_RESET}"
      echo "  ${C_GREEN}PBDS: Available${C_RESET}"
      echo "  ${C_GREEN}C++23: Supported${C_RESET}"
      rm -f /tmp/cp_gcc_test_$
    else
      echo "  ${C_RED}Some GCC features may not be available. Check your installation.${C_RESET}"
    fi
    rm -f "$test_file"
  fi

  # Test with Clang if available.
  if [ -n "$CLANGXX_PATH" ]; then
    echo ""
    echo "${C_CYAN}Testing Clang features:${C_RESET}"

    # Test PCH.h compatibility.
    local test_pch="/tmp/cp_clang_test_$.cpp"
    cat > "$test_pch" << 'EOF'
#define USE_CLANG_SANITIZE
#include "PCH.h"
using namespace std;
int main() { cout << "OK" << endl; return 0; }
EOF

    # Check if PCH.h exists in algorithms directory.
    if [ -f "algorithms/PCH.h" ]; then
      if $CLANGXX_PATH -std=c++23 -I./algorithms "$test_pch" -o /tmp/cp_clang_test_$ 2>/dev/null; then
        echo "  ${C_GREEN}PCH.h: Compatible${C_RESET}"
        echo "  ${C_GREEN}C++23: Supported${C_RESET}"
        rm -f /tmp/cp_clang_test_$
      else
        echo "  ${C_YELLOW}PCH.h compilation failed (check algorithms/PCH.h)${C_RESET}"
      fi
    else
      echo "  ${C_YELLOW}PCH.h: Not found in algorithms/ directory${C_RESET}"
    fi

    # Test sanitizer support.
    printf "#include <iostream>\nint main(){return 0;}" > "$test_pch"
    if $CLANGXX_PATH -fsanitize=address "$test_pch" -o /tmp/cp_clang_san_$ 2>/dev/null; then
      echo "  ${C_GREEN}AddressSanitizer: Available${C_RESET}"
      rm -f /tmp/cp_clang_san_$
    else
      echo "  ${C_RED}AddressSanitizer: Not available${C_RESET}"
    fi

    if $CLANGXX_PATH -fsanitize=undefined "$test_pch" -o /tmp/cp_clang_san_$ 2>/dev/null; then
      echo "  ${C_GREEN}UBSanitizer: Available${C_RESET}"
      rm -f /tmp/cp_clang_san_$
    else
      echo "  ${C_RED}UBSanitizer: Not available${C_RESET}"
    fi

    rm -f "$test_pch"
  fi

  echo ""
}

# ============================================================================ #
# End of 50-utilities.zsh
