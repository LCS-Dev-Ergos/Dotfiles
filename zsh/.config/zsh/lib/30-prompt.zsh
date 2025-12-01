#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ PROMPT SYSTEM CONFIGURATION ++++++++++++++++++++++++ #
# ============================================================================ #
#
# Multi-tier prompt system with automatic fallback cascade:
#   1. Starship      - Modern, fast, cross-platform (preferred).
#   2. Oh-My-Posh    - macOS/Windows fallback.
#   3. PowerLevel10k - Linux fallback.
#   4. Minimal       - Basic fallback (always works).
#
# Features:
#   - Transient prompt support (Starship).
#   - Smart newline insertion.
#   - Vi mode indicators.
#   - Platform-aware initialization.
#
# ============================================================================ #

# Enable prompt substitution globally.
setopt PROMPT_SUBST

# ++++++++++++++++++++++++++++++++ STARSHIP +++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _init_starship_prompt
# -----------------------------------------------------------------------------
# Initialize Starship prompt with transient prompt and smart newline features:
#   - Transient prompt: Shows minimal prompt for previous commands.
#   - Smart newline: Adds visual separation between commands.
#
# Returns:
#   0 - Success.
#   1 - Starship not available or initialization failed.
# -----------------------------------------------------------------------------
_init_starship_prompt() {
    # Note: We allow re-initialization to support re-sourcing .zshrc.

    setopt PROMPT_SUBST
    autoload -Uz add-zsh-hook

    # Initialize Starship and verify.
    eval "$(starship init zsh)"
    if [[ -z "$PROMPT" ]]; then
        print "Warning: Starship failed to initialize" >&2
        return 1
    fi

    # --------------------------- State Management ----------------------------
    # Use a single global associative array to avoid namespace pollution.
    # Keys:
    #   init_done       : Flag to prevent re-init.
    #   need_newline    : Boolean (0/1), true if next prompt needs a spacer.
    #   first_prompt    : Boolean (0/1), true if this is the first prompt.
    #   transient_on    : Boolean (0/1), master switch for transient mode.
    #   last_cmd        : The last executed command string.
    #   prompt_full     : Stashed original PROMPT.
    #   rprompt_full    : Stashed original RPROMPT.
    #   prompt2_full    : Stashed original PROMPT2.
    # -------------------------------------------------------------------------
    typeset -gA _STARSHIP_STATE
    _STARSHIP_STATE[init_done]=1
    _STARSHIP_STATE[need_newline]=0
    _STARSHIP_STATE[first_prompt]=1

    # Default: Enabled (preserve if already set during reload).
    if [[ -z "${_STARSHIP_STATE[transient_on]-}" ]]; then
        _STARSHIP_STATE[transient_on]=1
    fi

    # Stash original prompts (Starship sets these once at init).
    _STARSHIP_STATE[prompt_full]="$PROMPT"
    _STARSHIP_STATE[rprompt_full]="$RPROMPT"
    _STARSHIP_STATE[prompt2_full]="${PROMPT2-}"

    # Minimal transient prompt: truncated path + chevron.
    # Format: %(4~|…/%3~|%~) = show "…/last/3/dirs" if depth > 4, else full path.
    typeset -g _STARSHIP_TRANSIENT_PROMPT='%B%F{purple}%(4~|…/%3~|%~)%f%b %B%F{green}❯%f%b '

    # ---------- Register Hooks ---------- #
    # preexec: Record command to decide on newlines.
    add-zsh-hook preexec _starship_record_cmd
    # precmd: Handle newlines and restore full prompt.
    add-zsh-hook precmd _starship_precmd

    # ------- Register ZLE Widgets ------- #
    # Wrap zle-line-finish to trigger transient effect on Enter.
    _starship_wrap_widget "zle-line-finish" "_starship_line_finish"

    # Wrap clear-screen to reset newline state.
    _starship_wrap_widget "clear-screen" "_starship_clear_screen"

    # Register custom widgets.
    zle -N toggle-transient-prompt _starship_toggle_transient
    zle -N reset-prompt-state _starship_reset_state

    # Optional: Bind toggle widget to Ctrl+T.
    # bindkey '^T' toggle-transient-prompt

    return 0
}

# +++++++++++++++++++++++++++++ Helper Functions +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _starship_wrap_widget <widget_name> <wrapper_function>
# -----------------------------------------------------------------------------
# Safely wraps a ZLE widget, preserving any existing user or builtin widget.
#
# Arguments:
#   $1 - Name of the widget to wrap (e.g., "zle-line-finish").
#   $2 - Name of the wrapper function.
# -----------------------------------------------------------------------------
_starship_wrap_widget() {
    local widget="$1"
    local wrapper="$2"

    # Save previous widget if it exists.
    if [[ -n "${widgets[$widget]-}" ]]; then
        local prev="${widgets[$widget]}"
        if [[ "$prev" == user:* ]]; then
            _STARSHIP_STATE[prev_$widget]="${prev#user:}"
        elif [[ "$prev" == builtin:* ]]; then
            _STARSHIP_STATE[prev_$widget]=".${prev#builtin:}"
        fi
    fi

    zle -N "$widget" "$wrapper"
}

# -----------------------------------------------------------------------------
# _starship_record_cmd <command>
# -----------------------------------------------------------------------------
# Hook: preexec
# Records the command being executed to determine if a newline is needed later.
# -----------------------------------------------------------------------------
_starship_record_cmd() {
    # Store command with leading whitespace trimmed.
    local cmd="${1#"${1%%[![:space:]]*}"}"
    _STARSHIP_STATE[last_cmd]="$cmd"
}

# -----------------------------------------------------------------------------
# _starship_precmd
# -----------------------------------------------------------------------------
# Hook: precmd
# 1. Handles "Smart Newline" logic (printing a spacer line).
# 2. Restores the full Starship prompt for the new command line.
# -----------------------------------------------------------------------------
_starship_precmd() {
    # 1. Smart Newline Logic
    if [[ -n "${_STARSHIP_STATE[first_prompt]}" ]]; then
        # First prompt after shell start: no newline.
        unset "_STARSHIP_STATE[first_prompt]"
        _STARSHIP_STATE[need_newline]=0
    elif (( _STARSHIP_STATE[need_newline] )); then
        # Print spacer line if requested.
        print ""
    fi

    # Reset state for next cycle.
    _STARSHIP_STATE[need_newline]=0

    # 2. Restore Full Prompt.
    PROMPT="${_STARSHIP_STATE[prompt_full]}"
    RPROMPT="${_STARSHIP_STATE[rprompt_full]}"
    PROMPT2="${_STARSHIP_STATE[prompt2_full]}"
}

# -----------------------------------------------------------------------------
# _starship_line_finish
# -----------------------------------------------------------------------------
# Widget: zle-line-finish
# Called when the user accepts a command line (presses Enter).
# 1. Determines if the *next* prompt needs a newline spacer.
# 2. Replaces the *current* prompt with the transient (minimal) version.
# -----------------------------------------------------------------------------
_starship_line_finish() {
    local cmd="${BUFFER:-}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}" # Trim leading whitespace

    # Determine if newline is needed for next prompt.
    if [[ -z "$cmd" ]]; then
        # Empty command: usually want a newline to separate blocks.
        _STARSHIP_STATE[need_newline]=1
    else
        case "$cmd" in
            # Commands that clear the screen shouldn't have a newline after.
            clear|clear\ *|cls|cls\ *|reset|reset\ *|c|c\ *)
                _STARSHIP_STATE[need_newline]=0
                ;;
            *)
                _STARSHIP_STATE[need_newline]=1
                ;;
        esac
    fi

    # Call previous widget if it existed (chaining).
    local prev="${_STARSHIP_STATE[prev_zle-line-finish]-}"
    if [[ -n "$prev" ]]; then
        "$prev" "$@"
    fi

    # Apply transient prompt ONLY if enabled.
    if (( _STARSHIP_STATE[transient_on] )); then
        PROMPT="$_STARSHIP_TRANSIENT_PROMPT"
        RPROMPT=
        zle .reset-prompt
    fi
}

# -----------------------------------------------------------------------------
# _starship_clear_screen
# -----------------------------------------------------------------------------
# Widget: clear-screen (Ctrl+L)
# Ensures that clearing the screen doesn't leave a "need newline" state.
# -----------------------------------------------------------------------------
_starship_clear_screen() {
    _STARSHIP_STATE[need_newline]=0

    local prev="${_STARSHIP_STATE[prev_clear-screen]-}"
    if [[ -n "$prev" ]]; then
        if [[ "$prev" == .* ]]; then
            zle "$prev"
        else
            "$prev" "$@"
        fi
    else
        zle .clear-screen
    fi
}

# -----------------------------------------------------------------------------
# _starship_toggle_transient
# -----------------------------------------------------------------------------
# Widget: toggle-transient-prompt
# Toggles the transient prompt behavior on/off.
# Usage: bindkey '^[t' toggle-transient-prompt
# -----------------------------------------------------------------------------
_starship_toggle_transient() {
    if (( _STARSHIP_STATE[transient_on] )); then
        _STARSHIP_STATE[transient_on]=0
        zle -M "Transient prompt: DISABLED"
    else
        _STARSHIP_STATE[transient_on]=1
        zle -M "Transient prompt: ENABLED"
    fi
}

# -----------------------------------------------------------------------------
# _starship_reset_state
# -----------------------------------------------------------------------------
# Function: reset-prompt-state
# Resets internal state in case of desync or glitches.
# -----------------------------------------------------------------------------
_starship_reset_state() {
    _STARSHIP_STATE[need_newline]=0
    _STARSHIP_STATE[first_prompt]=0
    _STARSHIP_STATE[transient_on]=1
    PROMPT="${_STARSHIP_STATE[prompt_full]}"
    RPROMPT="${_STARSHIP_STATE[rprompt_full]}"
    zle -M "Prompt state reset."
}

# ++++++++++++++++++++++++++++++++ OH-MY-POSH ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _init_ohmyposh_prompt
# -----------------------------------------------------------------------------
# Initialize Oh-My-Posh prompt as fallback for macOS/Windows.
#
# Expects config file at: $XDG_CONFIG_HOME/oh-my-posh/lcs-dev.omp.json
# -----------------------------------------------------------------------------
_init_ohmyposh_prompt() {
    local omp_config="${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-posh/lcs-dev.omp.json"

    if [[ ! -f "$omp_config" ]]; then
        print "Warning: Oh-My-Posh config not found at $omp_config" >&2
        return 1
    fi

    if ! eval "$(oh-my-posh init zsh --config "$omp_config")"; then
        print "Warning: Oh-My-Posh initialization failed" >&2
        return 1
    fi

    return 0
}

# ++++++++++++++++++++++++++++++ POWERLEVEL10K +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _init_p10k_prompt
# -----------------------------------------------------------------------------
# Initialize PowerLevel10k prompt as Linux fallback.
#
# Searches for theme in common locations:
#   - /usr/share/zsh-theme-powerlevel10k/
#   - ~/.oh-my-zsh/custom/themes/powerlevel10k/
#   - $ZDOTDIR/.oh-my-zsh/custom/themes/powerlevel10k/
# -----------------------------------------------------------------------------
_init_p10k_prompt() {
    local p10k_theme
    local p10k_config="$HOME/.p10k.zsh"
    local -a p10k_locations=(
        "/usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme"
        "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme"
        "${ZDOTDIR:-$HOME}/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme"
    )

    # Try loading PowerLevel10k from known locations.
    for p10k_theme in "${p10k_locations[@]}"; do
        if [[ -f "$p10k_theme" ]]; then
            if ! source "$p10k_theme"; then
                print "Warning: Failed to load PowerLevel10k from $p10k_theme" >&2
                continue
            fi
            [[ -f "$p10k_config" ]] && source "$p10k_config"
            return 0
        fi
    done

    return 1
}

# +++++++++++++++++++++++++++++++++ MINIMAL ++++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _init_minimal_prompt
# -----------------------------------------------------------------------------
# Initialize basic fallback prompt when no other prompt system is available.
#
# Format:
#   Left:  user@host:path #/$
#   Right: HH:MM:SS (dimmed)
#
# Exit code colors prompt symbol green (success) or red (failure).
# -----------------------------------------------------------------------------
_init_minimal_prompt() {
    setopt PROMPT_SUBST
    PROMPT='%F{cyan}%n@%m%f:%F{yellow}%~%f %(?.%F{green}.%F{red})%#%f '
    RPROMPT='%F{240}%D{%H:%M:%S}%f'
}

# ============================================================================ #
# ++++++++++++++++++++++++++ PROMPT INITIALIZATION +++++++++++++++++++++++++++ #
# ============================================================================ #

# Initialize prompt system in priority order.
# Wrapped in anonymous function for local scope.
() {
    # Priority 1: Starship.
    if command -v starship >/dev/null 2>&1; then
        _init_starship_prompt && return 0
        print "Starship init failed, trying fallback..." >&2
    fi

    # Priority 2: Oh-My-Posh.
    if command -v oh-my-posh >/dev/null 2>&1; then
        _init_ohmyposh_prompt && return 0
        print "Oh-My-Posh init failed, trying fallback..." >&2
    fi

    # Priority 3: PowerLevel10k.
    if _init_p10k_prompt; then
        return 0
    else
        [[ "${PLATFORM:-}" == "Linux" ]] && print "PowerLevel10k not found" >&2
    fi

    # Priority 4: Minimal (always succeeds).
    print "Using minimal prompt" >&2
    _init_minimal_prompt
}

# ============================================================================ #
