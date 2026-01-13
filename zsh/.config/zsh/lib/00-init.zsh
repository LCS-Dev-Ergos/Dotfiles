#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#                           ██╗███╗   ██╗██╗████████╗
#                           ██║████╗  ██║██║╚══██╔══╝
#                           ██║██╔██╗ ██║██║   ██║
#                           ██║██║╚██╗██║██║   ██║
#                           ██║██║ ╚████║██║   ██║
#                           ╚═╝╚═╝  ╚═══╝╚═╝   ╚═╝
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
  () {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
    local cache_file="$cache_dir/vscode-shell-integration"
    local shell_integration=""

    if [[ -r "$cache_file" ]]; then
      IFS= read -r shell_integration < "$cache_file"
    fi

    if [[ -z "$shell_integration" || ! -f "$shell_integration" ]]; then
      if command -v code >/dev/null 2>&1; then
        shell_integration="$(code --locate-shell-integration-path zsh 2>/dev/null)"
        if [[ -n "$shell_integration" && -f "$shell_integration" ]]; then
          command mkdir -p "$cache_dir" 2>/dev/null
          print -r -- "$shell_integration" >| "$cache_file"
        fi
      fi
    fi

    if [[ -n "$shell_integration" && -f "$shell_integration" ]]; then
      . "$shell_integration"
    fi
  }
fi

# ============================================================================ #
# ++++++++++++++++++++++++ EXECUTION AND OS DETECTION ++++++++++++++++++++++++ #
# ============================================================================ #

# ---- ANSI Color Definitions ---- #
# Check if the current shell is interactive and supports colors.
# If so, define color variables. Otherwise, they will be empty strings.
if [[ -t 1 ]]; then
  zmodload -i zsh/terminfo 2>/dev/null
  if [[ -n "${terminfo[colors]-}" ]] && (( terminfo[colors] >= 8 )); then
    C_RESET="\e[0m"
    C_BOLD="\e[1m"
    C_RED="\e[31m"
    C_GREEN="\e[32m"
    C_YELLOW="\e[33m"
    C_BLUE="\e[34m"
    C_CYAN="\e[36m"
  else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
  fi
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
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

# -----------------------------------------------------------------------------
# _zsh_defer
# -----------------------------------------------------------------------------
# Defer a function until ZLE is idle (after the first prompt is shown).
# This helps shift non-critical startup work out of the hot path.
# Usage:
#   _zsh_defer function_name
# -----------------------------------------------------------------------------
if [[ $- == *i* ]]; then
  typeset -ga _ZSH_DEFER_TASKS=()
  typeset -gi _ZSH_DEFER_ARMED=0
  typeset -gi _ZSH_HAS_ZSTAT=0

  if zmodload -i zsh/stat 2>/dev/null; then
    _ZSH_HAS_ZSTAT=1
  fi

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

  # ---------------------------------------------------------------------------
  # _zsh_mtime
  # ---------------------------------------------------------------------------
  # Return file modification time using zstat when available.
  _zsh_mtime() {
    local file="$1"
    local -a stat_info

    if (( _ZSH_HAS_ZSTAT )) && zstat -L -A stat_info +mtime -- "$file" 2>/dev/null; then
      print -r -- "$stat_info[1]"
      return 0
    fi

    if [[ "$OSTYPE" == darwin* ]]; then
      command stat -f %m "$file" 2>/dev/null
    else
      command stat -c %Y "$file" 2>/dev/null
    fi
  }

  # ---------------------------------------------------------------------------
  # _zsh_is_secure_file
  # ---------------------------------------------------------------------------
  # Ensure file is owned by the current user and not group/world-writable.
  _zsh_is_secure_file() {
    local file="$1"
    [[ -f "$file" && -r "$file" ]] || return 1

    local -a stat_info
    if (( _ZSH_HAS_ZSTAT )) && zstat -L -A stat_info +mode +uid -- "$file" 2>/dev/null; then
      local mode=$stat_info[1]
      local uid=$stat_info[2]
      (( uid == EUID )) || return 1
      (( mode & 0022 )) && return 1
      return 0
    fi

    local mode uid
    if [[ "$OSTYPE" == darwin* ]]; then
      uid="$(command stat -f %u "$file" 2>/dev/null)" || return 1
      mode="$(command stat -f %Lp "$file" 2>/dev/null)" || return 1
    else
      uid="$(command stat -c %u "$file" 2>/dev/null)" || return 1
      mode="$(command stat -c %a "$file" 2>/dev/null)" || return 1
    fi

    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    [[ "$mode" =~ ^[0-9]+$ ]] || return 1
    (( uid == EUID )) || return 1
    (( 8#$mode & 022 )) && return 1
    return 0
  }

  # ---------------------------------------------------------------------------
  # _zsh_cache_auto_check
  # ---------------------------------------------------------------------------
  # One-time cache reset when config files changed since last stamp.
  # Deferred to run after first prompt for faster startup.
  # Disable with: ZSH_CACHE_AUTO=0
  _zsh_cache_auto_check() {
    [[ "${ZSH_CACHE_AUTO:-1}" == "1" ]] || return 0

    emulate -L zsh
    setopt noxtrace noverbose nullglob

    local cfg_root="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}"
    [[ -d "$cfg_root" ]] || return 0

    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
    local stamp_file="$cache_dir/config.mtime"
    local zdot="${ZDOTDIR:-$HOME}"

    # Collect config files using zsh glob (no fork).
    local -a files
    files=("$cfg_root"/**/*.(zsh|sh)(N.))
    [[ -f "$HOME/.zshrc" ]] && files+=("$HOME/.zshrc")
    [[ -f "$HOME/.zshenv" ]] && files+=("$HOME/.zshenv")
    (( ${#files[@]} )) || return 0

    # Find the latest mtime.
    local latest=0 mtime file
    for file in "${files[@]}"; do
      mtime="$(_zsh_mtime "$file")" || continue
      [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > latest )) && latest=$mtime
    done

    # Get stamp file mtime.
    local last=0
    if [[ -f "$stamp_file" ]]; then
      last="$(_zsh_mtime "$stamp_file")"
      [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi

    # Rebuild cache if config is newer.
    if (( latest > last )); then
      if typeset -f zshcache >/dev/null 2>&1; then
        zshcache --rebuild --quiet
      else
        command rm -rf -- "$cache_dir"/* "$zdot"/.zcompdump* 2>/dev/null
        autoload -Uz compinit
        compinit -C
      fi
      command mkdir -p "$cache_dir" 2>/dev/null
      : >| "$stamp_file"
    fi
  }

  # Defer cache check to run after first prompt (non-blocking startup).
  _zsh_defer _zsh_cache_auto_check
fi

# Unset options to restore default behavior.
unsetopt xtrace verbose

# ============================================================================ #
# End of 00-init.zsh
