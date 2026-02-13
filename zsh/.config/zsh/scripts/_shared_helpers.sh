#!/usr/bin/env bash
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ Shared Shell Helpers +++++++++++++++++++++++++++ #
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
_SHARED_HELPERS_LOADED=1

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
  printf "%s%s [y/N]: %s" "$C_YELLOW" "$prompt" "$C_RESET"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================================ #
# End of script.
