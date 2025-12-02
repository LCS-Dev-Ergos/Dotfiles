#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ ZSH CONFIGURATION +++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Personal interactive Zsh configuration with modular architecture.
# This is the main loader that sources individual configuration modules.
#
# ARCHITECTURE:
#   This file has been refactored from a 2000+ line monolithic configuration
#   into a modular system for better maintainability and organization.
#
# Configuration modules are loaded from: ~/.config/zsh/lib/
#
# Loading order (critical for proper functionality):
#
#   00-init.zsh         - Base configuration, platform detection, colors.
#   10-history.zsh      - History settings.
#   20-omz.zsh          - Oh-My-Zsh initialization.
#   30-prompt.zsh       - Prompt system (Starship/P10k/Minimal).
#   40-vi-mode.zsh      - Vi mode and keybindings.
#   50-tools.zsh        - Modern tools (fzf, zoxide, yazi, atuin).
#   60-aliases.zsh      - All aliases and utility functions.
#   70-fabric.zsh       - Fabric AI integration.
#   75-variables.zsh    - Global variables and exports.
#   80-languages.zsh    - Language managers (SDKMAN, pyenv, fnm, etc.).
#   85-completions.zsh  - Completion systems.
#   90-path.zsh         - Final PATH assembly and cleanup.
#
# BENEFITS OF MODULAR ARCHITECTURE:
#   - Maintainability: Each file has a single responsibility.
#   - Performance: Easy to profile and optimize individual modules.
#   - Debugging: Can disable specific modules for troubleshooting.
#   - Portability: Modules can be shared across machines.
#   - Version Control: Smaller, focused commits.
#
#
# EXTERNAL SCRIPTS:
#   Custom scripts from ~/.config/zsh/scripts/ are loaded after core modules.
#   Scripts are sourced alphabetically by filename.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# Configuration directory: robustly determine the configuration directory.
# We look for the 'lib' directory to confirm we have the right place.
# -----------------------------------------------------------------------------
# 1. Try "ZDOTDIR".
if [[ -n "$ZDOTDIR" && -d "$ZDOTDIR/lib" ]]; then
    ZSH_CONFIG_DIR="$ZDOTDIR"
# 2. Try Standard XDG location.
elif [[ -d "$HOME/.config/zsh/lib" ]]; then
    ZSH_CONFIG_DIR="$HOME/.config/zsh"
else
    # 3. Try relative to this file (for symlinks or direct sourcing).
    local current_dir="${${(%):-%x}:A:h}"

    if [[ -d "$current_dir/lib" ]]; then
        ZSH_CONFIG_DIR="$current_dir"
    elif [[ -d "$current_dir/.config/zsh/lib" ]]; then
        ZSH_CONFIG_DIR="$current_dir/.config/zsh"
    # 4. Fallback to HOME if nothing else works (last resort).
    else
        ZSH_CONFIG_DIR="$HOME/.config/zsh"
    fi
fi

# +++++++++++++++++++++++++ LOAD CORE MODULES ++++++++++++++++++++++++++++++++ #

# Load modules in priority order.
# Note: Order is critical - Do not rearrange without understanding dependencies.
# Use an array to capture the files first to check if any exist.
typeset -a config_modules
config_modules=("$ZSH_CONFIG_DIR/lib/"*.zsh(N))

if (( ${#config_modules} == 0 )); then
    echo "⚠️  Warning: No Zsh configuration modules found in $ZSH_CONFIG_DIR/lib/"
    echo "    Please check your ZSH_CONFIG_DIR setting."
else
    for config_module in "${config_modules[@]}"; do
        source "$config_module"
    done
fi

# ++++++++++++++++++++++++++ EXTERNAL SCRIPTS ++++++++++++++++++++++++++++++++ #

# Load Competitive Programming tools.
[[ -f "$HOME/.config/cpp-tools/competitive.sh" ]] \
    && source "$HOME/.config/cpp-tools/competitive.sh"

# Load custom ZSH scripts from ~/.config/zsh/scripts/.
# The (N) glob qualifier suppresses errors if no files match.
if [[ -d "$ZSH_CONFIG_DIR/scripts" ]]; then
    () {
        setopt localoptions noxtrace noverbose
        local script
        for script in "$ZSH_CONFIG_DIR/scripts"/*.sh(N); do
            [[ -r "$script" ]] && source "$script"
        done
    }
fi

# ============================================================================ #
# +++++++++++++++++++++++++++ MODULE DOCUMENTATION +++++++++++++++++++++++++++ #
# ============================================================================ #
#
# 00-init.zsh:
#   Base shell configuration, safety settings, color definitions, and platform
#   detection. Provides foundational variables used by other modules.
#
# 10-history.zsh:
#   Shell history configuration with advanced features for command recall,
#   deduplication, and history sharing across sessions.
#
# 20-omz.zsh:
#   Oh-My-Zsh framework initialization with platform-aware plugin management.
#   Provides syntax highlighting, autosuggestions, and utility plugins.
#
# 30-prompt.zsh:
#   Multi-tier prompt system with automatic fallback cascade. Supports
#   Starship (preferred), Oh-My-Posh, PowerLevel10k, and minimal fallback.
#
# 40-vi-mode.zsh:
#   Vi mode configuration with cursor shape changes and custom keybindings.
#   Provides vim-like editing experience in the command line.
#
# 50-tools.zsh:
#   Integration of modern command-line tools with lazy-loading for performance.
#   Includes Atuin, Yazi, Ghostty, fzf (with Tokyo Night theme), zoxide, direnv.
#
# 60-aliases.zsh:
#   Cross-platform aliases and utility functions organized by category:
#   navigation, development tools, compilation shortcuts, git, productivity,
#   and platform-specific utilities.
#
# 70-fabric.zsh:
#   Fabric AI integration with Obsidian note-taking workflow. Provides pattern
#   aliases, YouTube transcript extraction, and automatic markdown file creation.
#
# 75-variables.zsh:
#   Environment variables and configuration for development tools, build systems,
#   and project-specific paths. Platform-aware exports for macOS and Linux.
#
# 80-languages.zsh:
#   Initialization of programming language version managers and runtime
#   environments. Includes static managers (Nix, Homebrew, Haskell, OCaml) and
#   dynamic managers (SDKMAN, pyenv, conda, rbenv, fnm).
#
# 85-completions.zsh:
#   Shell completion initialization for various tools (Docker, ngrok, Angular).
#   Loads late to ensure all PATH modifications are complete.
#
# 90-path.zsh:
#   Final PATH assembly and cleanup. Rebuilds PATH in deterministic order with
#   version manager shims at top priority. Removes duplicates and orphaned paths.
#
# ============================================================================ #
# End of ~/.zshrc
