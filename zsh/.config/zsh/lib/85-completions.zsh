#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ COMPLETION SYSTEMS +++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Shell completion initialization for various tools.
# Completions enhance command-line productivity with tab-completion support.
#
# Tools:
#   - Docker (custom completion directory)
#   - ngrok
#   - Angular CLI
#
# Note: This module must load LATE to ensure all PATH modifications are complete.
#
# ============================================================================ #

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
#   - Platform-aware cache validation (macOS uses stat -f, Linux uses find).
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

  # Check if cache exists and is less than 7 days old.
  if [[ -f "$cache_file" ]]; then
    local cache_valid=false
    if [[ "$PLATFORM" == 'macOS' ]]; then
      local mtime=$(stat -f %m "$cache_file")
      local now=$(date +%s)
      if ((now - mtime < 604800)); then
        cache_valid=true
      fi
    else
      if [[ -n $(find "$cache_file" -mtime -7 2>/dev/null) ]]; then
        cache_valid=true
      fi
    fi

    if $cache_valid; then
      source "$cache_file"
      return
    fi
  fi

  # Generate completion.
  mkdir -p "$(dirname "$cache_file")"
  "${generate_cmd[@]}" >"$cache_file" 2>/dev/null
  source "$cache_file"
}

# ------------ ngrok ---------------- #
if command -v ngrok >/dev/null 2>&1; then
  _cache_completion ngrok ngrok completion
fi

# ----------- Angular CLI ----------- #
if command -v ng >/dev/null 2>&1; then
  _cache_completion ng ng completion script
fi

# ----------- Docker CLI  ----------- #
if [[ -d "$HOME/.docker/completions" ]]; then
  # Add custom completions directory.
  fpath=("/Users/lcs-dev/Dotfiles/zsh/.config/zsh/completions" "$HOME/.docker/completions" $fpath)
fi

autoload -Uz compinit
# Use -C only if the dump file exists, otherwise do a full init.
if [[ -f "$ZSH_COMPDUMP" ]]; then
  compinit -C -d "$ZSH_COMPDUMP"
else
  compinit -d "$ZSH_COMPDUMP"
fi

# ============================================================================ #
