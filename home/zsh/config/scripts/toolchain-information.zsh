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
#  - Shared Gum/ANSI/plain presentation
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
  setopt noxtrace noverbose typesetsilent

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
    print -r -- "Homebrew GNU"
  elif [[ "$compiler_path" == /opt/homebrew/Cellar/gcc/* ]]; then
    print -r -- "Homebrew GNU"
  elif [[ "$version_info" == *"Ubuntu"* ]]; then
    print -r -- "GNU (Ubuntu)"
  elif [[ "$version_info" == *"Debian"* ]]; then
    print -r -- "GNU (Debian)"
  elif [[ "$version_info" == *"Arch Linux"* || "$version_info" == *"Archlinux"* ]]; then
    print -r -- "GNU (Arch)"
  elif [[ "$compiler_path" == /usr/bin/* ]]; then
    print -r -- "GNU (system)"
  else
    print -r -- "GNU"
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
    print -r -- "Apple"
  elif [[ "$compiler_path" == /nix/store/* \
    || "$compiler_path" == /etc/profiles/per-user/* \
    || "$compiler_path" == /run/current-system/sw/* ]]; then
    print -r -- "Nix LLVM"
  elif [[ "$version_info" == *"Homebrew"* ]]; then
    print -r -- "Homebrew LLVM"
  elif [[ "$version_info" == *"Ubuntu"* ]]; then
    print -r -- "LLVM (Ubuntu)"
  elif [[ "$version_info" == *"Debian"* ]]; then
    print -r -- "LLVM (Debian)"
  elif [[ "$compiler_path" == /usr/bin/* ]]; then
    print -r -- "LLVM (system)"
  else
    print -r -- "LLVM"
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
  emulate -L zsh
  setopt noxtrace noverbose typesetsilent

  local platform="$(_toolchain_detect_platform)"
  _zsh_ui_heading \
    "C/C++ toolchain" \
    "Active compiler resolution · $platform" || return 1

  if [[ -n "${CC:-}" || -n "${CXX:-}" ]]; then
    local -a environment_rows=()
    [[ -n "${CC:-}" ]] && environment_rows+=("CC"$'\t'"$CC")
    [[ -n "${CXX:-}" ]] && environment_rows+=("CXX"$'\t'"$CXX")
    print -r -- ""
    _zsh_ui_section "Environment overrides" || return 1
    _zsh_ui_table $'Variable\tValue' "${environment_rows[@]}" || return 1
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

  local -a rows=() debug_rows=()
  local -i available=0 missing=0
  local compiler
  for compiler in "${compilers[@]}"; do
    local cpath=""
    cpath=$(command -v "$compiler" 2>/dev/null)

    if [[ -n "$cpath" && -x "$cpath" ]]; then
      local real_cpath wrapper_details real_details
      real_cpath=$(_toolchain_resolve_real_compiler "$cpath")
      wrapper_details=$(_toolchain_compiler_details "$cpath")
      real_details=$(_toolchain_compiler_details "$real_cpath")

      local -a wrapper_fields=("${(@s:|:)wrapper_details}")
      local -a real_fields=("${(@s:|:)real_details}")
      local wrapper_type="${wrapper_fields[1]:-Unknown}"
      local wrapper_vendor="${wrapper_fields[2]-}"
      local wrapper_version="${wrapper_fields[3]:-Unknown}"
      local real_type="${real_fields[1]:-Unknown}"
      local real_vendor="${real_fields[2]-}"
      local real_version="${real_fields[3]:-Unknown}"
      local compiler_status="Available"
      local resolution="$cpath"

      if [[ "$cpath" == *"/ccache/"* || "$cpath" == *"ccache/bin"* ]]; then
        resolution="ccache: $cpath → $real_cpath"
      elif [[ "$cpath" != "$real_cpath" ]]; then
        resolution="$cpath → $real_cpath"
      fi

      if [[ ("$compiler" == "gcc" || "$compiler" == "g++") && "$real_type" == "Clang" ]]; then
        compiler_status="Warning: resolves to Clang"
      elif [[ ("$compiler" == "clang" || "$compiler" == "clang++") && "$real_type" == "GCC" ]]; then
        compiler_status="Warning: resolves to GCC"
      fi

      local toolchain="${real_vendor:+$real_vendor }$real_type"
      rows+=("$compiler"$'\t'"$compiler_status"$'\t'"$toolchain"$'\t'"$real_version"$'\t'"$resolution")
      available=$(( available + 1 ))
      if [[ "${TOOLCHAIN_INFO_DEBUG:-0}" != "0" ]]; then
        debug_rows+=(
          "$compiler"$'\t'"$wrapper_type"$'\t'"$wrapper_vendor"$'\t'"$wrapper_version"$'\t'"$real_cpath"
        )
      fi
    else
      rows+=("$compiler"$'\tMissing\t-\t-\tNot found in PATH')
      missing=$(( missing + 1 ))
    fi
  done

  print -r -- ""
  _zsh_ui_section "Compilers in PATH" || return 1
  _zsh_ui_table \
    $'Compiler\tStatus\tToolchain\tVersion\tResolution' \
    "${rows[@]}" || return 1

  if (( ${#debug_rows[@]} )); then
    print -r -- ""
    _zsh_ui_section "Debug details" || return 1
    _zsh_ui_table \
      $'Compiler\tWrapper type\tWrapper vendor\tWrapper version\tReal path' \
      "${debug_rows[@]}" || return 1
  fi

  print -r -- ""
  if (( missing )); then
    _zsh_ui_log warn "$available compiler(s) available; $missing missing."
  else
    _zsh_ui_log ok "$available compiler(s) available."
  fi
}

# ============================================================================ #
# End of toolchain-information.zsh
