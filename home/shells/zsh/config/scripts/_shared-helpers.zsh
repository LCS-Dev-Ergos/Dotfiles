#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ SHARED SHELL HELPERS +++++++++++++++++++++++++++ #
# ============================================================================ #
# Common utility functions shared across zsh scripts.
#
# Provides the shared terminal style, color initialization,
# leveled logging, platform detection and interactive confirmation. Designed
# to be sourced by other scripts in this directory to eliminate code
# duplication.
#
# Usage:
#   source "${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts/_shared-helpers.zsh"
#
# Guard:
#   Re-sourcing is supported so real implementations can replace lazy stubs.
#
# Author: LCS-Dev-Ergos
# License: MIT
# ============================================================================ #

# Re-sourcing is intentionally allowed so real helper implementations can
# replace stale lazy-loader stubs after a shell reload.

_shared_runtime_helpers="${${(%):-%N}:A:h:h}/runtime-helpers.zsh"
if [[ -r "$_shared_runtime_helpers" ]]; then
  # shellcheck disable=SC1090
  source "$_shared_runtime_helpers"
else
  printf "[ERROR] Runtime helpers not found: %s\n" \
    "$_shared_runtime_helpers" >&2
  return 1 2>/dev/null || exit 1
fi
unset _shared_runtime_helpers

# The shared look lives in home/shells/terminal-style. The deployed
# configuration carries a copy next to this file; a repository checkout
# reads the module itself.
_shared_ui_dir="${${(%):-%N}:A:h}"
for _shared_ui in \
  "$_shared_ui_dir/_terminal-style.zsh" \
  "${_shared_ui_dir:h:h:h}/terminal-style/terminal-style.zsh"; do
  [[ -r "$_shared_ui" ]] && break
done
if [[ -r "$_shared_ui" ]]; then
  # shellcheck disable=SC1090
  source "$_shared_ui"
else
  printf "[ERROR] Terminal style not found next to %s\n" "$_shared_ui_dir" >&2
  unset _shared_ui _shared_ui_dir
  return 1 2>/dev/null || exit 1
fi
unset _shared_ui _shared_ui_dir

# ++++++++++++++++++++++++++++++ COLOR HANDLING ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_init_colors
# @internal
# @description Sets C_* color variables, empty when output is not a tty.
# @noargs
# -----------------------------------------------------------------------------
_shared_init_colors() {
  _zsh_init_colors
  if [[ -n "${NO_COLOR-}" ]]; then
    C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW=""
    C_BLUE="" C_MAGENTA="" C_CYAN=""
  fi
}

# ++++++++++++++++++++++++++++ LOGGING UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_log
# @internal
# @description Prints a leveled, color-coded log line; warn/error go to stderr.
# @arg $1 string Level: info, ok, warn, or error.
# @arg $@ string Message text.
# -----------------------------------------------------------------------------
_shared_log() {
  _zsh_ui_log "$@"
}

# -----------------------------------------------------------------------------
# _shared_rule
# @internal
# @description Prints a horizontal rule sized to the terminal width.
# @arg $1 string Optional rule character; defaults to "-".
# -----------------------------------------------------------------------------
_shared_rule() {
  _zsh_ui_rule "$@"
}

# -----------------------------------------------------------------------------
# _shared_banner
# @internal
# @description Prints the shared title banner followed by a blank line.
# @arg $1 string Title text.
# @arg $2 string Optional subtitle text.
# -----------------------------------------------------------------------------
_shared_banner() {
  _zsh_ui_heading "$1" "${2:-}" || return $?
  print -r -- ""
}

# -----------------------------------------------------------------------------
# _shared_section
# @internal
# @description Prints a section label.
# @arg $1 string Section title.
# -----------------------------------------------------------------------------
_shared_section() {
  _zsh_ui_section "$1"
}

# +++++++++++++++++++++++++++++ PLATFORM HELPERS ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_detect_platform
# @internal
# @description Detects the OS and Linux distribution; idempotent once cached.
# @noargs
# @set SHARED_PLATFORM string Detected platform: macOS, Linux, or Other.
# @set SHARED_DISTRO string Linux distro name (e.g. Arch); empty elsewhere.
# -----------------------------------------------------------------------------
_shared_detect_platform() {
  if [[ -n "${SHARED_PLATFORM:-}" ]]; then
    return 0
  fi

  if [[ -n "${PLATFORM:-}" ]]; then
    SHARED_PLATFORM="$PLATFORM"
  else
    _zsh_detect_platform
    SHARED_PLATFORM="$PLATFORM"
  fi

  SHARED_DISTRO=""
  if [[ "$SHARED_PLATFORM" == "Linux" ]]; then
    if [[ "${ARCH_LINUX:-false}" == true || -f "/etc/arch-release" ]]; then
      SHARED_DISTRO="Arch"
    elif command -v lsb_release >/dev/null 2>&1; then
      SHARED_DISTRO=$(lsb_release -si 2>/dev/null || printf "")
    fi
  fi
}

# -----------------------------------------------------------------------------
# _shared_platform_pretty
# @internal
# @description Prints a human-readable platform string, e.g. "Linux (Arch)".
# @noargs
# @stdout The platform string.
# -----------------------------------------------------------------------------
_shared_platform_pretty() {
  _shared_detect_platform
  if [[ "${SHARED_PLATFORM:-}" == "Linux" && -n "${SHARED_DISTRO:-}" ]]; then
    printf "Linux (%s)\n" "$SHARED_DISTRO"
  else
    printf "%s\n" "${SHARED_PLATFORM:-unknown}"
  fi
}

# ++++++++++++++++++++++++++++ VALIDATION HELPERS +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_is_bool
# @internal
# @description Checks whether a value is the literal string "true" or "false".
# @arg $1 string Value to validate.
# @exitcode 1 If the value is neither "true" nor "false".
# -----------------------------------------------------------------------------
_shared_is_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

# -----------------------------------------------------------------------------
# _shared_has_command
# @internal
# @description Checks whether a command exists in PATH.
# @arg $1 string Command name.
# @exitcode 1 If the command is not found.
# -----------------------------------------------------------------------------
_shared_has_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# _shared_require_command
# @internal
# @description Logs an error and fails if a required command is missing.
# @arg $1 string Command name.
# @arg $2 string Optional error message override.
# @exitcode 1 If the command is not found.
# -----------------------------------------------------------------------------
_shared_require_command() {
  local cmd="$1"
  local message="${2:-Required command not found: $cmd}"

  if _shared_has_command "$cmd"; then
    return 0
  fi

  _shared_log error "$message"
  return 1
}

# +++++++++++++++++++++++++++ INTERACTIVE PROMPTS ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_confirm
# @internal
# @description Prompts for y/N confirmation, defaulting to "no" for safety;
# fails immediately if stdin is not a terminal.
# @arg $1 string Optional prompt text; defaults to "Continue?".
# @exitcode 1 If the user declines, or stdin is not a terminal.
# -----------------------------------------------------------------------------
_shared_confirm() {
  _zsh_ui_confirm "$@"
}

_SHARED_HELPERS_LOADED=1

# ============================================================================ #
# End of _shared-helpers.zsh
