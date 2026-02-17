#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ SHARED SHELL HELPERS +++++++++++++++++++++++++++ #
# ============================================================================ #
# Common utility functions shared across zsh scripts.
#
# Provides terminal color initialization, leveled logging, and interactive
# confirmation prompts. Designed to be sourced by other scripts in this
# directory to eliminate code duplication.
#
# Usage:
#   source "${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts/_shared_helpers.sh"
#
# Guard:
#   Idempotent -- re-sourcing is a no-op once loaded.
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

# Idempotent guard: skip if already loaded.
[[ -n "${_SHARED_HELPERS_LOADED:-}" ]] && return 0

# ++++++++++++++++++++++++++++++ COLOR HANDLING ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_init_colors
# -----------------------------------------------------------------------------
# Initializes terminal color codes for formatted output.
# Detects terminal capabilities and sets color variables. Falls back to
# empty strings if terminal doesn't support colors or output is not a tty.
#
# Usage:
#   _shared_init_colors
#
# Side Effects:
#   - Sets global color variables: C_RESET, C_BOLD, C_RED, C_GREEN,
#     C_YELLOW, C_BLUE, C_CYAN, C_MAGENTA.
# -----------------------------------------------------------------------------
_shared_init_colors() {
  # shellcheck disable=SC2034
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
    C_RESET=$'\e[0m'
    C_BOLD=$'\e[1m'
    C_RED=$'\e[31m'
    C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'
    C_MAGENTA=$'\e[35m'
    C_CYAN=$'\e[36m'
  else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
  fi
}

# ++++++++++++++++++++++++++++ LOGGING UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_log
# -----------------------------------------------------------------------------
# Formatted logging function with color-coded severity levels.
# Supports info, ok, warn, and error levels with appropriate colors.
#
# Usage:
#   _shared_log <level> <message...>
#
# Arguments:
#   level   - Log level: info, ok, warn, error (required).
#   message - Log message text, supports multiple arguments (required).
#
# Side Effects:
#   - Outputs to stdout for info/ok, stderr for warn/error.
# -----------------------------------------------------------------------------
_shared_log() {
  local level="$1"
  shift
  case "$level" in
    info)  printf "%s[INFO]%s  %s\n" "$C_CYAN" "$C_RESET" "$*" ;;
    ok)    printf "%s[OK]%s    %s\n" "$C_GREEN" "$C_RESET" "$*" ;;
    warn)  printf "%s[WARN]%s  %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2 ;;
    error) printf "%s[ERROR]%s %s\n" "$C_RED" "$C_RESET" "$*" >&2 ;;
  esac
}

# +++++++++++++++++++++++++++++ PLATFORM HELPERS ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _shared_detect_platform
# -----------------------------------------------------------------------------
# Detects the current operating system and optional Linux distribution.
# Results are cached in SHARED_PLATFORM and SHARED_DISTRO globals.
#
# Usage:
#   _shared_detect_platform
#
# Side Effects:
#   - Sets SHARED_PLATFORM global variable.
#   - Sets SHARED_DISTRO global variable for Linux when available.
# -----------------------------------------------------------------------------
_shared_detect_platform() {
  if [[ -n "${SHARED_PLATFORM:-}" ]]; then
    return 0
  fi

  local os
  os=$(uname -s 2>/dev/null || printf "unknown")

  case "$os" in
    Darwin) SHARED_PLATFORM="macOS" ;;
    Linux) SHARED_PLATFORM="Linux" ;;
    *) SHARED_PLATFORM="$os" ;;
  esac

  SHARED_DISTRO=""
  if [[ "$SHARED_PLATFORM" == "Linux" ]]; then
    if [[ -f "/etc/arch-release" ]]; then
      SHARED_DISTRO="Arch"
    elif command -v lsb_release >/dev/null 2>&1; then
      SHARED_DISTRO=$(lsb_release -si 2>/dev/null || printf "")
    fi
  fi
}

# -----------------------------------------------------------------------------
# _shared_platform_pretty
# -----------------------------------------------------------------------------
# Returns human-readable platform string.
#
# Usage:
#   platform=$(_shared_platform_pretty)
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
# -----------------------------------------------------------------------------
# Validates boolean-like values.
#
# Usage:
#   _shared_is_bool <value>
#
# Returns:
#   0 - Value is "true" or "false".
#   1 - Value is invalid.
# -----------------------------------------------------------------------------
_shared_is_bool() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

# -----------------------------------------------------------------------------
# _shared_has_command
# -----------------------------------------------------------------------------
# Checks whether a command exists in PATH.
#
# Usage:
#   _shared_has_command <command>
#
# Returns:
#   0 - Command exists.
#   1 - Command missing.
# -----------------------------------------------------------------------------
_shared_has_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# _shared_require_command
# -----------------------------------------------------------------------------
# Ensures a required command exists in PATH.
#
# Usage:
#   _shared_require_command <command> [error_message]
#
# Returns:
#   0 - Command exists.
#   1 - Command missing (logs error).
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
# -----------------------------------------------------------------------------
# Prompts user for confirmation with a default of "no" for safety.
# Only accepts explicit y/yes to proceed.
#
# Usage:
#   _shared_confirm "Are you sure?"
#
# Arguments:
#   prompt - Question text to display (optional, default: "Continue?").
#
# Returns:
#   0 - User confirmed (y/yes).
#   1 - User declined or pressed enter.
#
# Side Effects:
#   - Reads from stdin.
# -----------------------------------------------------------------------------
_shared_confirm() {
  local prompt="${1:-Continue?}"
  local reply
  if [[ ! -t 0 ]]; then
    _shared_log error "Cannot prompt: stdin is not a terminal."
    return 1
  fi
  printf "%s%s [y/N]: %s" "$C_YELLOW" "$prompt" "$C_RESET"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

_SHARED_HELPERS_LOADED=1

# ============================================================================ #
# End of script.
