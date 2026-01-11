# ============================================================================ #
# ++++++++++++++++++++++++++++ COMPILER UTILITIES ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Toolchain selection helpers for switching between GCC and Clang.
# Includes a quick profiling setup and configuration inspection.
#
# Functions:
#   - cppgcc    Configure build using GCC.
#   - cppclang  Configure build using Clang.
#   - cppprof   Configure profiling build.
#   - cppinfo   Display current compiler configuration.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# cppgcc
# -----------------------------------------------------------------------------
# Switch to GCC toolchain and reconfigure the project.
#
# Usage:
#   cppgcc [build_type]
# -----------------------------------------------------------------------------
function cppgcc() {
  local build_type=${1:-Debug}
  echo "${C_CYAN}Switching to GCC toolchain (${build_type})...${C_RESET}"
  echo "${C_YELLOW}Cleaning build environment first...${C_RESET}"
  cppclean
  cppconf "$build_type" gcc
}

# -----------------------------------------------------------------------------
# cppclang
# -----------------------------------------------------------------------------
# Switch to Clang toolchain and reconfigure the project.
#
# Usage:
#   cppclang [build_type]
# -----------------------------------------------------------------------------
function cppclang() {
  local build_type=${1:-Debug}
  echo "${C_CYAN}Switching to Clang toolchain (${build_type})...${C_RESET}"
  echo "${C_YELLOW}Cleaning build environment first...${C_RESET}"
  cppclean
  cppconf "$build_type" clang
}

# -----------------------------------------------------------------------------
# cppprof
# -----------------------------------------------------------------------------
# Configure a profiling build with Clang and timing enabled.
# -----------------------------------------------------------------------------
function cppprof() {
  echo "${C_CYAN}Configuring profiling build with Clang...${C_RESET}"
  echo "${C_YELLOW}Cleaning build environment first...${C_RESET}"
  cppclean
  CP_TIMING=1 cppconf Release clang
}

# -----------------------------------------------------------------------------
# cppinfo
# -----------------------------------------------------------------------------
# Display the current build configuration and compiler path.
# -----------------------------------------------------------------------------
function cppinfo() {
  if [ -f ".statistics/last_config" ]; then
    local config
    config=$(cat .statistics/last_config)
    local build_type=${config%:*}
    local compiler=${config#*:}
    echo "${C_CYAN}Current configuration:${C_RESET}"
    echo "  Build Type: ${C_YELLOW}$build_type${C_RESET}"
    echo "  Compiler: ${C_YELLOW}$compiler${C_RESET}"
  else
    echo "${C_YELLOW}No configuration found. Run 'cppconf' first.${C_RESET}"
  fi

  if [ -f "build/CMakeCache.txt" ]; then
    local actual_compiler
    actual_compiler=$(grep "CMAKE_CXX_COMPILER:FILEPATH=" build/CMakeCache.txt | cut -d'=' -f2)
    echo "  Actual Path: ${C_GREEN}$actual_compiler${C_RESET}"

    # Check for LTO support.
    if grep -q "INTERPROCEDURAL_OPTIMIZATION.*TRUE" build/CMakeCache.txt 2>/dev/null; then
      echo "  ${C_GREEN}LTO: Enabled${C_RESET}"
    fi
  fi
}

# ============================================================================ #
# End of 40-compiler.zsh
