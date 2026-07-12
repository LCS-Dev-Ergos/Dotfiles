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
    local cache_is_secure=false

    if [[ -r "$cache_file" && -O "$cache_file" && ! -L "$cache_file" ]]; then
      cache_is_secure=true
    fi

    if $cache_is_secure; then
      IFS= read -r shell_integration < "$cache_file"
    fi

    if [[ -z "$shell_integration" || ! -f "$shell_integration" ]]; then
      if command -v code >/dev/null 2>&1; then
        shell_integration="$(code --locate-shell-integration-path zsh 2>/dev/null)"
        if [[ -n "$shell_integration" && -f "$shell_integration" ]]; then
          command mkdir -p "$cache_dir" 2>/dev/null
          (
            umask 077
            print -r -- "$shell_integration" >| "$cache_file"
          ) 2>/dev/null
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
_zsh_init_colors

# Export this variable to let .zshrc know that this file has already run.
# This is the crucial synchronization mechanism.
export ZPROFILE_HAS_RUN=true

# Platform detection is provided by runtime-helpers.zsh.
_zsh_detect_platform

# CPU count (computed once, reused by OPAMJOBS, CARGO_BUILD_JOBS, etc.).
typeset -gi _ZSH_NCPUS
(( _ZSH_NCPUS = $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) ))

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
  # _zsh_cache_auto_check
  # @internal
  # @description Rebuilds completion/lazy-loader caches and recompiles .zwc
  # bytecode once, deferred to after the first prompt, when any startup
  # config file changed since the last stamp. Disable with ZSH_CACHE_AUTO=0.
  # @noargs
  # ---------------------------------------------------------------------------
  _zsh_cache_auto_check() {
    [[ "${ZSH_CACHE_AUTO:-1}" == "1" ]] || return 0

    emulate -L zsh
  # The fallback removes only files rooted in the resolved Zsh cache paths.
  # Keep that maintenance non-interactive: RM_STAR_SILENT otherwise makes Zsh
  # ask for confirmation before expanding the cache-directory wildcard.
  setopt noxtrace noverbose nullglob rmstarsilent

    local cfg_root="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}"
    [[ -d "$cfg_root" ]] || return 0

    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
    local stamp_file="$cache_dir/config.mtime"
    local zdot="${ZDOTDIR:-$HOME}"

    # Collect startup config files; scripts/ are lazy-loaded.
    local -a files
    files=(
      "$cfg_root"/runtime-helpers.zsh(N.)
      "$cfg_root"/lib/*.zsh(N.)
      "$cfg_root"/functions/*.zsh(N.)
      "$cfg_root"/conf.d/**/*.zsh(N.)
    )
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

      # Keep bytecode synchronized automatically instead of silently falling
      # back to stale source files until a manual `zshcache --compile` run.
      local -a compile_files
      compile_files=(
        "$cfg_root"/runtime-helpers.zsh(N.)
        "$cfg_root"/lib/*.zsh(N.)
        "$cfg_root"/functions/*.zsh(N.)
        "$cfg_root"/conf.d/**/*.zsh(N.)
      )
      local compile_file
      for compile_file in "${compile_files[@]}"; do
        zcompile -U "$compile_file" 2>/dev/null ||
          print -u2 "Warning: zcompile failed for $compile_file"
      done
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
# End of lib/00-initialization.zsh
