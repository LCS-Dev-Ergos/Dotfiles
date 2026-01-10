#!/usr/bin/env zsh
# ============================================================================ #
#! ██████╗░░█████╗░  ███╗░░██╗░█████╗░████████╗  ███████╗██████╗░██╗████████╗
#! ██╔══██╗██╔══██╗  ████╗░██║██╔══██╗╚══██╔══╝  ██╔════╝██╔══██╗██║╚══██╔══╝
#! ██║░░██║██║░░██║  ██╔██╗██║██║░░██║░░░██║░░░  █████╗░░██║░░██║██║░░░██║░░░
#! ██║░░██║██║░░██║  ██║╚████║██║░░██║░░░██║░░░  ██╔══╝░░██║░░██║██║░░░██║░░░
#! ██████╔╝╚█████╔╝  ██║░╚███║╚█████╔╝░░░██║░░░  ███████╗██████╔╝██║░░░██║░░░
#! ╚═════╝░░╚════╝░  ╚═╝░░╚══╝░╚════╝░░░░╚═╝░░░  ╚══════╝╚═════╝░╚═╝░░░╚═╝░░░
# ============================================================================ #
#
# ============================================================================ #
# ++++++++++++++++++++++ ZSHENV - Environment Variables ++++++++++++++++++++++ #
# ============================================================================ #
#
# This file is sourced for ALL shell types (interactive, non-interactive, login).
# It should ONLY contain environment variable exports - no shell configuration.
#
# Standard Zsh loading order:
#   1. .zshenv     <- YOU ARE HERE (env vars only)
#   2. .zprofile   <- login shells
#   3. .zshrc      <- interactive shells (shell config goes here)
#   4. .zlogin     <- login shells (after .zshrc)
#
# IMPORTANT: Do NOT source .zshrc from here - let Zsh handle the natural flow.
#
# ============================================================================ #

# Platform detection - load HyDE environment variables on Arch Linux.
# Only env.zsh is loaded here - shell configuration is deferred to .zshrc
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  if [[ "$ID" == "arch" ]]; then
    # HyDE configs stay in the XDG config dir even if we later move ZDOTDIR to $HOME.
    local hyde_cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
    local hyde_env="${hyde_cfg_root}/conf.d/hyde/env.zsh"
    [[ -r "$hyde_env" ]] && source "$hyde_env"
  fi
fi

# Force ZDOTDIR to $HOME so history/dump files live in the home directory
# while the actual configs remain under ${XDG_CONFIG_HOME:-$HOME/.config}/zsh.
export ZDOTDIR="$HOME"

# NOTE: .zshrc is loaded automatically by Zsh for interactive shells.
# No explicit sourcing needed here.

# ============================================================================ #
