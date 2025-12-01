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

# ------------ ngrok ---------------- #
# Lazy load or manual load recommended to save startup time.
if command -v ngrok >/dev/null 2>&1; then
    eval "$(ngrok completion 2>/dev/null)" || true
fi

# ----------- Angular CLI ----------- #
# Lazy load or manual load recommended to save startup time.
if command -v ng >/dev/null 2>&1; then
    source <(ng completion script 2>/dev/null) || true
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
