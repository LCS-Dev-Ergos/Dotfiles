#!/usr/bin/env bash
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++ Cross-Platform Toolchain Switcher +++++++++++++++++++ #
# ============================================================================ #
# Advanced compiler toolchain management for macOS and Linux development.
#
# This script provides intelligent switching between LLVM/Clang and GNU GCC
# toolchains with automatic detection of installation paths from:
# - Homebrew installations (macOS: /opt/homebrew, /usr/local)
# - System package managers (Arch Linux, Ubuntu, Debian)
# - Custom LLVM installations (/usr/lib/llvm*, /opt/llvm*)
#
# Features:
# - Automatic version selection (prefers highest versioned binary)
# - Safe environment preservation and restoration
# - PATH manipulation with original state backup
# - Compiler flags configuration (LDFLAGS, CPPFLAGS)
# - Cross-platform compatibility (macOS Darwin, Linux)
# - Color-coded logging and status messages
#
# Usage:
#   use_llvm    # Activate LLVM/Clang toolchain
#   use_gnu     # Activate GNU GCC toolchain
#   use_system  # Restore original system environment
#
# Environment Variables (preserved):
#   CC, CXX, LDFLAGS, CPPFLAGS, PKG_CONFIG_PATH, PATH
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

# ++++++++++++++++++++++++++++++ Color Handling +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_init_colors
# -----------------------------------------------------------------------------
# Initializes terminal color codes for formatted output.
# Detects terminal capabilities and sets color variables. Falls back to
# empty strings if terminal doesn't support colors.
#
# Usage:
#   _toolchain_init_colors
#
# Returns:
#   0 - Always succeeds
#
# Side Effects:
#   - Sets global color variables: C_RESET, C_BOLD, C_RED, C_GREEN, etc.
# -----------------------------------------------------------------------------
_toolchain_init_colors() {
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
    C_RESET=$'\e[0m'
    C_BOLD=$'\e[1m'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_CYAN=$'\e[36m'
  else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
  fi
}

# ------------------------------ Platform Probe ------------------------------ #

# -----------------------------------------------------------------------------
# _toolchain_detect_platform
# -----------------------------------------------------------------------------
# Detects operating system and Linux distribution.
# Sets TOOLCHAIN_OS (macOS/Linux/Other) and TOOLCHAIN_DISTRO (Arch) globals.
# Idempotent - returns immediately if already detected.
#
# Usage:
#   _toolchain_detect_platform
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Sets TOOLCHAIN_OS global variable.
#   - Sets TOOLCHAIN_DISTRO for Arch Linux detection.
# -----------------------------------------------------------------------------
_toolchain_detect_platform() {
  if [[ -n "${TOOLCHAIN_OS:-}" ]]; then
    return
  fi

  case "$(uname -s 2>/dev/null)" in
    Darwin) TOOLCHAIN_OS="macOS" ;;
    Linux) TOOLCHAIN_OS="Linux" ;;
    *) TOOLCHAIN_OS="Other" ;;
  esac

  if [[ "$TOOLCHAIN_OS" == "Linux" && -f "/etc/arch-release" ]]; then
    TOOLCHAIN_DISTRO="Arch"
  fi
}

# ------------------------------ State Storage ------------------------------- #
# Ensure PATH is not empty; otherwise, fall back to a sane default to avoid
# breaking builtin utilities when this file is sourced in a bad environment.
if [[ -z "${PATH:-}" ]]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
fi

if [[ -z "${ORIGINAL_PATH:-}" ]]; then
  export ORIGINAL_PATH="${PATH}"
fi
: "${TOOLCHAIN_ORIGINAL_PATH:=${ORIGINAL_PATH}}"

if [[ -z "${_TOOLCHAIN_SAVED_ENV:-}" ]]; then
  _TOOLCHAIN_SAVED_ENV=1
  TOOLCHAIN_ORIGINAL_LDFLAGS="${LDFLAGS-__TOOLCHAIN_UNSET__}"
  TOOLCHAIN_ORIGINAL_CPPFLAGS="${CPPFLAGS-__TOOLCHAIN_UNSET__}"
  TOOLCHAIN_ORIGINAL_PKG_CONFIG_PATH="${PKG_CONFIG_PATH-__TOOLCHAIN_UNSET__}"
  TOOLCHAIN_ORIGINAL_CC="${CC-__TOOLCHAIN_UNSET__}"
  TOOLCHAIN_ORIGINAL_CXX="${CXX-__TOOLCHAIN_UNSET__}"
fi

# +++++++++++++++++++++++++++++++ Log Helpers ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_log
# -----------------------------------------------------------------------------
# Formatted logging function with color-coded severity levels.
# Supports info, ok, warn, and error levels with appropriate colors.
#
# Usage:
#   _toolchain_log <level> <message...>
#
# Arguments:
#   level - Log level: info, ok, warn, error (required).
#   message - Log message text, supports multiple arguments (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Outputs to stdout for info/ok, stderr for warn/error.
# -----------------------------------------------------------------------------
_toolchain_log() {
  local level="$1"
  shift
  case "$level" in
    info) printf "%s[INFO]%s %s\n" "$C_CYAN" "$C_RESET" "$*" ;;
    ok) printf "%s[OK]%s   %s\n" "$C_GREEN" "$C_RESET" "$*" ;;
    warn) printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2 ;;
    error) printf "%s[ERROR]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2 ;;
  esac
}

# -----------------------------------------------------------------------------
# _toolchain_restore_var
# -----------------------------------------------------------------------------
# Restores an environment variable to its original state.
# Handles both set and unset variables using sentinel value.
#
# Usage:
#   _toolchain_restore_var <name> <original_value>
#
# Arguments:
#   name - Environment variable name (required).
#   original_value - Original value or "__TOOLCHAIN_UNSET__" sentinel (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Exports variable with original value or unsets it.
# -----------------------------------------------------------------------------
_toolchain_restore_var() {
  local name="$1" value="$2"
  if [[ "$value" == "__TOOLCHAIN_UNSET__" ]]; then
    unset "$name"
  else
    export "$name=$value"
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_reset_env_to_original
# -----------------------------------------------------------------------------
# Resets all compiler-related environment variables to original state.
# Restores LDFLAGS, CPPFLAGS, PKG_CONFIG_PATH, CC, and CXX.
#
# Usage:
#   _toolchain_reset_env_to_original
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Restores or unsets compiler environment variables.
# -----------------------------------------------------------------------------
_toolchain_reset_env_to_original() {
  _toolchain_restore_var LDFLAGS "$TOOLCHAIN_ORIGINAL_LDFLAGS"
  _toolchain_restore_var CPPFLAGS "$TOOLCHAIN_ORIGINAL_CPPFLAGS"
  _toolchain_restore_var PKG_CONFIG_PATH "$TOOLCHAIN_ORIGINAL_PKG_CONFIG_PATH"
  _toolchain_restore_var CC "$TOOLCHAIN_ORIGINAL_CC"
  _toolchain_restore_var CXX "$TOOLCHAIN_ORIGINAL_CXX"
}

# -----------------------------------------------------------------------------
# _toolchain_set_path
# -----------------------------------------------------------------------------
# Modifies PATH to prioritize specified toolchain binary directory.
# Prepends bin_dir to original PATH or restores original if empty.
#
# Usage:
#   _toolchain_set_path <bin_dir>
#
# Arguments:
#   bin_dir - Toolchain binary directory or empty to restore (required).
#
# Returns:
#   0 - Always succeeds.
#
# Side Effects:
#   - Exports PATH with bin_dir prepended.
#   - Sets TOOLCHAIN_ACTIVE_BIN global variable.
# -----------------------------------------------------------------------------
_toolchain_set_path() {
  local bin_dir="$1"
  local base="${TOOLCHAIN_ORIGINAL_PATH}"
  if [[ -z "$base" ]]; then
    base="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  fi
  if [[ -n "$bin_dir" ]]; then
    export PATH="${bin_dir}:${base}"
    TOOLCHAIN_ACTIVE_BIN="$bin_dir"
  else
    export PATH="${base}"
    TOOLCHAIN_ACTIVE_BIN=""
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_get_homebrew_prefix
# -----------------------------------------------------------------------------
# Determines Homebrew installation prefix with fallback detection.
# Checks HOMEBREW_PREFIX env, brew command, and common installation paths.
#
# Usage:
#   prefix=$(_toolchain_get_homebrew_prefix)
#
# Returns:
#   0 - Homebrew prefix found (outputs path to stdout).
#   1 - Homebrew not found.
#
# Side Effects:
#   - Outputs Homebrew prefix path to stdout on success.
#
# Dependencies:
#   brew - Homebrew package manager (optional).
# -----------------------------------------------------------------------------
_toolchain_get_homebrew_prefix() {
  if [[ -n "${HOMEBREW_PREFIX:-}" && -d "${HOMEBREW_PREFIX}" ]]; then
    echo "${HOMEBREW_PREFIX}"
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    local prefix
    prefix=$(brew --prefix 2>/dev/null)
    if [[ -n "$prefix" && -d "$prefix" ]]; then
      echo "$prefix"
      return 0
    fi
  fi

  for prefix in /opt/homebrew /usr/local; do
    if [[ -d "$prefix" ]]; then
      echo "$prefix"
      return 0
    fi
  done

  return 1
}

# -----------------------------------------------------------------------------
# _toolchain_find_best_binary
# -----------------------------------------------------------------------------
# Finds the best available version of a compiler binary.
# Searches PATH and additional directories for versioned binaries (e.g., gcc-14).
# Prefers highest version number over unversioned binaries.
#
# Usage:
#   binary_path=$(_toolchain_find_best_binary <base_name> [extra_dirs...])
#
# Arguments:
#   base_name - Base binary name (e.g., "gcc", "clang") (required).
#   extra_dirs - Additional directories to search (optional).
#
# Returns:
#   0 - Binary found (outputs path to stdout).
#   1 - Binary not found (outputs nothing).
#
# Side Effects:
#   - Outputs binary path to stdout on success.
#
# Dependencies:
#   find - File search utility.
# -----------------------------------------------------------------------------
_toolchain_find_best_binary() {
  local base="$1"
  shift
  local fallback="" best="" best_ver=-1 dir candidate_path ver ver_str

  local -a dirs=()
  local IFS=:
  for dir in $PATH; do
    dirs+=("$dir")
  done
  for dir in "$@"; do
    dirs+=("$dir")
  done

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    if [[ -x "$dir/$base" && -z "$fallback" ]]; then
      fallback="$dir/$base"
    fi

    # Prefer versioned binaries (e.g., clang-20, gcc-14) without relying on shell globbing.
    while IFS= read -r candidate_path; do
      ver_str="${candidate_path##*-}"
      case "$ver_str" in
        '' | *[!0-9]*) continue ;;
      esac
      ver=$ver_str
      if ((ver > best_ver)); then
        best_ver=$ver
        best="$candidate_path"
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name "$base-[0-9]*" -print 2>/dev/null)
  done

  # Last resort: whatever command -v sees.
  if [[ -z "$best" && -z "$fallback" ]]; then
    local from_path
    from_path=$(command -v "$base" 2>/dev/null || true)
    if [[ -n "$from_path" ]]; then
      fallback="$from_path"
    fi
  fi

  if [[ -n "$best" ]]; then
    printf "%s\n" "$best"
  elif [[ -n "$fallback" ]]; then
    printf "%s\n" "$fallback"
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_select_llvm_bin_dir
# -----------------------------------------------------------------------------
# Locates LLVM/Clang installation binary directory.
# Searches platform-specific locations and selects highest version.
# macOS: Homebrew (/opt/homebrew, /usr/local)
# Linux: System paths (/usr/lib/llvm*, /opt/llvm*)
#
# Usage:
#   llvm_dir=$(_toolchain_select_llvm_bin_dir)
#
# Returns:
#   0 - LLVM directory found (outputs path to stdout).
#   1 - LLVM not found (outputs nothing).
#
# Side Effects:
#   - Outputs LLVM bin directory path to stdout on success.
# -----------------------------------------------------------------------------
_toolchain_select_llvm_bin_dir() {
  local -a candidates=()

  if [[ "$TOOLCHAIN_OS" == "macOS" ]]; then
    local brew_prefix
    brew_prefix=$(_toolchain_get_homebrew_prefix 2>/dev/null) || true
    if [[ -n "$brew_prefix" && -d "$brew_prefix/opt/llvm/bin" ]]; then
      candidates+=("$brew_prefix/opt/llvm/bin")
    fi
    [[ -d "/usr/local/opt/llvm/bin" ]] && candidates+=("/usr/local/opt/llvm/bin")
    [[ -d "/opt/homebrew/opt/llvm/bin" ]] && candidates+=("/opt/homebrew/opt/llvm/bin")
  else
    candidates+=(
      /usr/lib/llvm*/bin
      /usr/lib64/llvm*/bin
      /usr/local/llvm*/bin
      /opt/llvm*/bin
    )
  fi

  local best="" best_ver=-1 dir dir_no_bin ver resolved
  for dir in "${candidates[@]}"; do
    for resolved in $dir; do
      [[ -d "$resolved" ]] || continue
      dir_no_bin="${resolved%/bin}"
      ver="${dir_no_bin##*-}"
      case "$ver" in
        '' | *[!0-9]*) ver=0 ;;
      esac
      if ((ver > best_ver)); then
        best_ver=$ver
        best="$resolved"
      fi
    done
  done

  if [[ -n "$best" ]]; then
    printf "%s\n" "$best"
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_select_gcc_bin_dir
# -----------------------------------------------------------------------------
# Locates GNU GCC installation binary directory.
# macOS: Homebrew GCC installation
# Linux: System GCC (/usr/bin, /usr/local/bin)
#
# Usage:
#   gcc_dir=$(_toolchain_select_gcc_bin_dir)
#
# Returns:
#   0 - GCC directory found (outputs path to stdout).
#   1 - GCC not found (outputs nothing).
#
# Side Effects:
#   - Outputs GCC bin directory path to stdout on success.
# -----------------------------------------------------------------------------
_toolchain_select_gcc_bin_dir() {
  if [[ "$TOOLCHAIN_OS" == "macOS" ]]; then
    local brew_prefix
    brew_prefix=$(_toolchain_get_homebrew_prefix 2>/dev/null) || true
    if [[ -n "$brew_prefix" && -d "$brew_prefix/opt/gcc/bin" ]]; then
      printf "%s\n" "$brew_prefix/opt/gcc/bin"
      return 0
    fi
    return 1
  fi

  # Linux: prefer distro gcc in /usr/bin (Arch/Ubuntu) or /usr/local/bin.
  if [[ "$TOOLCHAIN_OS" == "Linux" ]]; then
    if [[ -x "/usr/bin/gcc" ]]; then
      printf "%s\n" "/usr/bin"
      return 0
    fi
    if [[ -x "/usr/local/bin/gcc" ]]; then
      printf "%s\n" "/usr/local/bin"
      return 0
    fi
  fi

  return 1
}

# -----------------------------------------------------------------------------
# _toolchain_verify_compiler
# -----------------------------------------------------------------------------
# Verifies compiler availability and displays version information.
# Executes compiler with --version flag to confirm functionality.
#
# Usage:
#   _toolchain_verify_compiler <compiler>
#
# Arguments:
#   compiler - Compiler binary name or path (required).
#
# Returns:
#   0 - Compiler found and working.
#   1 - Compiler not found or not functional.
#
# Side Effects:
#   - Logs compiler version or warning message.
# -----------------------------------------------------------------------------
_toolchain_verify_compiler() {
  local compiler="$1"
  if command -v "$compiler" >/dev/null 2>&1; then
    local version_output
    version_output=$("$compiler" --version 2>/dev/null | head -n 1)
    if [[ -n "$version_output" ]]; then
      _toolchain_log ok "${compiler}: ${version_output}"
      return 0
    fi
  fi
  _toolchain_log warn "Compiler '${compiler}' not found or not working properly."
  return 1
}

# +++++++++++++++++++++++++ Main Toolchain Functions +++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# use_llvm
# -----------------------------------------------------------------------------
# Activates LLVM/Clang toolchain for C/C++ development.
# Automatically detects and configures the best available LLVM installation
# from Homebrew (macOS) or system packages (Linux). Sets CC, CXX, PATH,
# and compiler flags (LDFLAGS, CPPFLAGS on macOS).
#
# Usage:
#   use_llvm
#
# Returns:
#   0 - LLVM toolchain activated successfully.
#   1 - LLVM toolchain not found.
#
# Side Effects:
#   - Modifies PATH to prioritize LLVM bin directory.
#   - Exports CC=clang, CXX=clang++.
#   - Sets LDFLAGS and CPPFLAGS on macOS for Homebrew LLVM.
#   - Resets other compiler environment variables to original state.
#   - Displays activation status and compiler versions.
#
# Environment Variables Modified:
#   PATH, CC, CXX, LDFLAGS (macOS), CPPFLAGS (macOS).
#
# Dependencies:
#   clang, clang++ - LLVM compiler binaries.
# -----------------------------------------------------------------------------
use_llvm() {
  _toolchain_init_colors
  _toolchain_detect_platform
  printf "%s%s[+] Activating LLVM/Clang toolchain...%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  _toolchain_reset_env_to_original

  local llvm_bin_dir clang_bin cxx_bin prefix_for_flags
  llvm_bin_dir=$(_toolchain_select_llvm_bin_dir) || true

  clang_bin=$(_toolchain_find_best_binary "clang" "$llvm_bin_dir") || true
  cxx_bin=$(_toolchain_find_best_binary "clang++" "$llvm_bin_dir") || true

  if [[ -z "$clang_bin" || -z "$cxx_bin" ]]; then
    _toolchain_log error "No Clang toolchain found. Install with Homebrew (macOS) or your package manager (e.g., pacman -S clang / apt install clang)."
    return 1
  fi

  local bin_dir_for_path
  bin_dir_for_path="$(dirname "$clang_bin")"
  _toolchain_set_path "$bin_dir_for_path"

  prefix_for_flags="${bin_dir_for_path%/bin}"
  if [[ "$TOOLCHAIN_OS" == "macOS" && -d "$prefix_for_flags/lib" ]]; then
    local base_ldflags base_cppflags
    [[ "$TOOLCHAIN_ORIGINAL_LDFLAGS" == "__TOOLCHAIN_UNSET__" ]] && base_ldflags="" || base_ldflags="$TOOLCHAIN_ORIGINAL_LDFLAGS"
    [[ "$TOOLCHAIN_ORIGINAL_CPPFLAGS" == "__TOOLCHAIN_UNSET__" ]] && base_cppflags="" || base_cppflags="$TOOLCHAIN_ORIGINAL_CPPFLAGS"

    export LDFLAGS="-L${prefix_for_flags}/lib${base_ldflags:+ ${base_ldflags}}"
    export CPPFLAGS="-I${prefix_for_flags}/include${base_cppflags:+ ${base_cppflags}}"
  fi

  export CC
  export CXX
  CC=$(basename "$clang_bin")
  CXX=$(basename "$cxx_bin")

  _toolchain_log info "PATH=${PATH}"
  _toolchain_log ok "CC='${CC}', CXX='${CXX}'"
  _toolchain_verify_compiler "$CC"
  _toolchain_verify_compiler "$CXX"
}

# -----------------------------------------------------------------------------
# use_gnu
# -----------------------------------------------------------------------------
# Activates GNU GCC toolchain for C/C++ development.
# Automatically detects and configures the best available GCC installation
# from Homebrew (macOS) or system packages (Linux). Sets CC, CXX, and PATH.
#
# Usage:
#   use_gnu
#
# Returns:
#   0 - GCC toolchain activated successfully.
#   1 - GCC toolchain not found.
#
# Side Effects:
#   - Modifies PATH to prioritize GCC bin directory.
#   - Exports CC=gcc, CXX=g++.
#   - Resets other compiler environment variables to original state.
#   - Displays activation status and compiler versions.
#
# Environment Variables Modified:
#   PATH, CC, CXX.
#
# Dependencies:
#   gcc, g++ - GNU compiler collection binaries.
# -----------------------------------------------------------------------------
use_gnu() {
  _toolchain_init_colors
  _toolchain_detect_platform
  printf "%s%s[+] Activating GNU GCC toolchain...%s\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  _toolchain_reset_env_to_original

  local gcc_bin_dir gcc_bin gxx_bin
  gcc_bin_dir=$(_toolchain_select_gcc_bin_dir) || true

  gcc_bin=$(_toolchain_find_best_binary "gcc" "$gcc_bin_dir") || true
  gxx_bin=$(_toolchain_find_best_binary "g++" "$gcc_bin_dir") || true

  if [[ -z "$gcc_bin" || -z "$gxx_bin" ]]; then
    _toolchain_log error "GCC not found. Install via Homebrew (macOS) or your distro packages (e.g., pacman -S gcc / apt install build-essential)."
    return 1
  fi

  local bin_dir_for_path
  bin_dir_for_path="$(dirname "$gcc_bin")"
  _toolchain_set_path "$bin_dir_for_path"

  export CC
  export CXX
  CC=$(basename "$gcc_bin")
  CXX=$(basename "$gxx_bin")

  _toolchain_log info "PATH=${PATH}"
  _toolchain_log ok "CC='${CC}', CXX='${CXX}'"
  _toolchain_verify_compiler "$CC"
  _toolchain_verify_compiler "$CXX"
}

# -----------------------------------------------------------------------------
# use_system
# -----------------------------------------------------------------------------
# Restores original system toolchain and environment variables.
# Resets PATH and all compiler-related variables (CC, CXX, LDFLAGS, CPPFLAGS)
# to their state before any toolchain switching occurred.
#
# Usage:
#   use_system
#
# Returns:
#   0 - System toolchain restored successfully.
#   1 - Original PATH not available (shell restart required).
#
# Side Effects:
#   - Restores PATH to original value.
#   - Resets CC, CXX, LDFLAGS, CPPFLAGS, PKG_CONFIG_PATH to original state.
#   - Displays system compiler information.
#
# Environment Variables Modified:
#   PATH, CC, CXX, LDFLAGS, CPPFLAGS, PKG_CONFIG_PATH.
# -----------------------------------------------------------------------------
use_system() {
  _toolchain_init_colors
  printf "%s%s[*] Restoring system/default toolchain...%s\n" "$C_BOLD" "$C_YELLOW" "$C_RESET"

  if [[ -z "${TOOLCHAIN_ORIGINAL_PATH:-}" ]]; then
    _toolchain_log error "TOOLCHAIN_ORIGINAL_PATH not set. Restart the shell if restoration fails."
    return 1
  fi

  _toolchain_set_path ""
  _toolchain_reset_env_to_original

  local system_cc system_cxx
  system_cc=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null || command -v gcc 2>/dev/null)
  system_cxx=$(command -v c++ 2>/dev/null || command -v clang++ 2>/dev/null || command -v g++ 2>/dev/null)

  if [[ -n "$system_cc" ]]; then
    _toolchain_log ok "System C compiler: $system_cc"
    _toolchain_verify_compiler "$system_cc"
  else
    _toolchain_log warn "No system C compiler detected in PATH."
  fi

  if [[ -n "$system_cxx" ]]; then
    _toolchain_log ok "System C++ compiler: $system_cxx"
    _toolchain_verify_compiler "$system_cxx"
  else
    _toolchain_log warn "No system C++ compiler detected in PATH."
  fi

  _toolchain_log ok "System toolchain restored."
}

# ============================================================================ #
# End of script.
