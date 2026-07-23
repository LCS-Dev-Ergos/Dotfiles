#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++ CROSS-PLATFORM TOOLCHAIN SWITCHER +++++++++++++++++++++ #
# ============================================================================ #
# Advanced compiler toolchain management for macOS and Linux development.
#
# This script provides intelligent switching between LLVM/Clang and GNU GCC
# toolchains with automatic detection of installation paths from:
#  - Homebrew installations (macOS: /opt/homebrew, /usr/local)
#  - System package managers (Arch Linux, Ubuntu, Debian)
#  - Custom LLVM installations (/usr/lib/llvm*, /opt/llvm*)
#
# Features:
#  - Automatic version selection (prefers highest versioned binary)
#  - Safe environment preservation and restoration
#  - PATH manipulation with original state backup
#  - Compiler flags configuration (LDFLAGS, CPPFLAGS)
#  - Cross-platform compatibility (macOS Darwin, Linux)
#  - Color-coded logging and status messages
#
# Usage:
#   use_llvm    # Activate LLVM/Clang toolchain
#   use_gnu     # Activate GNU GCC toolchain
#   use_system  # Restore original system environment
#
# Environment Variables (preserved):
#   CC, CXX, CPATH, LDFLAGS, CPPFLAGS, PKG_CONFIG_PATH, PATH
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

# ++++++++++++++++++++++++++ SHARED HELPERS LOADER +++++++++++++++++++++++++++ #

# shellcheck disable=SC2034

_toolchain_helpers_dir="${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts"
if [[ -r "${_toolchain_helpers_dir}/_shared-helpers.zsh" ]]; then
  # shellcheck disable=SC1091
  source "${_toolchain_helpers_dir}/_shared-helpers.zsh"
else
  printf "[ERROR] Shared helpers not found: %s/_shared-helpers.zsh\n" "$_toolchain_helpers_dir" >&2
  return 1 2>/dev/null || exit 1
fi
unset _toolchain_helpers_dir

# ++++++++++++++++++++++++++++++ COLOR HANDLING ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_init_colors
# @internal
# @description Sets C_* color variables for toolchain switcher output.
# @noargs
# -----------------------------------------------------------------------------
_toolchain_init_colors() {
  _shared_init_colors
}

# ++++++++++++++++++++++++++++++ PLATFORM PROBE ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_detect_platform
# @internal
# @description Detects the OS and Linux distribution; idempotent once cached.
# @noargs
# @set TOOLCHAIN_OS string Detected platform: macOS, Linux, or Other.
# @set TOOLCHAIN_DISTRO string "Arch" on Arch Linux, empty otherwise.
# -----------------------------------------------------------------------------
_toolchain_detect_platform() {
  if [[ -n "${TOOLCHAIN_OS:-}" ]]; then
    return 0
  fi

  _shared_detect_platform
  TOOLCHAIN_OS="${SHARED_PLATFORM:-Other}"
  TOOLCHAIN_DISTRO=""
  if [[ "$TOOLCHAIN_OS" == "Linux" && "${SHARED_DISTRO:-}" == "Arch" ]]; then
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
  TOOLCHAIN_ORIGINAL_CPATH="${CPATH-__TOOLCHAIN_UNSET__}"
  TOOLCHAIN_ORIGINAL_PKG_CONFIG_PATH="${PKG_CONFIG_PATH-__TOOLCHAIN_UNSET__}"
  TOOLCHAIN_ORIGINAL_CC="${CC-__TOOLCHAIN_UNSET__}"
  TOOLCHAIN_ORIGINAL_CXX="${CXX-__TOOLCHAIN_UNSET__}"
fi

# +++++++++++++++++++++++++++++++ LOG HELPERS ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _toolchain_log
# @internal
# @description Prints a leveled, color-coded log line; warn/error go to stderr.
# @arg $1 string Level: info, ok, warn, or error.
# @arg $@ string Message text.
# -----------------------------------------------------------------------------
_toolchain_log() {
  _shared_log "$@"
}

# -----------------------------------------------------------------------------
# _toolchain_restore_var
# @internal
# @description Restores an environment variable to its pre-switch state.
# @arg $1 string Environment variable name.
# @arg $2 string Original value, or the "__TOOLCHAIN_UNSET__" sentinel.
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
# @internal
# @description Restores LDFLAGS, CPPFLAGS, CPATH, PKG_CONFIG_PATH, CC, and CXX
# to the values captured before any toolchain switch.
# @noargs
# -----------------------------------------------------------------------------
_toolchain_reset_env_to_original() {
  _toolchain_restore_var LDFLAGS "$TOOLCHAIN_ORIGINAL_LDFLAGS"
  _toolchain_restore_var CPPFLAGS "$TOOLCHAIN_ORIGINAL_CPPFLAGS"
  _toolchain_restore_var CPATH "$TOOLCHAIN_ORIGINAL_CPATH"
  _toolchain_restore_var PKG_CONFIG_PATH "$TOOLCHAIN_ORIGINAL_PKG_CONFIG_PATH"
  _toolchain_restore_var CC "$TOOLCHAIN_ORIGINAL_CC"
  _toolchain_restore_var CXX "$TOOLCHAIN_ORIGINAL_CXX"
}

# -----------------------------------------------------------------------------
# _toolchain_set_path
# @internal
# @description Prepends a toolchain binary directory to the original PATH, or
# restores the original PATH when called with an empty argument.
# @arg $1 path Toolchain binary directory; empty to restore.
# @set TOOLCHAIN_ACTIVE_BIN string The prepended directory, or empty.
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
# @internal
# @description Resolves the Homebrew prefix from HOMEBREW_PREFIX, `brew
# --prefix`, or common install paths, in that order.
# @noargs
# @exitcode 1 If no Homebrew installation is found.
# @stdout The Homebrew prefix path, on success.
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
# @internal
# @description Searches preferred directories before PATH for the highest
# versioned binary matching base_name-N (e.g. gcc-15), falling back to an
# unversioned match within the same priority tier.
# @arg $1 string Base binary name (e.g. "gcc", "clang").
# @arg $@ path Additional directories to search.
# @stdout The resolved binary path, on success.
# -----------------------------------------------------------------------------
_toolchain_find_best_binary() {
  local base="$1"
  shift
  local fallback="" best="" dir candidate_path ver ver_str group
  local -i best_ver=-1

  local -a preferred_dirs=() path_dirs=("${path[@]}") dirs=()
  for dir in "$@"; do
    [[ -n "$dir" ]] && preferred_dirs+=("$dir")
  done

  # Explicitly selected installations are a higher-priority tier than PATH.
  # This prevents a lower-priority compiler from winning after a toolchain was
  # selected explicitly.
  for group in preferred path; do
    if [[ "$group" == preferred ]]; then
      dirs=("${preferred_dirs[@]}")
      (( ${#dirs[@]} )) || continue
    else
      dirs=("${path_dirs[@]}")
    fi
    typeset -U dirs
    fallback=""
    best=""
    best_ver=-1

    for dir in "${dirs[@]}"; do
      [[ -d "$dir" ]] || continue
      if [[ -x "$dir/$base" && -z "$fallback" ]]; then
        fallback="$dir/$base"
      fi

      # Include executable symlinks: Homebrew commonly exposes versioned GCC
      # names that way.
      for candidate_path in "$dir/$base"-*(N); do
        [[ -x "$candidate_path" ]] || continue
        ver_str="${candidate_path##*-}"
        [[ "$ver_str" == <-> ]] || continue
        ver=$ver_str
        if (( ver > best_ver )); then
          best_ver=$ver
          best="$candidate_path"
        fi
      done
    done

    if [[ -n "$best" ]]; then
      print -r -- "$best"
      return 0
    elif [[ -n "$fallback" ]]; then
      print -r -- "$fallback"
      return 0
    fi
  done

  return 1
}

# -----------------------------------------------------------------------------
# _toolchain_select_llvm_bin_dir
# @internal
# @description Locates the active Nix LLVM/Clang directory from PATH on macOS,
# or the highest-versioned conventional LLVM directory on Linux.
# @noargs
# @stdout The LLVM bin directory path, on success.
# -----------------------------------------------------------------------------
_toolchain_select_llvm_bin_dir() {
  local -a candidates=()

  if [[ "$TOOLCHAIN_OS" == "macOS" ]]; then
    local clang_bin
    clang_bin=$(_toolchain_find_best_binary clang) || return 1
    dirname "$clang_bin"
    return
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
# @internal
# @description Locates the GCC bin directory: Homebrew GCC on macOS, or
# /usr/bin / /usr/local/bin on Linux.
# @noargs
# @exitcode 1 If no GCC installation is found.
# @stdout The GCC bin directory path, on success.
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
# @internal
# @description Runs the compiler with --version and logs the result.
# @arg $1 string Compiler binary name or path.
# @exitcode 1 If the compiler is not found or does not run.
# -----------------------------------------------------------------------------
_toolchain_verify_compiler() {
  local compiler="$1"
  local label="${2:-Compiler}"
  local resolved
  resolved="$(command -v "$compiler" 2>/dev/null)"
  if [[ -n "$resolved" ]]; then
    local version_output
    version_output=$("$resolved" --version 2>/dev/null | head -n 1)
    if [[ -n "$version_output" ]]; then
      _toolchain_log ok "${label}: ${resolved:t} · ${version_output}"
      return 0
    fi
  fi
  _toolchain_log warn \
    "${label} compiler '${compiler}' is unavailable or unusable."
  return 1
}

# -----------------------------------------------------------------------------
# _toolchain_validate_resolution
# @internal
# @description Verifies that CC and CXX resolve to the compiler paths selected
# before PATH was updated, guarding against stale hashes and wrong precedence.
# @arg $1 path Expected C compiler.
# @arg $2 path Expected C++ compiler.
# @exitcode 1 If either selected compiler resolves elsewhere.
# -----------------------------------------------------------------------------
_toolchain_validate_resolution() {
  local expected_cc="$1" expected_cxx="$2"
  local resolved_cc resolved_cxx
  rehash
  resolved_cc="$(command -v "$CC" 2>/dev/null)"
  resolved_cxx="$(command -v "$CXX" 2>/dev/null)"

  if [[ -z "$resolved_cc" || "${resolved_cc:A}" != "${expected_cc:A}" ]]; then
    _toolchain_log error \
      "CC resolves to '${resolved_cc:-missing}', expected '$expected_cc'."
    return 1
  fi
  if [[ -z "$resolved_cxx" ||
        "${resolved_cxx:A}" != "${expected_cxx:A}" ]]; then
    _toolchain_log error \
      "CXX resolves to '${resolved_cxx:-missing}', expected '$expected_cxx'."
    return 1
  fi
}

# -----------------------------------------------------------------------------
# _toolchain_capture_state
# @internal
# @description Stores the current toolchain environment in reply for rollback.
# @noargs
# @set reply array Current PATH, state markers, and compiler variables.
# -----------------------------------------------------------------------------
_toolchain_capture_state() {
  reply=(
    "$PATH"
    "${TOOLCHAIN_ACTIVE-__TOOLCHAIN_UNSET__}"
    "${TOOLCHAIN_ACTIVE_BIN-__TOOLCHAIN_UNSET__}"
    "${LDFLAGS-__TOOLCHAIN_UNSET__}"
    "${CPPFLAGS-__TOOLCHAIN_UNSET__}"
    "${CPATH-__TOOLCHAIN_UNSET__}"
    "${PKG_CONFIG_PATH-__TOOLCHAIN_UNSET__}"
    "${CC-__TOOLCHAIN_UNSET__}"
    "${CXX-__TOOLCHAIN_UNSET__}"
  )
}

# -----------------------------------------------------------------------------
# _toolchain_restore_state
# @internal
# @description Restores a state captured by _toolchain_capture_state.
# @arg $@ string Nine state fields returned in reply.
# -----------------------------------------------------------------------------
_toolchain_restore_state() {
  (( $# == 9 )) || return 2
  export PATH="$1"
  if [[ "$2" == "__TOOLCHAIN_UNSET__" ]]; then
    unset TOOLCHAIN_ACTIVE
  else
    TOOLCHAIN_ACTIVE="$2"
  fi
  if [[ "$3" == "__TOOLCHAIN_UNSET__" ]]; then
    unset TOOLCHAIN_ACTIVE_BIN
  else
    TOOLCHAIN_ACTIVE_BIN="$3"
  fi
  _toolchain_restore_var LDFLAGS "$4"
  _toolchain_restore_var CPPFLAGS "$5"
  _toolchain_restore_var CPATH "$6"
  _toolchain_restore_var PKG_CONFIG_PATH "$7"
  _toolchain_restore_var CC "$8"
  _toolchain_restore_var CXX "$9"
  rehash
}

# +++++++++++++++++++++++++ MAIN TOOLCHAIN FUNCTIONS +++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# use_llvm
# @description Activates the best available LLVM/Clang toolchain.
# Updates compiler variables and PATH.
# @noargs
# @exitcode 1 If an LLVM toolchain is unavailable.
# -----------------------------------------------------------------------------
use_llvm() {
  _toolchain_init_colors
  _toolchain_detect_platform
  _zsh_ui_heading "LLVM/Clang toolchain" "Activating for the current shell"

  local llvm_bin_dir clang_bin cxx_bin
  llvm_bin_dir=$(_toolchain_select_llvm_bin_dir) || true

  clang_bin=$(_toolchain_find_best_binary "clang" "$llvm_bin_dir") || true
  cxx_bin=$(_toolchain_find_best_binary "clang++" "$llvm_bin_dir") || true

  if [[ -z "$clang_bin" || -z "$cxx_bin" ]]; then
    _toolchain_log error \
      "No Clang toolchain found; install LLVM with the platform package manager."
    return 1
  fi

  _toolchain_capture_state
  local -a previous_state=("${reply[@]}")
  _toolchain_reset_env_to_original

  local bin_dir_for_path
  bin_dir_for_path="$(dirname "$clang_bin")"
  _toolchain_set_path "$bin_dir_for_path"

  export CC
  export CXX
  CC=$(basename "$clang_bin")
  CXX=$(basename "$cxx_bin")

  _toolchain_validate_resolution "$clang_bin" "$cxx_bin" || {
    _toolchain_restore_state "${previous_state[@]}"
    return 1
  }
  local -i verify_status=0
  _toolchain_verify_compiler "$CC" "C" || verify_status=1
  _toolchain_verify_compiler "$CXX" "C++" || verify_status=1
  if (( verify_status != 0 )); then
    _toolchain_restore_state "${previous_state[@]}"
    return 1
  fi
  TOOLCHAIN_ACTIVE="llvm"
  _toolchain_log ok "LLVM/Clang is active for this shell."
}

# -----------------------------------------------------------------------------
# use_gnu
# @description Activates the best available GNU GCC toolchain.
# Updates compiler variables and PATH, then reports compiler versions.
# @noargs
# @exitcode 1 If a GCC toolchain is unavailable.
# -----------------------------------------------------------------------------
use_gnu() {
  _toolchain_init_colors
  _toolchain_detect_platform
  _zsh_ui_heading "GNU GCC toolchain" "Activating for the current shell"

  local gcc_bin_dir gcc_bin gxx_bin
  gcc_bin_dir=$(_toolchain_select_gcc_bin_dir) || true

  gcc_bin=$(_toolchain_find_best_binary "gcc" "$gcc_bin_dir") || true
  gxx_bin=$(_toolchain_find_best_binary "g++" "$gcc_bin_dir") || true

  if [[ -z "$gcc_bin" || -z "$gxx_bin" ]]; then
    _toolchain_log error \
      "GCC not found; install it with the platform package manager."
    return 1
  fi

  _toolchain_capture_state
  local -a previous_state=("${reply[@]}")
  _toolchain_reset_env_to_original

  local bin_dir_for_path
  bin_dir_for_path="$(dirname "$gcc_bin")"
  _toolchain_set_path "$bin_dir_for_path"

  export CC
  export CXX
  CC=$(basename "$gcc_bin")
  CXX=$(basename "$gxx_bin")

  _toolchain_validate_resolution "$gcc_bin" "$gxx_bin" || {
    _toolchain_restore_state "${previous_state[@]}"
    return 1
  }
  local -i verify_status=0
  _toolchain_verify_compiler "$CC" "C" || verify_status=1
  _toolchain_verify_compiler "$CXX" "C++" || verify_status=1
  if (( verify_status != 0 )); then
    _toolchain_restore_state "${previous_state[@]}"
    return 1
  fi
  TOOLCHAIN_ACTIVE="gnu"
  _toolchain_log ok "GNU GCC is active for this shell."
}

# -----------------------------------------------------------------------------
# use_system
# @description Restores PATH and compiler variables saved before switching.
# Reports the system C and C++ compilers after restoration.
# @noargs
# @exitcode 1 If the original PATH is unavailable.
# -----------------------------------------------------------------------------
use_system() {
  _toolchain_init_colors
  _zsh_ui_heading "System toolchain" "Restoring the original shell environment"

  if [[ -z "${TOOLCHAIN_ORIGINAL_PATH:-}" ]]; then
    _toolchain_log error \
      "TOOLCHAIN_ORIGINAL_PATH is unset; restart the shell to recover."
    return 1
  fi

  _toolchain_set_path ""
  _toolchain_reset_env_to_original

  local system_cc="${CC:-cc}" system_cxx="${CXX:-c++}"

  if command -v "$system_cc" >/dev/null 2>&1; then
    _toolchain_verify_compiler "$system_cc" "C"
  else
    _toolchain_log warn "No system C compiler detected in PATH."
  fi

  if command -v "$system_cxx" >/dev/null 2>&1; then
    _toolchain_verify_compiler "$system_cxx" "C++"
  else
    _toolchain_log warn "No system C++ compiler detected in PATH."
  fi

  TOOLCHAIN_ACTIVE="system"
  _toolchain_log ok "System toolchain restored."
}

# ============================================================================ #
# End of toolchain-selection.zsh
