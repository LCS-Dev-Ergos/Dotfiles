#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ BASE CONFIGURATION ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Base shell configuration, safety settings, color definitions, and platform
# detection. This module must be loaded FIRST as other modules depend on these
# foundational settings.
#
# Responsibilities:
#   - Shell safety options (pipefail, local options/traps).
#   - .zprofile bootstrap for non-login shells.
#   - Platform detection (macOS/Linux/Arch).
#   - ANSI color definitions for terminal output.
#   - Terminal variable configuration.
#   - VS Code integration.
#
# ============================================================================ #

# Profiling (enable by exporting ZSH_PROFILE=1 before starting the shell).
[[ -n "${ZSH_PROFILE:-}" ]] && zmodload zsh/zprof

# Fail on pipe errors.
set -o pipefail

# Protect against unset variables in functions.
setopt LOCAL_OPTIONS
setopt LOCAL_TRAPS

# If ZPROFILE_HAS_RUN variable doesn't exist, we're in a non-login shell
# (e.g., VS Code). Load our base configuration to ensure clean PATH setup.
if [[ -z "$ZPROFILE_HAS_RUN" ]]; then
  if [[ -f "${ZDOTDIR:-$HOME}/.zprofile" ]]; then
    source "${ZDOTDIR:-$HOME}/.zprofile"
  fi
fi

# Enables the advanced features of VS Code's integrated terminal.
# Must be in .zshrc because it is run for each new interactive shell.
if [[ "$TERM_PROGRAM" == "vscode" ]]; then
  # shellcheck source=/dev/null
  if command -v code >/dev/null 2>&1; then
    # Only attempt to source if the command succeeds.
    typeset shell_integration="$(code --locate-shell-integration-path zsh 2>/dev/null)"
    if [[ -n "$shell_integration" && -f "$shell_integration" ]]; then
      . "$shell_integration"
    fi
  fi
fi

# ============================================================================ #
# ++++++++++++++++++++++++ EXECUTION AND OS DETECTION ++++++++++++++++++++++++ #
# ============================================================================ #

# ---- ANSI Color Definitions ---- #
# Check if the current shell is interactive and supports colors.
# If so, define color variables. Otherwise, they will be empty strings.
if [[ -t 1 ]] && command -v tput >/dev/null && [[ $(tput colors) -ge 8 ]]; then
  C_RESET="\e[0m"
  C_BOLD="\e[1m"
  C_RED="\e[31m"
  C_GREEN="\e[32m"
  C_YELLOW="\e[33m"
  BLUE="\e[34m"
  C_CYAN="\e[36m"
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  BLUE=""
  C_CYAN=""
fi

# Export this variable to let .zshrc know that this file has already run.
# This is the crucial synchronization mechanism.
export ZPROFILE_HAS_RUN=true

# Detect operating system to load specific configurations.
if [[ "$(uname)" == "Darwin" ]]; then
  PLATFORM="macOS"
  ARCH_LINUX=false
elif [[ "$(uname)" == "Linux" ]]; then
  PLATFORM="Linux"
  # Check if we're on Arch Linux.
  if [[ -f "/etc/arch-release" ]]; then
    ARCH_LINUX=true
  else
    ARCH_LINUX=false
  fi
else
  PLATFORM="Other"
  ARCH_LINUX=false
fi

# ----------------------------- Startup Commands ----------------------------- #
# Conditional startup commands based on platform.
if [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Arch Linux specific startup commands.
  # command -v fastfetch >/dev/null 2>&1 && fastfetch
elif [[ "$PLATFORM" == "macOS" ]]; then
  # macOS specific startup command.
  # command -v fastfetch >/dev/null 2>&1 && fastfetch
  true # placeholder.
fi

# Disable auto-setting of terminal title to prevent flickering in Kitty.
DISABLE_AUTO_TITLE="true"

# ---------------------------- Terminal Variables ---------------------------- #
# Respect the terminal-provided TERM. Only force kitty when actually in kitty.
case "$TERM" in
  xterm-kitty) export TERM=xterm-kitty ;;     # running in Kitty
  xterm-ghostty) export TERM=xterm-ghostty ;; # running in Ghostty
  *) export TERM=xterm-256color ;;            # sensible default
esac

autoload -Uz add-zsh-hook

# -----------------------------------------------------------------------------#
# _zsh_defer
# -----------------------------------------------------------------------------#
# Defer a function until ZLE is idle (after the first prompt is shown).
# This helps shift non-critical startup work out of the hot path.
# Usage:
#   _zsh_defer function_name
# -----------------------------------------------------------------------------#
if [[ $- == *i* ]]; then
  typeset -ga _ZSH_DEFER_TASKS=()
  typeset -gi _ZSH_DEFER_ARMED=0

  # Run deferred tasks.
  _zsh_defer_run() {
    local task
    for task in "${_ZSH_DEFER_TASKS[@]}"; do
      if typeset -f "$task" >/dev/null 2>&1; then
        "$task"
      fi
    done
    _ZSH_DEFER_TASKS=()
  }

  # File descriptor handler to run deferred tasks.
  _zsh_defer_fdrun() {
    local fd=$1
    exec {fd}>&-
    zle -F $fd
    _zsh_defer_run
  }

  # Precmd hook to set up ZLE file descriptor.
  _zsh_defer_precmd() {
    add-zsh-hook -d precmd _zsh_defer_precmd
    if ! zle; then
      _zsh_defer_run
      return
    fi
    zmodload zsh/system 2>/dev/null || { _zsh_defer_run; return; }
    local fd
    sysopen -r -o cloexec -u fd /dev/null || { _zsh_defer_run; return; }
    zle -F $fd _zsh_defer_fdrun
  }

  # Function to defer tasks.
  _zsh_defer() {
    local task="$1"
    [[ -z "$task" ]] && return 1
    _ZSH_DEFER_TASKS+=("$task")
    if (( ! _ZSH_DEFER_ARMED )); then
      _ZSH_DEFER_ARMED=1
      add-zsh-hook precmd _zsh_defer_precmd
    fi
  }
fi

# Unset options to restore default behavior.
unsetopt xtrace verbose

# ============================================================================ #
