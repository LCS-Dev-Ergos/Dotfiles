#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#!             ██╗      ██████╗███████╗    ███████╗███████╗██╗  ██╗
#!             ██║     ██╔════╝██╔════╝    ╚══███╔╝██╔════╝██║  ██║
#!             ██║     ██║     ███████╗      ███╔╝ ███████╗███████║
#!             ██║     ██║     ╚════██║     ███╔╝  ╚════██║██╔══██║
#!             ███████╗╚██████╗███████║    ███████╗███████║██║  ██║
#!             ╚══════╝ ╚═════╝╚══════╝    ╚══════╝╚══════╝╚═╝  ╚═╝
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
# Consult the README.md for further details on the design philosophy,
# module breakdown, and usage tips.
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

# Debug: Uncomment to troubleshoot configuration directory detection.
# echo "ZSH_CONFIG_DIR=$ZSH_CONFIG_DIR"
# echo "HYDE_ENABLED=${HYDE_ENABLED:-not set}"

# -----------------------------------------------------------------------------
# Fast start toggle: skip heavy modules for a minimal, quick shell.
# Enable with: ZSH_FAST_START=1
# -----------------------------------------------------------------------------
if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
    source "$ZSH_CONFIG_DIR/lib/00-init.zsh"
    source "$ZSH_CONFIG_DIR/lib/10-history.zsh"
    source "$ZSH_CONFIG_DIR/lib/40-vi-mode.zsh"
    source "$ZSH_CONFIG_DIR/lib/60-aliases.zsh"
    source "$ZSH_CONFIG_DIR/lib/75-variables.zsh"
    source "$ZSH_CONFIG_DIR/lib/90-path.zsh"
    PROMPT='%F{cyan}%n@%m%f:%F{yellow}%~%f %(?.%F{green}.%F{red})%#%f '
    RPROMPT='%F{240}%D{%H:%M:%S}%f'
    return
fi

# ++++++++++++++++++++++++++++ LOAD CORE MODULES +++++++++++++++++++++++++++++ #

# Load modules in priority order.
# Note: Order is critical - Do not rearrange without understanding dependencies.

# On HyDE systems, load user preferences FIRST to determine which modules to use.
# This allows user.zsh to set HYDE_ZSH_NO_PLUGINS and HYDE_ZSH_PROMPT
if [[ "$HYDE_ENABLED" == "1" ]]; then
    # Load user preferences before deciding what to load.
    if [[ -f "$HOME/.hyde.zshrc" ]]; then
        source "$HOME/.hyde.zshrc"
    elif [[ -f "$HOME/.user.zsh" ]]; then
        source "$HOME/.user.zsh"
    elif [[ -f "$ZSH_CONFIG_DIR/user.zsh" ]]; then
        source "$ZSH_CONFIG_DIR/user.zsh"
    fi
fi

# Determine which modules to load based on platform/environment and user prefs.
typeset -a config_modules
typeset -ga _ZSH_HEAVY_FUNCTION_FILES=()

# -----------------------------------------------------------------------------
# Function file loader helpers
# -----------------------------------------------------------------------------
# Keep startup hot path small by deferring heavy helper bundles until the shell
# is idle after the first prompt.
_zsh_source_function_file() {
    local file="$1"
    if [[ -r "$file" ]]; then
        source "$file"
        return 0
    fi
    echo "Warning: Cannot read function file: $file"
    return 1
}

_zsh_queue_function_file() {
    local file="$1"
    case "${file:t}" in
        network.zsh | pdf.zsh | productivity.zsh)
            _ZSH_HEAVY_FUNCTION_FILES+=("$file")
            ;;
        *)
            _zsh_source_function_file "$file"
            ;;
    esac
}

_zsh_load_heavy_functions() {
    local file
    for file in "${_ZSH_HEAVY_FUNCTION_FILES[@]}"; do
        _zsh_source_function_file "$file"
    done
    _ZSH_HEAVY_FUNCTION_FILES=()
    unfunction _zsh_load_heavy_functions 2>/dev/null
}

_zsh_schedule_heavy_functions() {
    (( ${#_ZSH_HEAVY_FUNCTION_FILES[@]} )) || return 0
    if typeset -f _zsh_defer >/dev/null 2>&1; then
        _zsh_defer _zsh_load_heavy_functions
    else
        _zsh_load_heavy_functions
    fi
}

if [[ "$HYDE_ENABLED" == "1" ]]; then
    # -------------------------------------------------------------------------
    # +++++++++++++++++++++++++ ARCH LINUX with HyDE ++++++++++++++++++++++++++
    # -------------------------------------------------------------------------
    # Check user preferences to decide which system handles OMZ/prompt:
    #   - HYDE_ZSH_NO_PLUGINS=1 → use lib/20-zinit.zsh (user's config)
    #   - HYDE_ZSH_PROMPT=0     → use lib/30-prompt.zsh (user's config)

    # Load base modules first.
    source "$ZSH_CONFIG_DIR/lib/00-init.zsh"
    source "$ZSH_CONFIG_DIR/lib/10-history.zsh"

    # OMZ: user's lib/ or HyDE's shell.zsh?
    if [[ "${HYDE_ZSH_NO_PLUGINS}" == "1" ]]; then
        # User wants their own plugin manager config.
        source "$ZSH_CONFIG_DIR/lib/20-zinit.zsh"
    else
        # HyDE handles OMZ - load shell.zsh (partial, just OMZ part).
        [[ -f "$ZSH_CONFIG_DIR/conf.d/hyde/shell.zsh" ]] && \
            source "$ZSH_CONFIG_DIR/conf.d/hyde/shell.zsh"
    fi

    # Prompt: user's lib/ or HyDE's shell.zsh?
    if [[ "${HYDE_ZSH_PROMPT}" != "1" ]]; then
        # User wants their own prompt config (with transient prompt).
        source "$ZSH_CONFIG_DIR/lib/30-prompt.zsh"
    fi
    # If HYDE_ZSH_PROMPT=1, shell.zsh already loaded prompt.

    # Load remaining modules.
    source "$ZSH_CONFIG_DIR/lib/40-vi-mode.zsh"
    source "$ZSH_CONFIG_DIR/lib/50-tools.zsh"
    source "$ZSH_CONFIG_DIR/lib/60-aliases.zsh"
    source "$ZSH_CONFIG_DIR/lib/70-ai-tools.zsh"
    source "$ZSH_CONFIG_DIR/lib/75-variables.zsh"
    source "$ZSH_CONFIG_DIR/lib/80-languages.zsh"
    source "$ZSH_CONFIG_DIR/lib/85-completions.zsh"
    source "$ZSH_CONFIG_DIR/lib/90-path.zsh"
    [[ -f "$ZSH_CONFIG_DIR/lib/95-lazy-scripts.zsh" ]] && source "$ZSH_CONFIG_DIR/lib/95-lazy-scripts.zsh"
    [[ -f "$ZSH_CONFIG_DIR/lib/96-lazy-cpp-tools.zsh" ]] && source "$ZSH_CONFIG_DIR/lib/96-lazy-cpp-tools.zsh"

    # Load custom functions (shell.zsh only loads them when HYDE_ZSH_NO_PLUGINS!=1).
    if [[ "${HYDE_ZSH_NO_PLUGINS}" == "1" ]]; then
        for file in "$ZSH_CONFIG_DIR"/functions/*.zsh(N); do
            _zsh_queue_function_file "$file"
        done
        _zsh_schedule_heavy_functions
    fi
else
    # -------------------------------------------------------------------------
    # ++++++++++++++++++++++++ macOS or non-HyDE Linux ++++++++++++++++++++++++
    # -------------------------------------------------------------------------
    # Load ALL modules normally - no HyDE interference
    config_modules=("$ZSH_CONFIG_DIR/lib/"*.zsh(N))

    if (( ${#config_modules} == 0 )); then
        echo "Warning: No Zsh configuration modules found in $ZSH_CONFIG_DIR/lib/"
        echo "    Please check your ZSH_CONFIG_DIR setting."
    else
        for config_module in "${config_modules[@]}"; do
            source "$config_module"
        done
    fi

    # Load custom functions.
    typeset -a function_files
    function_files=("$ZSH_CONFIG_DIR"/functions/*.zsh(N))

    if (( ${#function_files} == 0 )); then
        echo "Warning: No function files found in $ZSH_CONFIG_DIR/functions/"
        echo "    ZSH_CONFIG_DIR=$ZSH_CONFIG_DIR"
        echo "    Please check if the functions directory exists and contains .zsh files."
    else
        for file in "${function_files[@]}"; do
            _zsh_queue_function_file "$file"
        done
        _zsh_schedule_heavy_functions
    fi
fi

# +++++++++++++++++++++++++++++ EXTERNAL SCRIPTS +++++++++++++++++++++++++++++ #

# Load Competitive Programming tools (eager load only if lazy disabled).
if [[ "${ZSH_LAZY_CPP_TOOLS:-1}" != "1" ]]; then
    [[ -f "$HOME/.config/cpp-tools/competitive.sh" ]] \
        && source "$HOME/.config/cpp-tools/competitive.sh"
fi

# Load custom ZSH scripts from ~/.config/zsh/scripts/.
# The (N) glob qualifier suppresses errors if no files match.
if [[ "${ZSH_LAZY_SCRIPTS:-1}" != "1" ]]; then
    if [[ -d "$ZSH_CONFIG_DIR/scripts" ]]; then
        () {
            setopt localoptions noxtrace noverbose
            local script
            for script in "$ZSH_CONFIG_DIR/scripts"/*.sh(N); do
                [[ -r "$script" ]] && source "$script"
            done
        }
    fi
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
# 20-zinit.zsh:
#   Zinit plugin initialization with platform-aware plugin management.
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
# 70-ai-tools.zsh:
#   Configuration for AI-powered tools and coding agents. Includes Fabric
#   (LLM patterns with Obsidian integration) and OpenCode (MCP-based assistant).
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
# 95-lazy-scripts.zsh:
#   Lazy loader for ~/.config/zsh/scripts (on-demand sourcing).
#
# 96-lazy-cpp-tools.zsh:
#   Lazy loader for ~/.config/cpp-tools/competitive.sh (on-demand sourcing).
#
# ============================================================================ #
# End of ~/.zshrc
