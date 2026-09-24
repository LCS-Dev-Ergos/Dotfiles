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
#   - .zprofile bootstrap for non-login shells.
#   - The parts of Apple's /etc/zshrc this configuration keeps (macOS).
#   - Platform detection (macOS/Linux/Arch).
#   - ANSI color definitions for terminal output.
#   - Terminal variable configuration and the vi keymap selection.
#   - VS Code integration.
#   - The idle-time defer queue.
#
# ============================================================================ #

# Profiling (enable by exporting ZSH_PROFILE=1 before starting the shell).
[[ "${ZSH_PROFILE:-0}" == "1" ]] && zmodload -i zsh/zprof 2>/dev/null

# Load zsh/datetime for $EPOCHSECONDS (avoids forking `date +%s`).
zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS 2>/dev/null

# Shared colors, platform, filesystem, and cache primitives. This explicit
# source also makes direct sourcing of 00-initialization deterministic; the
# runtime module stays independent from the numbered startup glob.
typeset _zsh_runtime_helpers="${${(%):-%N}:A:h:h}/runtime-helpers.zsh"
if [[ -r "$_zsh_runtime_helpers" ]]; then
  source "$_zsh_runtime_helpers"
else
  print -u2 "Warning: runtime helpers not found: $_zsh_runtime_helpers"
  return 1
fi
unset _zsh_runtime_helpers

# LOCAL_OPTIONS and LOCAL_TRAPS stay at their defaults (off) at top level.
# Turned on globally, every function return rolls back the options it set,
# including the ones plugin managers apply from inside their loader functions
# (OMZ's completion library sets complete_in_word, always_to_end and
# no_flow_control that way). Functions that need scoped options declare it
# with `emulate -L zsh` or `setopt localoptions`.

# If ZPROFILE_HAS_RUN variable doesn't exist, we're in a non-login shell
# (e.g., VS Code). Load our base configuration to ensure clean PATH setup.
if [[ -z "$ZPROFILE_HAS_RUN" ]]; then
  if [[ -f "${ZDOTDIR:-$HOME}/.zprofile" ]]; then
    source "${ZDOTDIR:-$HOME}/.zprofile"
  fi
fi

# Apple's /etc/zshrc is skipped on purpose (see the GLOBAL_RCS note in
# .zshenv). History, key bindings, and the prompt are owned by later modules;
# this keeps the rest of it, without the `locale` fork it used to test for
# UTF-8. Nothing happens when /etc/zshrc did run.
if [[ "$OSTYPE" == darwin* && ! -o global_rcs ]]; then
  zmodload -F zsh/langinfo p:langinfo 2>/dev/null &&
    [[ "${langinfo[CODESET]-}" == UTF-8 ]] && setopt COMBINING_CHARS
  # Keep `log` for /usr/bin/log instead of the builtin of the same name.
  disable log 2>/dev/null
  # Terminal.app integration: working-directory reporting and session
  # restore.
  [[ -n "${TERM_PROGRAM:-}" && -r "/etc/zshrc_$TERM_PROGRAM" ]] &&
    source "/etc/zshrc_$TERM_PROGRAM"
fi

# Enables the advanced features of VS Code's integrated terminal.
# Must be in .zshrc because it is run for each new interactive shell.
if [[ "$TERM_PROGRAM" == "vscode" ]]; then
  # shellcheck source=/dev/null
  () {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
    local cache_file="$cache_dir/vscode-shell-integration"
    local shell_integration=""

    # The cached value names a script we source, so the cache itself must
    # pass the same ownership and permission checks as any sourced file.
    if _zsh_is_secure_file "$cache_file"; then
      IFS= read -r shell_integration < "$cache_file"
    fi

    if [[ -z "$shell_integration" || ! -f "$shell_integration" ]]; then
      if command -v code >/dev/null 2>&1; then
        shell_integration="$(code --locate-shell-integration-path zsh 2>/dev/null)"
        if [[ -n "$shell_integration" && -f "$shell_integration" ]]; then
          print -r -- "$shell_integration" | _zsh_cache_put "$cache_file"
        fi
      fi
    fi

    if [[ -n "$shell_integration" && -f "$shell_integration" ]]; then
      . "$shell_integration"
    fi
  }
fi

# ++++++++++++++++++++++++ EXECUTION AND OS DETECTION ++++++++++++++++++++++++ #

# ---- ANSI Color Definitions ---- #
_zsh_init_colors

# Export this variable to let .zshrc know that this file has already run.
# This is the crucial synchronization mechanism.
export ZPROFILE_HAS_RUN=true

# Platform detection is provided by runtime-helpers.zsh.
_zsh_detect_platform

# CPU count, reused by OPAMJOBS and CARGO_BUILD_JOBS. The hardware value never
# changes between shells, so it is cached instead of forking sysctl/nproc on
# every startup; the integer check keeps a tampered cache from reaching the
# arithmetic context.
typeset -gi _ZSH_NCPUS=4
() {
  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/ncpus" count=""
  _zsh_is_secure_file "$cache_file" && IFS= read -r count < "$cache_file"
  if [[ "$count" != <1-> ]]; then
    count="$(command sysctl -n hw.ncpu 2>/dev/null ||
      command nproc 2>/dev/null)"
    [[ "$count" == <1-> ]] || return 0
    print -r -- "$count" | _zsh_cache_put "$cache_file" 2>/dev/null
  fi
  _ZSH_NCPUS=$count
}

# ----------------------------- STARTUP COMMANDS ----------------------------- #
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

# ---------------------------- TERMINAL VARIABLES ---------------------------- #
# Keep terminal-provided TERM whenever available. Only set a default when TERM
# is missing or set to "dumb" (common in limited/non-interactive contexts).
case "${TERM:-}" in
  "" | dumb)
    case "${TERM_PROGRAM:-}" in
      kitty) export TERM=xterm-kitty ;;
      ghostty) export TERM=xterm-ghostty ;;
      *) export TERM=xterm-256color ;;
    esac
    ;;
esac

# Select vi editing before any module binds keys. zsh picks the main keymap
# from EDITOR/VISUAL when it starts, so in a shell started without them the
# plugin bindings of 20-zinit.zsh would land in the emacs keymap, which
# 40-vi-mode.zsh then swaps out for viins.
[[ -o zle ]] && bindkey -v

autoload -Uz add-zsh-hook

# -----------------------------------------------------------------------------
# _zsh_defer
# @internal
# @description Queues a named function to run once ZLE is idle, after the
# first prompt is shown, to keep non-critical work out of the startup path.
# @arg $1 string Name of the function to defer.
# -----------------------------------------------------------------------------
if [[ $- == *i* ]]; then
  typeset -ga _ZSH_DEFER_TASKS=()
  typeset -gi _ZSH_DEFER_ARMED=0

  # ---------------------------------------------------------------------------
  # _zsh_defer_run
  # @internal
  # @description Drains the deferred queue, including tasks queued by tasks
  # that are already running, then disarms it so a later _zsh_defer call
  # schedules a fresh idle run.
  # @noargs
  # ---------------------------------------------------------------------------
  _zsh_defer_run() {
    local task
    local -a batch
    while (( ${#_ZSH_DEFER_TASKS} )); do
      batch=("${_ZSH_DEFER_TASKS[@]}")
      _ZSH_DEFER_TASKS=()
      for task in "${batch[@]}"; do
        (( $+functions[$task] )) && "$task"
      done
    done
    _ZSH_DEFER_ARMED=0
  }

  # ---------------------------------------------------------------------------
  # _zsh_defer_fdrun
  # @internal
  # @description Closes the one-shot file descriptor and runs deferred tasks;
  # registered as the zle -F callback for that descriptor.
  # @arg $1 integer File descriptor passed by the zle -F callback.
  # ---------------------------------------------------------------------------
  _zsh_defer_fdrun() {
    local fd=$1
    exec {fd}>&-
    zle -F $fd
    _zsh_defer_run
  }

  # ---------------------------------------------------------------------------
  # _zsh_defer_precmd
  # @internal
  # @description One-shot precmd hook that opens a /dev/null file descriptor
  # and arms _zsh_defer_fdrun on it so deferred tasks run once ZLE is idle;
  # runs them immediately if the line editor or zsh/system is unavailable.
  # The test is the ZLE option, not `zle` without arguments: that reports
  # whether a widget is running, which is never the case in precmd, so it
  # ran the whole queue before the first prompt was drawn.
  # @noargs
  # ---------------------------------------------------------------------------
  _zsh_defer_precmd() {
    add-zsh-hook -d precmd _zsh_defer_precmd
    if [[ ! -o zle ]]; then
      _zsh_defer_run
      return
    fi
    zmodload zsh/system 2>/dev/null || { _zsh_defer_run; return; }
    local fd
    sysopen -r -o cloexec -u fd /dev/null || { _zsh_defer_run; return; }
    zle -F $fd _zsh_defer_fdrun
  }

  # Queue a task and arm the one-shot precmd hook when it is not armed yet.
  # A task queued while the queue runs lands in its next batch, after every
  # task queued before (20-zinit.zsh relies on this for highlighting).
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
# End of lib/00-initialization.zsh
