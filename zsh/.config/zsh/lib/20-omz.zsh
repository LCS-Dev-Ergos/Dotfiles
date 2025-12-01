#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ OH-MY-ZSH SETUP ++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Oh-My-Zsh framework initialization with platform-aware plugin management.
# Provides a curated set of plugins for enhanced shell functionality.
#
# Features:
#   - Platform-specific plugin loading (macOS vs. Arch Linux).
#   - Syntax highlighting (must be last plugin).
#   - Autosuggestions and auto-pairing.
#   - Git integration and utility plugins.
#
# Note: zsh-syntax-highlighting must be the last plugin to work correctly.
#
# ============================================================================ #

# Path to Oh-My-Zsh installation (platform specific).
if [[ "$PLATFORM" == "macOS" ]]; then
    export ZSH="$HOME/.oh-my-zsh"
elif [[ "$PLATFORM" == "Linux" ]]; then
    if [[ -d "/usr/share/oh-my-zsh" ]]; then
        export ZSH="/usr/share/oh-my-zsh"
    else
        export ZSH="$HOME/.oh-my-zsh"
    fi
fi

# Set custom directory if needed.
ZSH_CUSTOM=${ZSH_CUSTOM:-$HOME/.config/zsh}

# Set name of the theme to load.
ZSH_THEME=""

# Check for plugin availability on Arch Linux.
if [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
    # Make sure the ZSH_CUSTOM path is set correctly for Arch Linux.
    ZSH_CUSTOM="/usr/share/oh-my-zsh/custom"
fi

# Common plugins for all platforms.
# Note: zsh-syntax-highlighting must be the last plugin to work correctly.
plugins=(
    git
    sudo
    extract
    colored-man-pages
)

# Platform-specific plugins.
if [[ "$PLATFORM" == "macOS" ]]; then
    # macOS specific plugins.
    plugins+=(
        zsh-autosuggestions
        zsh-syntax-highlighting
    )
elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
    # Arch Linux specific plugins.
    plugins+=(
        fzf
        zsh-256color
        zsh-history-substring-search
        zsh-autopair
        zsh-autosuggestions
        zsh-syntax-highlighting
    )
fi

# ZSH Cache.
export ZSH_COMPDUMP="$ZSH/cache/.zcompdump-$HOST"

source "$ZSH/oh-my-zsh.sh"

# ============================================================================ #
