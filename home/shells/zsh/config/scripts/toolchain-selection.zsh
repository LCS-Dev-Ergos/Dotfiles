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
#  - CC and CXX set to absolute compiler paths
#  - PATH edited in place: only a directory the switch itself added is
#    removed again, so later PATH changes survive every switch
#  - Cross-platform compatibility (macOS Darwin, Linux)
#  - Color-coded logging and status messages
#
# Usage:
#   use_llvm    # Activate LLVM/Clang toolchain
#   use_gnu     # Activate GNU GCC toolchain
#   use_system  # Return to the environment before the first switch
#
# Environment Variables (restored by use_system):
#   CC, CXX, CPATH, LDFLAGS, CPPFLAGS, PKG_CONFIG_PATH
#
# Author: LCS-Dev-Ergos
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

# Nothing is snapshotted when this file loads. A copy of PATH or CC taken here
# goes stale the moment the shell changes either, and exporting it would hand
# the parent's copy to every child shell. The baseline below is captured when
# the shell first leaves the system toolchain instead.

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
# _toolchain_save_baseline
# @internal
# @description Commits the pre-switch values after a successful activation.
# Switching between LLVM and GNU keeps the first baseline.
# @arg $1 string Previous LDFLAGS or the unset sentinel.
# @arg $2 string Previous CPPFLAGS or the unset sentinel.
# @arg $3 string Previous CPATH or the unset sentinel.
# @arg $4 string Previous PKG_CONFIG_PATH or the unset sentinel.
# @arg $5 string Previous CC or the unset sentinel.
# @arg $6 string Previous CXX or the unset sentinel.
# @set TOOLCHAIN_BASELINE_* string Saved values, or the unset sentinel.
# -----------------------------------------------------------------------------
_toolchain_save_baseline() {
  (( $# == 6 )) || return 2
  [[ -z "${TOOLCHAIN_ACTIVE:-}" || "$TOOLCHAIN_ACTIVE" == system ]] || return 0
  typeset -g TOOLCHAIN_BASELINE_LDFLAGS="$1"
  typeset -g TOOLCHAIN_BASELINE_CPPFLAGS="$2"
  typeset -g TOOLCHAIN_BASELINE_CPATH="$3"
  typeset -g TOOLCHAIN_BASELINE_PKG_CONFIG_PATH="$4"
  typeset -g TOOLCHAIN_BASELINE_CC="$5"
  typeset -g TOOLCHAIN_BASELINE_CXX="$6"
}

# -----------------------------------------------------------------------------
# _toolchain_restore_baseline
# @internal
# @description Restores the variables saved by _toolchain_save_baseline, if a
# switch ever saved them; otherwise leaves the environment as it is.
# @noargs
# -----------------------------------------------------------------------------
_toolchain_restore_baseline() {
  (( ${+TOOLCHAIN_BASELINE_CC} )) || return 0
  _toolchain_restore_var LDFLAGS "$TOOLCHAIN_BASELINE_LDFLAGS"
  _toolchain_restore_var CPPFLAGS "$TOOLCHAIN_BASELINE_CPPFLAGS"
  _toolchain_restore_var CPATH "$TOOLCHAIN_BASELINE_CPATH"
  _toolchain_restore_var PKG_CONFIG_PATH "$TOOLCHAIN_BASELINE_PKG_CONFIG_PATH"
  _toolchain_restore_var CC "$TOOLCHAIN_BASELINE_CC"
  _toolchain_restore_var CXX "$TOOLCHAIN_BASELINE_CXX"
}

# -----------------------------------------------------------------------------
# _toolchain_set_path
# @internal
# @description Edits the current PATH in place. The directory a previous
# switch prepended is removed, then the new one is prepended only when PATH
# does not already contain it: moving a directory such as the Nix profile to
# the front would also let its node or python shadow the version managers'.
# @arg $1 path Toolchain binary directory; empty to only undo the last one.
# @set TOOLCHAIN_ACTIVE_BIN string The directory this call prepended, or empty.
# -----------------------------------------------------------------------------
_toolchain_set_path() {
  local bin_dir="$1"
  if [[ -n "${TOOLCHAIN_ACTIVE_BIN:-}" ]]; then
    path=("${(@)path:#${(b)TOOLCHAIN_ACTIVE_BIN}}")
  fi
  TOOLCHAIN_ACTIVE_BIN=""
  if [[ -n "$bin_dir" && -z "${path[(r)${(b)bin_dir}]}" ]]; then
    path=("$bin_dir" "${path[@]}")
    TOOLCHAIN_ACTIVE_BIN="$bin_dir"
  fi
  export PATH
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
      # names that way. Only base-<number> counts: gcc-ar-16 also ends in a
      # number, but it is GCC's archiver, not version 16 of gcc.
      for candidate_path in "$dir/$base"-*(N); do
        [[ -x "$candidate_path" ]] || continue
        ver_str="${${candidate_path:t}#${base}-}"
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
# _toolchain_is_gnu_compiler
# @internal
# @description Tells a real GNU compiler from Apple's Clang, which answers to
# the gcc and g++ names as well.
# @arg $1 path Compiler to inspect.
# @exitcode 1 If the compiler does not identify itself as GNU.
# -----------------------------------------------------------------------------
_toolchain_is_gnu_compiler() {
  local banner
  banner="$("$1" --version 2>/dev/null)" || return 1
  [[ "$banner" == *"Free Software Foundation"* ]]
}

# -----------------------------------------------------------------------------
# _toolchain_select_gcc_bin_dir
# @internal
# @description Locates the GCC bin directory. On macOS that is the first GNU
# gcc on PATH -- the Nix host driver, which is the source of truth -- with
# Homebrew's keg only as a fallback; on Linux, /usr/bin or /usr/local/bin.
# @noargs
# @exitcode 1 If no GCC installation is found.
# @stdout The GCC bin directory path, on success.
# -----------------------------------------------------------------------------
_toolchain_select_gcc_bin_dir() {
  if [[ "$TOOLCHAIN_OS" == "macOS" ]]; then
    local candidate
    for candidate in ${(f)"$(whence -ap gcc 2>/dev/null)"}; do
      if _toolchain_is_gnu_compiler "$candidate"; then
        printf "%s\n" "${candidate:h}"
        return 0
      fi
    done

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
# @description Verifies that CC and CXX name exactly the compilers that were
# selected, guarding against a stale hash or a selection that went wrong.
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

# -----------------------------------------------------------------------------
# _toolchain_activate
# @internal
# @description Makes a selected compiler pair the shell's CC and CXX, rolling
# every change back if the pair does not resolve or does not run.
# @arg $1 string Toolchain name recorded in TOOLCHAIN_ACTIVE.
# @arg $2 path Selected C compiler.
# @arg $3 path Selected C++ compiler.
# @exitcode 1 If the selected compilers fail validation.
# -----------------------------------------------------------------------------
_toolchain_activate() {
  local toolchain="$1" c_compiler="$2" cxx_compiler="$3"

  _toolchain_capture_state
  local -a previous_state=("${reply[@]}")
  # Returning from a selected toolchain uses its saved environment. Leaving
  # the system uses the current environment, committed only after validation.
  if [[ -n "${TOOLCHAIN_ACTIVE:-}" && "$TOOLCHAIN_ACTIVE" != system ]]; then
    _toolchain_restore_baseline
  fi

  # Absolute paths: CC keeps naming the selected compiler whatever PATH does
  # afterwards, so PATH only needs the directory when it lacks it entirely.
  _toolchain_set_path "${c_compiler:h}"
  export CC="$c_compiler"
  export CXX="$cxx_compiler"

  _toolchain_validate_resolution "$c_compiler" "$cxx_compiler" || {
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
  _toolchain_save_baseline "${previous_state[@]:3}"
  TOOLCHAIN_ACTIVE="$toolchain"
}

# +++++++++++++++++++++++++ MAIN TOOLCHAIN FUNCTIONS +++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# use_llvm
# @description Activates the best available LLVM/Clang toolchain.
# Sets CC and CXX to its compilers for the current shell.
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

  _toolchain_activate llvm "$clang_bin" "$cxx_bin" || return 1
  _toolchain_log ok "LLVM/Clang is active for this shell."
}

# -----------------------------------------------------------------------------
# use_gnu
# @description Activates the best available GNU GCC toolchain.
# Sets CC and CXX to its compilers, then reports compiler versions.
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

  _toolchain_activate gnu "$gcc_bin" "$gxx_bin" || return 1
  _toolchain_log ok "GNU GCC is active for this shell."
}

# -----------------------------------------------------------------------------
# use_system
# @description Returns CC, CXX, and the compiler flags to their values before
# the first switch, and removes the directory a switch added to PATH. Reports
# the system C and C++ compilers afterwards.
# @noargs
# -----------------------------------------------------------------------------
use_system() {
  _toolchain_init_colors
  _zsh_ui_heading "System toolchain" "Restoring the environment before the first switch"

  _toolchain_set_path ""
  _toolchain_restore_baseline

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
