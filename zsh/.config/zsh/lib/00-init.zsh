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

# Profiling (uncomment to debug startup time).
zmodload zsh/zprof

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
    local shell_integration="$(code --locate-shell-integration-path zsh 2>/dev/null)"
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
  command -v fastfetch >/dev/null 2>&1 && fastfetch
elif [[ "$PLATFORM" == "macOS" ]]; then
  # macOS specific startup command.
  # command -v fastfetch >/dev/null 2>&1 && fastfetch
  true # placeholder.
fi

# ---------------------------- Terminal Variables ---------------------------- #
if [[ "$TERM" == "xterm-kitty" ]]; then
  export TERM=xterm-kitty
else
  export TERM=xterm-256color
fi

autoload -Uz add-zsh-hook

# Unset options to restore default behavior.
unsetopt xtrace verbose

# ============================================================================ #
