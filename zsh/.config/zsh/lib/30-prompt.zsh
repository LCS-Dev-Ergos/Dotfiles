#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#            ██████╗ ██████╗  ██████╗ ███╗   ███╗██████╗ ████████╗
#            ██╔══██╗██╔══██╗██╔═══██╗████╗ ████║██╔══██╗╚══██╔══╝
#            ██████╔╝██████╔╝██║   ██║██╔████╔██║██████╔╝   ██║
#            ██╔═══╝ ██╔══██╗██║   ██║██║╚██╔╝██║██╔═══╝    ██║
#            ██║     ██║  ██║╚██████╔╝██║ ╚═╝ ██║██║        ██║
#            ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚═╝        ╚═╝
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
#   - Transient prompt support (Starship) using Powerlevel10k technique.
#   - Consistent newline spacing between prompts.
#   - Ctrl+C handling.
#   - Platform-aware initialization.
#
# Implementation based on:
#   - https://gist.github.com/subnut/3af65306fbecd35fe2dda81f59acf2b2
#   - https://github.com/romkatv/powerlevel10k/issues/888
#
# ============================================================================ #

# On HyDE: this file is loaded only when "HYDE_ZSH_PROMPT!=1" (user wants lib/ prompt)
# The guard below is a safety net for direct sourcing.
if [[ "$HYDE_ENABLED" == "1" ]] && [[ "${HYDE_ZSH_PROMPT}" == "1" ]]; then
    # HyDE's shell.zsh handles prompt instead
    return 0
fi

# Enable prompt substitution globally.
setopt PROMPT_SUBST

# ++++++++++++++++++++++++++++++++ STARSHIP +++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _init_starship_prompt
# -----------------------------------------------------------------------------
# Initialize Starship prompt with transient prompt feature.
#
# The transient prompt technique uses zle -F with a file descriptor to schedule
# prompt restoration. This is the same approach used by Powerlevel10k.
#
# Flow:
#   1. User presses Enter -> zle-line-finish fires.
#   2. Apply transient prompt, open fd to /dev/null, register zle -F callback.
#   3. Command executes.
#   4. zle -F callback fires (fd is readable), restores full prompt.
#   5. precmd runs, prompt is already correct.
#
# Returns:
#   0 - Success.
#   1 - Starship not available or initialization failed.
# -----------------------------------------------------------------------------
_init_starship_prompt() {
  # Require /dev/null and zsh/system module.
  [[ -c /dev/null ]] || return 1
  zmodload zsh/system || return 1

  setopt PROMPT_SUBST

  # Initialize Starship.
  eval "$(starship init zsh)"
  if [[ -z "$PROMPT" ]]; then
    print "Warning: Starship failed to initialize" >&2
    return 1
  fi

  # ------------------------- Configuration Variables -------------------------
  # File descriptor for async callback (0 = not active).
  typeset -gi _tp_fd=0

  # Newline variable: empty on first prompt, "\n" after first command.
  # Embedded in PROMPT for dynamic spacing.
  typeset -g _tp_newline=

  # Master switch for transient prompt (1=enabled, 0=disabled).
  typeset -gi _tp_enabled=1

  # Transient prompt string (minimal version shown for past commands).
  # Format: truncated path + green chevron.
  typeset -g _tp_transient='%B%F{cyan}%(4~|…/%2~|%~)%f%b %B%F{green}❯%f%b '

  # Store original prompts from Starship.
  typeset -g _tp_prompt_orig="$PROMPT"
  typeset -g _tp_rprompt_orig="$RPROMPT"

  # --------------------------- Build Final Prompt ----------------------------
  # Wrap original prompt with dynamic newline prefix.
  # The $_tp_newline variable controls spacing between prompts.
  _tp_set_prompt() {
    PROMPT='${_tp_newline}'"${_tp_prompt_orig}"
    RPROMPT="${_tp_rprompt_orig}"
  }
  _tp_set_prompt

  # ------------------------- Widget: zle-line-finish -------------------------
  # Called when user presses Enter. Applies transient prompt and schedules
  # restoration via file descriptor callback.
  zle -N zle-line-finish _tp_zle_line_finish
  _tp_zle_line_finish() {
    # Skip if transient prompt is disabled.
    (( _tp_enabled )) || return 0

    # Skip if fd is already active (prevents double-trigger).
    (( _tp_fd )) && return 0

    # Open /dev/null and register callback. The fd becomes readable immediately,
    # so the callback fires on the next event loop iteration.
    sysopen -r -o cloexec -u _tp_fd /dev/null || return 0
    zle -F $_tp_fd _tp_restore_prompt

    # Apply transient prompt and refresh display.
    # zle check ensures we're in line editor context.
    if zle; then
      PROMPT="$_tp_transient"
      RPROMPT=
      zle reset-prompt
      zle -R
    fi
  }

  # --------------------------- Widget: send-break ----------------------------
  # Called on Ctrl+C. Apply transient prompt before breaking.
  zle -N send-break _tp_send_break
  _tp_send_break() {
    _tp_zle_line_finish
    zle .send-break
  }

  # -------------------------- Widget: clear-screen ---------------------------
  # Called on Ctrl+L. Reset newline state so next prompt has no leading space.
  zle -N clear-screen _tp_clear_screen
  _tp_clear_screen() {
    _tp_newline=
    zle .clear-screen
  }

  # ------------------------ Callback: Restore Prompt -------------------------
  # Called via zle -F when fd becomes readable (after command execution).
  # Restores the full Starship prompt.
  _tp_restore_prompt() {
    # Close and unregister fd.
    local fd=$1
    exec {fd}>&-
    zle -F $fd
    _tp_fd=0

    # Restore full prompt.
    _tp_set_prompt

    # Refresh if in line editor context.
    if zle; then
      zle reset-prompt
      zle -R
    fi
  }

  # ------------------------------ Preexec Hook -------------------------------
  # Detects screen-clearing commands and sets flag to skip newline.
  (( ${+preexec_functions} )) || typeset -ga preexec_functions
  # Avoid duplicate registrations when re-sourcing.
  preexec_functions=(${(@)preexec_functions:#_tp_preexec})
  preexec_functions+=(_tp_preexec)

  # Flag: 1 = skip newline on next precmd
  typeset -gi _tp_skip_newline=0

  _tp_preexec() {
    # Extract first word of command
    local cmd="${1%% *}"
    case "$cmd" in
      clear|cls|reset|c) _tp_skip_newline=1 ;;
    esac
  }

  # ------------------------------- Precmd Hook -------------------------------
  # Sets _tp_newline after first prompt, respecting clear commands.
  (( ${+precmd_functions} )) || typeset -ga precmd_functions
  (( ${#precmd_functions} )) || precmd_functions=(true)
  # Avoid duplicate registrations when re-sourcing.
  precmd_functions=(${(@)precmd_functions:#_tp_precmd})
  precmd_functions+=(_tp_precmd)

  # First precmd: don't set newline yet.
  _tp_precmd() {
    TRAPINT() {
      zle && _tp_zle_line_finish
      return $(( 128 + $1 ))
    }

    # After first run, redefine with newline logic.
    _tp_precmd() {
      TRAPINT() {
        zle && _tp_zle_line_finish
        return $(( 128 + $1 ))
      }

      if (( _tp_skip_newline )); then
        _tp_newline=
        _tp_skip_newline=0
      else
        _tp_newline=$'\n'
      fi
    }
  }

  # ----------------------------- Toggle Function -----------------------------
  # Widget to toggle transient prompt on/off.
  zle -N toggle-transient-prompt _tp_toggle
  _tp_toggle() {
    if (( _tp_enabled )); then
      _tp_enabled=0
      zle -M "Transient prompt: OFF"
    else
      _tp_enabled=1
      zle -M "Transient prompt: ON"
    fi
  }

  return 0
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

  # Priority 4: Minimal.
  print "Using minimal prompt" >&2
  _init_minimal_prompt
}

# ============================================================================ #
# End of 30-prompt.zsh
