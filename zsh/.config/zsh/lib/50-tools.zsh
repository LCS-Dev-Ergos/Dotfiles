#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ MODERN TOOLS & UTILITIES +++++++++++++++++++++++++ #
# ============================================================================ #
#
# Integration of modern command-line tools with lazy-loading for performance.
# These tools enhance shell productivity and user experience.
#
# Tools integrated:
#   - Atuin: Magical shell history with sync.
#   - Yazi: Terminal file manager with cd integration.
#   - Ghostty: Terminal emulator integration.
#   - fzf: Fuzzy finder with Tokyo Night theme.
#   - zoxide: Smart cd replacement.
#   - direnv: Directory-specific environment loading.
#
# Performance:
#   - Lazy loading for fzf, zoxide, direnv (first precmd hook).
#   - Immediate loading for Atuin and Yazi (lightweight).
#
# ============================================================================ #

# ++++++++++++++++++++++++++++++++++ ATUIN +++++++++++++++++++++++++++++++++++ #

# Initialize Atuin (Magical Shell History).
if command -v atuin >/dev/null 2>&1; then
    eval "$(atuin init zsh)"
fi

# +++++++++++++++++++++++++++++++++++ YAZI +++++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# y
# -----------------------------------------------------------------------------
# Wrapper function for yazi to change directory after execution.
# Yazi writes the final directory to a temp file which we read on exit.
#
# Usage:
#   y [directory]
# -----------------------------------------------------------------------------
function y() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
    yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd <"$tmp"
    [ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
    rm -f -- "$tmp"
}

# +++++++++++++++++++++++++++++++++ GHOSTTY ++++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _init_ghostty
# -----------------------------------------------------------------------------
# Initialize Ghostty shell integration and alias.
# Uses GHOSTTY_RESOURCES_DIR to source integration script if available.
# Creates a 'ghostty' alias to avoid adding the full path to PATH.
# -----------------------------------------------------------------------------
_init_ghostty() {
    # 1. Shell Integration (if running inside Ghostty)
    if [[ -n "${GHOSTTY_RESOURCES_DIR}" ]]; then
        if [[ -f "${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration" ]]; then
            source "${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration"
        fi
    fi

    # 2. Command Alias (available everywhere)
    # Allows running 'ghostty' without polluting PATH.
    if [[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
        alias ghostty="/Applications/Ghostty.app/Contents/MacOS/ghostty"
    fi
}
_init_ghostty

# ++++++++++++++++++++++++++++ LAZY-LOADED TOOLS +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _tools_lazy_init
# -----------------------------------------------------------------------------
# Lazy initialization for fzf, zoxide, and direnv to improve startup time.
# Runs once on first precmd hook, then removes itself.
#
# Initializes:
#   - fzf: Fuzzy finder shell integration.
#   - zoxide: Smarter cd command.
#   - direnv: Directory-specific environment loading.
#
# Returns:
#   0 - Tools initialized or already initialized.
# -----------------------------------------------------------------------------
_tools_lazy_init() {
    [[ -n "${_TOOLS_LAZY_INIT_DONE-}" ]] && return

    if command -v fzf >/dev/null 2>&1; then
        eval "$(fzf --zsh 2>/dev/null)" || echo "${C_YELLOW}Warning: fzf init failed.${C_RESET}"
    fi

    if command -v zoxide >/dev/null 2>&1; then
        eval "$(zoxide init zsh 2>/dev/null)" || echo "${C_YELLOW}Warning: zoxide init failed.${C_RESET}"
    fi

    if command -v direnv >/dev/null 2>&1; then
        eval "$(direnv hook zsh 2>/dev/null)" || echo "${C_YELLOW}Warning: direnv init failed.${C_RESET}"
    fi

    _TOOLS_LAZY_INIT_DONE=1
    add-zsh-hook -d precmd _tools_lazy_init 2>/dev/null
}
add-zsh-hook precmd _tools_lazy_init

# ++++++++++++++++++++++++++++ FZF CONFIGURATION +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _gen_fzf_default_opts
# -----------------------------------------------------------------------------
# Configure fzf color scheme (Tokyo Night theme).
# Sets FZF_DEFAULT_OPTS with consistent color palette for all fzf invocations.
# -----------------------------------------------------------------------------
_gen_fzf_default_opts() {
    # ---------- Setup FZF theme ---------- #
    # Scheme name: Tokyo Night

    local color00='#1a1b26' # background
    local color01='#16161e' # darker background
    local color02='#2f3549' # selection background
    local color03='#414868' # comments
    local color04='#787c99' # dark foreground
    local color05='#a9b1d6' # foreground
    local color06='#c0caf5' # light foreground
    local color07='#cfc9c2' # lighter foreground
    local color08='#f7768e' # red
    local color09='#ff9e64' # orange
    local color0A='#e0af68' # yellow
    local color0B='#9ece6a' # green
    local color0C='#2ac3de' # cyan
    local color0D='#7aa2f7' # blue
    local color0E='#bb9af7' # purple
    local color0F='#cfc9c2' # grey/white

    export FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS""\
 --color=bg+:$color01,bg:$color00,spinner:$color0C,hl:$color0D""\
 --color=fg:$color04,header:$color0D,info:$color0A,pointer:$color0C""\
 --color=marker:$color0C,fg+:$color06,prompt:$color0A,hl+:$color0D"
}

_gen_fzf_default_opts

# ------ Use fd instead of fzf ------- #
if command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"

    # Use fd (https://github.com/sharkdp/fd) for listing path candidates.
    _fzf_compgen_path() {
        fd --hidden --exclude .git . "$1"
    }

    # Use fd to generate the list for directory completion.
    _fzf_compgen_dir() {
        fd --type=d --hidden --exclude .git . "$1"
    }
fi

# Source fzf-git.sh only if it exists.
if [[ -f "$HOME/.config/fzf-git/fzf-git.sh" ]]; then
    source "$HOME/.config/fzf-git/fzf-git.sh"
else
    # Check common Arch path as a fallback.
    if [[ "$PLATFORM" == "Linux" && -f "/usr/share/fzf/fzf-git.sh" ]]; then
        source "/usr/share/fzf/fzf-git.sh"
    fi
fi

# FZF preview options (only if tools are available).
if command -v bat >/dev/null 2>&1; then
    export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :500 {}'"
fi

if command -v eza >/dev/null 2>&1; then
    export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"
fi

# Advanced customization of fzf options via _fzf_comprun function.
if command -v fzf >/dev/null 2>&1; then
    _fzf_comprun() {
        local cmd="$1"
        shift

        case "$cmd" in
        cd)
            if command -v eza >/dev/null 2>&1; then
                fzf --preview 'eza --tree --color=always {} | head -200' "$@"
            else
                fzf --preview 'ls -la {}' "$@"
            fi
            ;;
        export | unset) fzf --preview 'echo {}' "$@" ;;
        ssh) fzf --preview 'dig {}' "$@" ;;
        *)
            if command -v bat >/dev/null 2>&1; then
                fzf --preview "bat -n --color=always --line-range :500 {}" "$@"
            else
                fzf --preview 'cat {}' "$@"
            fi
            ;;
        esac
    }
fi

# --------- Bat (better cat) --------- #
export BAT_THEME=tokyonight_night

# ============================================================================ #
