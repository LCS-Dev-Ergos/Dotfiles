#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#   █████╗ ██╗   ██╗████████╗ ██████╗      ██████╗ ██████╗ ███╗   ███╗██████╗
#  ██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗    ██╔════╝██╔═══██╗████╗ ████║██╔══██╗
#  ███████║██║   ██║   ██║   ██║   ██║    ██║     ██║   ██║██╔████╔██║██████╔╝
#  ██╔══██║██║   ██║   ██║   ██║   ██║    ██║     ██║   ██║██║╚██╔╝██║██╔═══╝
#  ██║  ██║╚██████╔╝   ██║   ╚██████╔╝    ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║
#  ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝      ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝
# ============================================================================ #
# ++++++++++++++++++++++++++++ COMPLETION SYSTEMS ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Shell completion initialization for various tools.
# Completions enhance command-line productivity with tab-completion support.
#
# Tools:
#   - Bun (JavaScript runtime)
#   - Docker (custom completion directory)
#   - ngrok
#   - Angular CLI
#
# Note: This module must load LATE to ensure all PATH modifications are complete.
# ============================================================================ #

# On HyDE with user's lib/config: compinit usually runs in 20-zinit.zsh.
# On HyDE with shell.zsh: compinit already ran there.
# This guard prevents double compinit when shell.zsh was loaded.
if [[ "$HYDE_ENABLED" == "1" ]] && [[ "${HYDE_ZSH_NO_PLUGINS}" != "1" ]]; then
    # shell.zsh already ran compinit, skip everything (fpath already set there).
    return 0
fi

# On HyDE with HYDE_ZSH_NO_PLUGINS=1: shell.zsh already added completions to fpath.
# Skip adding again to avoid duplicates.
if [[ "$HYDE_ENABLED" == "1" ]] && [[ "${HYDE_ZSH_NO_PLUGINS}" == "1" ]]; then
    # shell.zsh:145 already added $ZDOTDIR/completions to fpath.
    # We only need to ensure compinit runs (which happens below).
    HYDE_SKIP_FPATH_COMPLETIONS=1
fi

# -----------------------------------------------------------------------------
# _cache_completion
# -----------------------------------------------------------------------------
# Caches command completion scripts to improve shell startup performance.
# Generates completions on first run or when cache expires (7 days).
#
# Parameters:
#   $1 - Command name (e.g., "ngrok", "ng").
#   $2 - Generation command (e.g., "ngrok completion").
#
# Cache location:
#   ${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions/_<cmd>
#
# Behavior:
#   - Uses cached completion if valid (< 7 days old).
#   - Regenerates completion if cache missing or expired.
#   - Platform-aware cache validation (macOS uses stat -f, Linux uses stat -c).
#
# Usage:
#   _cache_completion "ngrok" "ngrok completion"
#   _cache_completion "ng" "ng completion script"
# -----------------------------------------------------------------------------
_cache_completion() {
  local cmd="$1"
  shift
  local -a generate_cmd=("$@")
  local cache_file="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/completions/_$cmd"
  local cache_safe=false

  # Check if cache exists and is less than 7 days old.
  if [[ -f "$cache_file" ]]; then
    local cache_valid=false
    local now=${EPOCHSECONDS:-$(date +%s)}
    local mtime=""

    if typeset -f _zsh_mtime >/dev/null 2>&1; then
      mtime="$(_zsh_mtime "$cache_file")"
    elif [[ "$PLATFORM" == 'macOS' ]]; then
      mtime="$(command stat -f %m "$cache_file" 2>/dev/null)"
    else
      mtime="$(command stat -c %Y "$cache_file" 2>/dev/null)"
    fi

    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    if (( now - mtime < 604800 )); then
      cache_valid=true
    fi

    if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
      _zsh_is_secure_file "$cache_file" && cache_safe=true
    elif [[ -r "$cache_file" && -O "$cache_file" && ! -L "$cache_file" ]]; then
      cache_safe=true
    fi

    if $cache_valid && $cache_safe; then
      source "$cache_file"
      return
    elif $cache_valid && ! $cache_safe; then
      print -u2 "Completion cache skipped (insecure file): $cache_file"
    fi
  fi

  # Generate completion.
  local cache_dir="${cache_file:h}"
  local tmp_file=""
  mkdir -p "$cache_dir"

  tmp_file="$(mktemp "${cache_dir}/.${cmd}.XXXXXX" 2>/dev/null)" || return 1
  if "${generate_cmd[@]}" >"$tmp_file" 2>/dev/null; then
    chmod 600 "$tmp_file" 2>/dev/null || :
    mv -f "$tmp_file" "$cache_file"
  else
    rm -f -- "$tmp_file" 2>/dev/null
    return 1
  fi

  cache_safe=false
  if typeset -f _zsh_is_secure_file >/dev/null 2>&1; then
    _zsh_is_secure_file "$cache_file" && cache_safe=true
  elif [[ -r "$cache_file" && -O "$cache_file" && ! -L "$cache_file" ]]; then
    cache_safe=true
  fi
  $cache_safe && source "$cache_file"
}

# ------- Deferred completions ------- #
_late_completions() {
  if [[ -s "$HOME/.bun/_bun" ]]; then
    source "$HOME/.bun/_bun"
  fi
  if command -v ngrok >/dev/null 2>&1; then
    _cache_completion ngrok ngrok completion
  fi
  if command -v ng >/dev/null 2>&1; then
    _cache_completion ng ng completion script
  fi
  unfunction _late_completions 2>/dev/null
}

if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
  : # skip during fast start.
elif [[ "${ZSH_DEFER_COMPLETIONS:-1}" == "1" ]]; then
  _zsh_defer _late_completions
else
  _late_completions
fi

# ----------- Docker CLI  ------------ #
# Add custom completions directories (unless HyDE already did it).
typeset -i _completion_fpath_changed=0
if [[ "${HYDE_SKIP_FPATH_COMPLETIONS:-0}" != "1" ]]; then
  local _completions_dir="${ZDOTDIR:-$HOME/.config/zsh}/completions"
  if [[ -d "$_completions_dir" ]] && (( ${fpath[(Ie)$_completions_dir]} == 0 )); then
    fpath=("$_completions_dir" $fpath)
    _completion_fpath_changed=1
  fi
  unset _completions_dir
fi

# Docker completions (always check, as HyDE doesn't add this).
local _docker_completions_dir="$HOME/.docker/completions"
if [[ -d "$_docker_completions_dir" ]] && (( ${fpath[(Ie)$_docker_completions_dir]} == 0 )); then
  fpath=("$_docker_completions_dir" $fpath)
  _completion_fpath_changed=1
fi
unset _docker_completions_dir

autoload -Uz compinit
typeset -a compinit_opts
compinit_opts=(-d "$ZSH_COMPDUMP")
if [[ "$ZSH_DISABLE_COMPFIX" == true ]]; then
  compinit_opts=(-u $compinit_opts)
fi

# Avoid double compinit (20-zinit.zsh usually already ran it).
if (( ! ${+_comps} )); then
  # Use -C only if the dump file exists, otherwise do a full init.
  if [[ -f "$ZSH_COMPDUMP" ]]; then
    compinit -C "${compinit_opts[@]}"
  else
    compinit "${compinit_opts[@]}"
  fi
elif (( _completion_fpath_changed )); then
  # fpath changed after compinit: rebuild completion map to include new dirs.
  compinit "${compinit_opts[@]}"
fi
unset compinit_opts _completion_fpath_changed

# ============================================================================ #
# End of 85-completions.zsh
