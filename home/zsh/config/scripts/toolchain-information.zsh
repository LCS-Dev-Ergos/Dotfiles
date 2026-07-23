#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++ TOOLCHAIN INFORMATION REPORTER ++++++++++++++++++++++ #
# ============================================================================ #
# Comprehensive C/C++ compiler toolchain analysis and reporting utility.
#
# This script provides detailed information about active compiler toolchains:
#  - Compiler detection (cc, c++, gcc, g++, clang, clang++, versioned variants)
#  - Vendor identification (Apple, Homebrew, GNU, LLVM, system packages)
#  - Wrapper detection (ccache, symlinks, masquerading binaries)
#  - Version reporting with origin attribution
#  - Cross-platform support (macOS, Linux: Arch, Ubuntu, Debian)
#
# Features:
#  - Automatic detection of Homebrew versioned GCC (gcc-14, gcc-15, etc.)
#  - Symlink resolution to identify real compiler binaries
#  - ccache wrapper detection with fallback resolution
#  - Masquerading warnings (gcc pointing to clang, etc.)
#  - Color-coded output with vendor/type highlighting
#  - Environment variable override display (CC, CXX)
#  - Debug mode for detailed path resolution information
#
# Usage:
#   get_toolchain_info              # Display comprehensive toolchain report
#   TOOLCHAIN_INFO_DEBUG=1 get_toolchain_info  # Enable debug output
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

# ++++++++++++++++++++++++++ SHARED HELPERS LOADER +++++++++++++++++++++++++++ #

_toolchain_info_helpers_dir="${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts"
if [[ -r "${_toolchain_info_helpers_dir}/_shared-helpers.zsh" ]]; then
  # shellcheck disable=SC1091
  source "${_toolchain_info_helpers_dir}/_shared-helpers.zsh"
else
  printf "[ERROR] Shared helpers not found: %s/_shared-helpers.zsh\n" "$_toolchain_info_helpers_dir" >&2
  return 1 2>/dev/null || exit 1
fi
unset _toolchain_info_helpers_dir

# ++++++++++++++++++++++++++++++ Color Handling ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_info_disable_trace
# @internal
# @description Disables noisy trace options in zsh; no-op on other shells.
# @noargs
# -----------------------------------------------------------------------------
_toolchain_info_disable_trace() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    unsetopt VERBOSE SOURCE_TRACE 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_info_init_colors
# @internal
# @description Sets C_* color variables for toolchain report output.
# @noargs
# -----------------------------------------------------------------------------
_toolchain_info_init_colors() {
  _toolchain_info_disable_trace
  _shared_init_colors
}

# +++++++++++++++++++++++++++++++ HELPER UTILS +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_detect_platform
# @internal
# @description Prints a human-readable platform string with distro details.
# @noargs
# @stdout The platform string.
# -----------------------------------------------------------------------------
_toolchain_detect_platform() {
  _toolchain_info_disable_trace
  _shared_platform_pretty
}

# -----------------------------------------------------------------------------
# _toolchain_path_without_ccache
# @internal
# @description Filters ccache directories out of PATH, to find real compiler
# binaries when a ccache wrapper is active.
# @noargs
# @stdout Colon-separated PATH without ccache directories.
# -----------------------------------------------------------------------------
_toolchain_path_without_ccache() {
  _toolchain_info_disable_trace

  local IFS=:
  local dir filtered=()
  for dir in $PATH; do
    [[ "$dir" == *ccache* ]] && continue
    filtered+=("$dir")
  done
  (
    IFS=:
    printf "%s" "${filtered[*]}"
  )
}

# -----------------------------------------------------------------------------
# _toolchain_portable_realpath
# @internal
# @description Resolves a path via realpath, python3, or readlink, whichever
# is available; returns the original path unresolved as a last resort.
# @arg $1 path Target file or symlink to resolve.
# @stdout The resolved path.
# -----------------------------------------------------------------------------
_toolchain_portable_realpath() {
  _toolchain_info_disable_trace

  local target="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null && return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi

  if command -v readlink >/dev/null 2>&1 && [[ -L "$target" ]]; then
    local link
    link=$(readlink "$target" 2>/dev/null) || true
    if [[ -n "$link" ]]; then
      printf "%s\n" "$link"
      return 0
    fi
  fi

  printf "%s\n" "$target"
}

# -----------------------------------------------------------------------------
# _toolchain_find_in_path
# @internal
# @description Finds the first executable named $1 in a colon-separated path.
# @arg $1 string Binary name to search for.
# @arg $2 string Optional colon-separated search path; defaults to PATH.
# @exitcode 1 If no matching executable is found.
# @stdout The resolved binary path, on success.
# -----------------------------------------------------------------------------
_toolchain_find_in_path() {
  _toolchain_info_disable_trace

  local name="$1" search_path="${2:-$PATH}" dir
  local IFS=:
  for dir in $search_path; do
    if [[ -x "$dir/$name" ]]; then
      printf "%s\n" "$dir/$name"
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# _toolchain_resolve_real_compiler
# @internal
# @description Resolves the real compiler behind ccache wrappers or symlinks,
# falling back to common installation directories when still unresolved.
# @arg $1 path Compiler binary path to resolve.
# @stdout The resolved compiler path.
# -----------------------------------------------------------------------------
_toolchain_resolve_real_compiler() {
  # Preserve xtrace state.
  emulate -L zsh
  setopt noxtrace noverbose

  local compiler_path="$1"
  local resolved
  resolved=$(_toolchain_portable_realpath "$compiler_path")

  if [[ "$compiler_path" == *ccache* ]]; then
    local compiler_name filtered_path alt_path
    compiler_name=$(basename "$compiler_path")
    filtered_path=$(_toolchain_path_without_ccache)
    alt_path=$(_toolchain_find_in_path "$compiler_name" "$filtered_path") || true
    if [[ -n "$alt_path" ]]; then
      resolved=$(_toolchain_portable_realpath "$alt_path")
    fi

    # Fallback: search common compiler locations if we still resolve to ccache.
    if [[ "$resolved" == *ccache* ]]; then
      local fallback_dirs=(
        "/usr/bin"
        "/usr/local/bin"
        "/opt/homebrew/bin"
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
      )
      local dir
      for dir in "${fallback_dirs[@]}"; do
        if [[ -x "$dir/$compiler_name" ]]; then
          resolved=$(_toolchain_portable_realpath "$dir/$compiler_name")
          break
        fi
      done
    fi
  fi

  printf "%s\n" "${resolved:-$compiler_path}"
}

# -----------------------------------------------------------------------------
# _toolchain_vendor_for_gcc
# @internal
# @description Identifies the GCC vendor from version output and path.
# @arg $1 string Output of `compiler --version`.
# @arg $2 path Compiler binary path.
# @stdout The vendor label (e.g. "Homebrew GNU", "GNU (Arch)").
# -----------------------------------------------------------------------------
_toolchain_vendor_for_gcc() {
  _toolchain_info_disable_trace

  local version_info="$1" compiler_path="$2"
  if [[ "$version_info" == *"Homebrew"* ]]; then
    echo "Homebrew GNU"
  elif [[ "$compiler_path" == /opt/homebrew/Cellar/gcc/* ]]; then
    echo "Homebrew GNU"
  elif [[ "$version_info" == *"Ubuntu"* ]]; then
    echo "GNU (Ubuntu)"
  elif [[ "$version_info" == *"Debian"* ]]; then
    echo "GNU (Debian)"
  elif [[ "$version_info" == *"Arch Linux"* || "$version_info" == *"Archlinux"* ]]; then
    echo "GNU (Arch)"
  elif [[ "$compiler_path" == /usr/bin/* ]]; then
    echo "GNU (system)"
  else
    echo "GNU"
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_vendor_for_clang
# @internal
# @description Identifies the Clang/LLVM vendor from version output and path.
# @arg $1 string Output of `compiler --version`.
# @arg $2 path Compiler binary path.
# @stdout The vendor label (e.g. "Apple", "Nix LLVM", "Homebrew LLVM").
# -----------------------------------------------------------------------------
_toolchain_vendor_for_clang() {
  # Preserve xtrace state.
  emulate -L zsh
  setopt noxtrace noverbose

  local version_info="$1" compiler_path="$2"
  if [[ "$version_info" == *"Apple clang"* ]]; then
    echo "Apple"
  elif [[ "$compiler_path" == /nix/store/* \
    || "$compiler_path" == /etc/profiles/per-user/* \
    || "$compiler_path" == /run/current-system/sw/* ]]; then
    echo "Nix LLVM"
  elif [[ "$version_info" == *"Homebrew"* ]]; then
    echo "Homebrew LLVM"
  elif [[ "$version_info" == *"Ubuntu"* ]]; then
    echo "LLVM (Ubuntu)"
  elif [[ "$version_info" == *"Debian"* ]]; then
    echo "LLVM (Debian)"
  elif [[ "$compiler_path" == /usr/bin/* ]]; then
    echo "LLVM (system)"
  else
    echo "LLVM"
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_compiler_details
# @internal
# @description Runs the compiler with --version and identifies its type,
# vendor, and version.
# @arg $1 path Compiler binary path.
# @stdout Pipe-delimited "type|vendor|version".
# -----------------------------------------------------------------------------
_toolchain_compiler_details() {
  # Preserve xtrace state.
  emulate -L zsh
  setopt noxtrace noverbose

  local compiler_path="$1"
  local version_info toolchain_type="Unknown" vendor=""

  # Get version information.
  if ! version_info=$("$compiler_path" --version 2>/dev/null | head -n 1); then
    version_info="Version information unavailable"
    printf "%s|%s|%s\n" "$toolchain_type" "$vendor" "$version_info"
    return
  fi

  version_info="${version_info//$'\r'/}"

  # Determine toolchain type and vendor.
  if [[ "$version_info" == *"Apple clang"* || "$version_info" == *"clang version"* ]]; then
    toolchain_type="Clang"
    vendor=$(_toolchain_vendor_for_clang "$version_info" "$compiler_path")
  elif [[ "$version_info" == *"(GCC)"* || "$version_info" == *"gcc version"* || "$version_info" == *"Homebrew GCC"* ]]; then
    toolchain_type="GCC"
    vendor=$(_toolchain_vendor_for_gcc "$version_info" "$compiler_path")
  fi

  printf "%s|%s|%s\n" "$toolchain_type" "$vendor" "$version_info"
}

# ++++++++++++++++++++++++++++++ MAIN FUNCTION +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# get_toolchain_info
# @description Reports compiler vendors, versions, wrappers, and PATH entries.
# TOOLCHAIN_INFO_DEBUG=1 adds diagnostic details to the report.
# @noargs
# -----------------------------------------------------------------------------
get_toolchain_info() {
  # Preserve xtrace state.
  emulate -L zsh
  setopt noxtrace

  # Initialize colors.
  _toolchain_info_init_colors

  echo "${C_GREEN}╞════════════════════════════════════════════════════════════════════╡${C_RESET}"
  printf "\n%s%sAnalyzing C/C++ toolchain configuration (%s)...%s\n" \
    "$C_BOLD" "$C_CYAN" "$(_toolchain_detect_platform)" "$C_RESET"

  if [[ -n "${CC:-}" || -n "${CXX:-}" ]]; then
    printf "%sEnvironment variables (override defaults):%s\n" "$C_YELLOW" "$C_RESET"
    [[ -n "${CC:-}" ]] && printf "   %sCC  = %s%s%s\n" "$C_BOLD" "$C_CYAN" "$CC" "$C_RESET"
    [[ -n "${CXX:-}" ]] && printf "   %sCXX = %s%s%s\n" "$C_BOLD" "$C_CYAN" "$CXX" "$C_RESET"
    echo
  fi

  local -a compilers=("cc" "c++" "gcc" "g++" "clang" "clang++")
  local -A seen_compilers=()
  local name

  # Add Homebrew versioned GCC binaries if present (e.g., gcc-15, g++-15).
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    local brew_prefix gcc_bin
    if command -v brew >/dev/null 2>&1; then
      brew_prefix=$(brew --prefix 2>/dev/null)
      if [[ -n "$brew_prefix" && -d "$brew_prefix/opt/gcc/bin" ]]; then
        gcc_bin="$brew_prefix/opt/gcc/bin"
      fi
    fi

    if [[ -z "$gcc_bin" && -d "/opt/homebrew/opt/gcc/bin" ]]; then
      gcc_bin="/opt/homebrew/opt/gcc/bin"
    fi

    if [[ -n "$gcc_bin" && -d "$gcc_bin" ]]; then
      while IFS= read -r compiler_entry; do
        name=$(basename "$compiler_entry")
        if [[ -n "$name" ]]; then
          compilers+=("$name")
        fi
      done < <(find "$gcc_bin" -maxdepth 1 -type f \( -name "gcc-[0-9]*" -o -name "g++-[0-9]*" \) -print 2>/dev/null | sort -V)
    fi
  fi

  # Deduplicate while preserving order.
  local -a unique=()
  local comp_name
  for comp_name in "${compilers[@]}"; do
    if [[ -z "${seen_compilers[$comp_name]:-}" ]]; then
      seen_compilers["$comp_name"]=1
      unique+=("$comp_name")
    fi
  done
  compilers=("${unique[@]}")

  printf "%sActive compilers in PATH:%s\n\n" "$C_BOLD" "$C_RESET"

  local compiler
  for compiler in "${compilers[@]}"; do
    local cpath
    cpath=$(command -v "$compiler" 2>/dev/null)

    if [[ -n "$cpath" && -x "$cpath" ]]; then
      local real_cpath
      real_cpath=$(_toolchain_resolve_real_compiler "$cpath")

      local wrapper_details
      local real_details
      wrapper_details=$(_toolchain_compiler_details "$cpath")
      real_details=$(_toolchain_compiler_details "$real_cpath")

      IFS='|' read -r wrapper_type wrapper_vendor wrapper_version <<<"$wrapper_details"
      IFS='|' read -r real_type real_vendor real_version <<<"$real_details"

      printf "%s◆ %-10s%s %s%s%s\n" "$C_GREEN" "$compiler" "$C_RESET" "$C_CYAN" "$cpath" "$C_RESET"

      local has_wrapper=false
      if [[ "$cpath" == *"/ccache/"* || "$cpath" == *"ccache/bin"* ]]; then
        printf "  ├─ %sWrapper:%s ccache (caching)\n" "$C_YELLOW" "$C_RESET"
        has_wrapper=true
      elif [[ "$cpath" != "$real_cpath" ]]; then
        printf "  ├─ %sSymlink:%s → %s%s%s\n" "$C_YELLOW" "$C_RESET" "$C_CYAN" "$real_cpath" "$C_RESET"
        has_wrapper=true
      fi

      if [[ "$has_wrapper" == true ]]; then
        printf "  └─ %sReal compiler:%s %s %s\n" "$C_BLUE" "$C_RESET" "$real_vendor" "$real_type"
        printf "     %sVersion:%s %s\n" "$C_MAGENTA" "$C_RESET" "$real_version"
      else
        printf "  ├─ %sType:%s %s %s\n" "$C_BLUE" "$C_RESET" "$real_vendor" "$real_type"
        printf "  └─ %sVersion:%s %s\n" "$C_MAGENTA" "$C_RESET" "$real_version"
      fi

      if [[ ("$compiler" == "gcc" || "$compiler" == "g++") && "$real_type" == "Clang" ]]; then
        printf "     %sWarning:%s '%s' resolves to Clang, not GCC\n" "$C_YELLOW" "$C_RESET" "$compiler"
      elif [[ ("$compiler" == "clang" || "$compiler" == "clang++") && "$real_type" == "GCC" ]]; then
        printf "     %sWarning:%s '%s' resolves to GCC, not Clang\n" "$C_YELLOW" "$C_RESET" "$compiler"
      fi

      if [[ "${TOOLCHAIN_INFO_DEBUG:-0}" != "0" ]]; then
        printf "     %sDebug:%s compiler_path=%s%s%s\n" "$C_BOLD" "$C_RESET" "$C_CYAN" "$cpath" "$C_RESET"
        printf "            real_compiler_path=%s%s%s\n" "$C_CYAN" "$real_cpath" "$C_RESET"
        printf "            wrapper_details='%s%s%s|%s%s%s|%s%s%s'\n" \
          "$C_BLUE" "$wrapper_type" "$C_RESET" "$C_YELLOW" "$wrapper_vendor" "$C_RESET" "$C_MAGENTA" "$wrapper_version" "$C_RESET"
        printf "            real_details='%s%s%s|%s%s%s|%s%s%s'\n" \
          "$C_BLUE" "$real_type" "$C_RESET" "$C_YELLOW" "$real_vendor" "$C_RESET" "$C_MAGENTA" "$real_version" "$C_RESET"
      fi
      echo
    else
      printf "%s✗ %-10s%s Not found in PATH\n\n" "$C_RED" "$compiler" "$C_RESET"
    fi
  done

  echo "${C_GREEN}╞════════════════════════════════════════════════════════════════════╡${C_RESET}"
}

# ============================================================================ #
# End of toolchain-information.zsh
