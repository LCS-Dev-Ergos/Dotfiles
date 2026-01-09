#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ CORE FUNCTIONS ++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Essential utility functions for daily shell workflow.
# These are fundamental building blocks used frequently.
#
# Functions:
#   - up        Navigate up N directories.
#   - mkcd      Create directory and cd into it.
#   - bak       Create timestamped backup of a file.
#   - epoch     Display current Unix timestamp.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# up
# -----------------------------------------------------------------------------
# Navigate up N directories in the filesystem hierarchy.
#
# Usage:
#   up [n]
#
# Arguments:
#   n - Number of directories to go up (default: 1)
# -----------------------------------------------------------------------------
function up() {
  local d=""
  local limit="${1:-1}"

  if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
    echo "${C_RED}Error: Argument must be a positive integer.${C_RESET}" >&2
    return 1
  fi

  for ((i = 1; i <= limit; i++)); do
    d="../$d"
  done

  if ! cd "$d"; then
    echo "${C_RED}Error: Cannot go up $limit directories.${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# mkcd
# -----------------------------------------------------------------------------
# Create a directory (including parents) and change into it.
#
# Usage:
#   mkcd <directory>
# -----------------------------------------------------------------------------
function mkcd() {
  if [[ -z "$1" ]]; then
    echo "${C_YELLOW}Usage: mkcd <directory>${C_RESET}" >&2
    return 1
  fi
  mkdir -p "$1" && cd "$1" || return 1
}

# -----------------------------------------------------------------------------
# bak
# -----------------------------------------------------------------------------
# Create a timestamped backup of a file.
# Format: original.YYYY-MM-DD_HH-MM-SS.bak
#
# Usage:
#   bak <file>
# -----------------------------------------------------------------------------
function bak() {
  if [[ $# -eq 0 ]]; then
    echo "${C_YELLOW}Usage: bak <file>${C_RESET}" >&2
    return 1
  fi

  # Check if file exists.
  if [[ -f "$1" ]]; then
    # Create backup with timestamp.
    local backup_file="${1}.$(date +'%Y-%m-%d_%H-%M-%S').bak"
    if cp -p "$1" "$backup_file" 2>/dev/null; then
      echo "${C_GREEN}Backup created: ${backup_file}${C_RESET}"
    else
      echo "${C_RED}Error: Failed to create backup.${C_RESET}" >&2
      return 1
    fi
  else
    echo "${C_RED}Error: File '$1' not found.${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# epoch
# -----------------------------------------------------------------------------
# Display current Unix timestamp and human-readable date.
# Platform-aware (macOS uses -r, Linux uses -d).
# -----------------------------------------------------------------------------
function epoch() {
  local ts=$(date +%s)
  echo "Unix timestamp: $ts"
  if [[ "$PLATFORM" == 'macOS' ]]; then
    echo "Human readable: $(date -r "$ts")"
  else
    echo "Human readable: $(date -d "@$ts")"
  fi
}

# ============================================================================ #
