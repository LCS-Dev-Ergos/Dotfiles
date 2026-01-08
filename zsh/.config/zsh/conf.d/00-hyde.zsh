#!/usr/bin/env zsh
# ============================================================================ #
#!                     ██╗  ██╗██╗   ██╗██████╗ ███████╗
#!                     ██║  ██║╚██╗ ██╔╝██╔══██╗██╔════╝
#!                     ███████║ ╚████╔╝ ██║  ██║█████╗
#!                     ██╔══██║  ╚██╔╝  ██║  ██║██╔══╝
#!                     ██║  ██║   ██║   ██████╔╝███████╗
#!                     ╚═╝  ╚═╝   ╚═╝   ╚═════╝ ╚══════╝
# ============================================================================ #

# ============================================================================ #
# +++++++++++++++++++++++++++++++ HyDE Loader ++++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# This file is sourced by .zshenv on Arch Linux systems.
# It ONLY loads environment variables from env.zsh.
#
# Shell configuration (OMZ, prompt, functions) is handled by:
#   - conf.d/hyde/shell.zsh (loaded by .zshrc when HYDE_ENABLED=1).
#
# This separation ensures:
#   1. .zshenv remains fast (only env vars).
#   2. No duplicate OMZ/prompt loading.
#   3. Clean coordination via HYDE_ENABLED flag.
#
# ============================================================================ #

# Load HyDE environment variables.
# This sets HYDE_ENABLED=1, XDG vars, PATH additions, etc.
if [[ -f "$ZDOTDIR/conf.d/hyde/env.zsh" ]]; then
  source "$ZDOTDIR/conf.d/hyde/env.zsh"
else
  echo "Warning: HyDE env.zsh not found at $ZDOTDIR/conf.d/hyde/env.zsh" >&2
fi

# NOTE: terminal.zsh is NO LONGER loaded here.
# Shell configuration is now handled by shell.zsh, loaded from .zshrc.
# This prevents duplicate OMZ/prompt initialization.
