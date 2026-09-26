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
#   - reload    Replace the current process with a clean Zsh instance.
#
# ============================================================================ #

# Remove framework/plugin aliases before defining the canonical implementation.
unalias reload 2>/dev/null

# bak and epoch format timestamps in-process (EPOCHSECONDS, strftime).
zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS 2>/dev/null

# -----------------------------------------------------------------------------
# reload
# @description Replaces the current Zsh process with a clean instance,
# preserving whether the current shell is a login shell. Unlike sourcing
# .zshrc again, this cannot duplicate hooks, widgets, or deferred plugin jobs.
# @noargs
# @exitcode 1 If no executable Zsh binary can be resolved.
# @exitcode 2 If arguments are supplied.
# -----------------------------------------------------------------------------
reload() {
  (( $# == 0 )) || {
    print -u2 "Usage: reload"
    return 2
  }

  local zsh_bin="${commands[zsh]:-${SHELL:-}}"
  [[ -n "$zsh_bin" && -x "$zsh_bin" ]] || {
    print -u2 "reload: could not resolve the Zsh executable"
    return 1
  }

  if [[ -o login ]]; then
    exec "$zsh_bin" -l
  else
    exec "$zsh_bin"
  fi
}

# -----------------------------------------------------------------------------
# up
# @description Moves up parent directories; defaults to one.
# A value of zero leaves the current directory unchanged.
# @arg $1 integer Optional non-negative parent count; defaults to 1.
# @exitcode 1 If the argument is invalid or changing directory fails.
# -----------------------------------------------------------------------------
function up() {
  local limit="${1:-1}"

  if [[ "$limit" != <-> ]]; then
    echo "${C_RED}Error: Argument must be a non-negative integer.${C_RESET}" >&2
    return 1
  fi
  (( limit > 0 )) || return 0

  # Repeat "../" limit times, e.g. 3 -> ../../../
  if ! builtin cd -- "${(pl:limit*3::../:)}"; then
    echo "${C_RED}Error: Cannot go up $limit directories.${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# mkcd
# @description Creates a directory, including parents, and enters it.
# @arg $1 path Directory to create and enter.
# @exitcode 1 If the directory is missing or creation or entry fails.
# -----------------------------------------------------------------------------
function mkcd() {
  if [[ -z "$1" ]]; then
    echo "${C_YELLOW}Usage: mkcd <directory>${C_RESET}" >&2
    return 1
  fi
  command mkdir -p -- "$1" && builtin cd -- "$1" || return 1
}

# -----------------------------------------------------------------------------
# bak
# @description Creates a timestamped .bak copy of a regular file, preserving
# its attributes; a same-second backup may be overwritten.
# @arg $1 path File to back up.
# @exitcode 1 If the source is missing, not regular, or cannot be copied.
# -----------------------------------------------------------------------------
function bak() {
  if [[ $# -eq 0 ]]; then
    echo "${C_YELLOW}Usage: bak <file>${C_RESET}" >&2
    return 1
  fi

  if [[ -f "$1" ]]; then
    local stamp
    strftime -s stamp '%Y-%m-%d_%H-%M-%S' "$EPOCHSECONDS"
    local backup_file="${1}.${stamp}.bak"
    if command cp -p -- "$1" "$backup_file" 2>/dev/null; then
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
# @description Displays the Unix timestamp and local human-readable date.
# @noargs
# -----------------------------------------------------------------------------
function epoch() {
  # zsh/datetime formats in-process, so the BSD/GNU `date` flag differences
  # (-r EPOCH vs -d @EPOCH) never come into play.
  local ts="$EPOCHSECONDS" human
  strftime -s human '%a %b %e %H:%M:%S %Z %Y' "$ts"
  echo "Unix timestamp: $ts"
  echo "Human readable: $human"
}

# ============================================================================ #
# End of core.zsh
