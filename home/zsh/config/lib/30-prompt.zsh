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

typeset -f _zsh_cache_is_fresh >/dev/null 2>&1 ||
  source "${${(%):-%N}:A:h:h}/runtime-helpers.zsh"

# On HyDE, load this file only when HYDE_ZSH_PROMPT is not 1.
# The guard below is a safety net for direct sourcing.
if [[ "$HYDE_ENABLED" == "1" ]] && [[ "${HYDE_ZSH_PROMPT}" == "1" ]]; then
    # HyDE's shell.zsh handles prompt instead
    return 0
fi

# Enable prompt substitution globally.
setopt PROMPT_SUBST

# ++++++++++++++++++++++++++++++++ STARSHIP +++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _zsh_load_starship_init
# @internal
# @description Loads cached Starship init code when it belongs to the selected
# executable, otherwise regenerates and atomically replaces the cache.
# @arg $1 path Absolute path to the selected Starship executable.
# @exitcode 1 If Starship initialization or cache evaluation fails.
# -----------------------------------------------------------------------------
_zsh_load_starship_init() {
  local starship_bin="$1"
  [[ -n "$starship_bin" && -x "$starship_bin" ]] || return 1

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
  local cache_file="$cache_dir/starship-init.zsh"
  local cache_header="# starship-bin: $starship_bin"
  local cached_header=""
  if _zsh_cache_is_fresh "$cache_file"; then
    IFS= read -r cached_header < "$cache_file"
  fi

  if [[ "$cached_header" == "$cache_header" &&
        "$cache_file" -nt "$starship_bin" ]]; then
    source "$cache_file"
    return $?
  fi

  local init_code
  init_code="$("$starship_bin" init zsh)" || {
    print "Warning: Starship init failed" >&2
    return 1
  }
  eval "$init_code" || return 1
  {
    print -r -- "$cache_header"
    print -r -- "$init_code"
  } | _zsh_cache_put "$cache_file" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _init_starship_prompt
# @internal
# @description Initializes Starship with the transient-prompt technique (same
# as Powerlevel10k): on Enter, apply the transient prompt and open a zle -F
# callback on /dev/null; once the fd is readable after the command runs, the
# callback restores the full prompt before precmd fires.
# @noargs
# @exitcode 1 If Starship is unavailable or initialization fails.
# -----------------------------------------------------------------------------
_init_starship_prompt() {
  # Require /dev/null and zsh/system module.
  [[ -c /dev/null ]] || return 1
  zmodload zsh/system || return 1

  setopt PROMPT_SUBST

  local starship_bin="${commands[starship]-}"
  _zsh_load_starship_init "$starship_bin" || return 1

  if [[ -z "$PROMPT" ]]; then
    print "Warning: Starship failed to initialize" >&2
    return 1
  fi

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

  # ---------------------------------------------------------------------------
  # _tp_set_prompt
  # @internal
  # @description Rebuilds PROMPT/RPROMPT from the saved Starship prompt plus
  # the dynamic newline prefix in $_tp_newline.
  # @noargs
  # ---------------------------------------------------------------------------
  _tp_set_prompt() {
    PROMPT='${_tp_newline}'"${_tp_prompt_orig}"
    RPROMPT="${_tp_rprompt_orig}"
  }
  _tp_set_prompt

  # ---------------------------------------------------------------------------
  # _tp_zle_line_finish
  # @internal
  # @description Switches to the transient prompt when a command line is
  # accepted, then schedules _tp_restore_prompt via a one-shot file
  # descriptor callback so the full prompt returns before the next command.
  # @noargs
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # _tp_send_break
  # @internal
  # @description Applies the transient prompt before handling Ctrl+C.
  # @noargs
  # ---------------------------------------------------------------------------
  zle -N send-break _tp_send_break
  _tp_send_break() {
    _tp_zle_line_finish
    zle .send-break
  }

  # ---------------------------------------------------------------------------
  # _tp_clear_screen
  # @internal
  # @description Resets the newline-prefix state on Ctrl+L so the next prompt
  # starts without a leading blank line.
  # @noargs
  # ---------------------------------------------------------------------------
  zle -N clear-screen _tp_clear_screen
  _tp_clear_screen() {
    _tp_newline=
    zle .clear-screen
  }

  # ---------------------------------------------------------------------------
  # _tp_restore_prompt
  # @internal
  # @description Closes the one-shot file descriptor and restores the full
  # Starship prompt after a command finishes.
  # @arg $1 integer File descriptor passed by the zle -F callback.
  # ---------------------------------------------------------------------------
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

  # ------------------------------ PREEXEC HOOK -------------------------------
  # Detects screen-clearing commands and sets flag to skip newline.
  (( ${+preexec_functions} )) || typeset -ga preexec_functions
  # Avoid duplicate registrations when re-sourcing.
  preexec_functions=(${(@)preexec_functions:#_tp_preexec})
  preexec_functions+=(_tp_preexec)

  # Flag: 1 = skip newline on next precmd
  typeset -gi _tp_skip_newline=0

  # ---------------------------------------------------------------------------
  # _tp_preexec
  # @internal
  # @description Flags screen-clearing commands (clear/cls/reset/c) so the
  # next precmd skips the newline prefix.
  # @arg $1 string Command line about to execute.
  # ---------------------------------------------------------------------------
  _tp_preexec() {
    # Extract first word of command
    local cmd="${1%% *}"
    case "$cmd" in
      clear|cls|reset|c) _tp_skip_newline=1 ;;
    esac
  }

  # ------------------------------- PRECMD HOOK -------------------------------
  # Sets _tp_newline after first prompt, respecting clear commands.
  (( ${+precmd_functions} )) || typeset -ga precmd_functions
  (( ${#precmd_functions} )) || precmd_functions=(true)
  # Avoid duplicate registrations when re-sourcing.
  precmd_functions=(${(@)precmd_functions:#_tp_precmd})
  precmd_functions+=(_tp_precmd)

  # ---------------------------------------------------------------------------
  # _tp_precmd
  # @internal
  # @description Sets _tp_newline before each prompt. On its first call it
  # redefines itself (and TRAPINT) so the very first prompt skips the leading
  # newline, while later calls apply the normal skip-on-clear newline logic.
  # @noargs
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # _tp_toggle
  # @internal
  # @description Widget that toggles the transient prompt on/off.
  # @noargs
  # ---------------------------------------------------------------------------
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
# @internal
# @description Initializes Oh-My-Posh as a fallback prompt using the config at
# $XDG_CONFIG_HOME/oh-my-posh/lcs-dev.omp.json.
# @noargs
# @exitcode 1 If the config file is missing or initialization fails.
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
# @internal
# @description Initializes Powerlevel10k as a Linux fallback prompt, searching
# common theme install locations and sourcing ~/.p10k.zsh when present.
# @noargs
# @exitcode 1 If no Powerlevel10k theme file is found or loadable.
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
# @internal
# @description Sets a minimal fallback PROMPT/RPROMPT (user@host:path, dimmed
# clock) when no other prompt system is available.
# @noargs
# -----------------------------------------------------------------------------
_init_minimal_prompt() {
  setopt PROMPT_SUBST
  PROMPT='%F{cyan}%n@%m%f:%F{yellow}%~%f %(?.%F{green}.%F{red})%#%f '
  RPROMPT='%F{240}%D{%H:%M:%S}%f'
}

# ++++++++++++++++++++++++++ PROMPT INITIALIZATION +++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _zsh_init_prompt_system
# @internal
# @description Activates the first available prompt after PATH normalization.
# @noargs
# -----------------------------------------------------------------------------
_zsh_init_prompt_system() {
  # Priority 1: Starship.
  if (( $+commands[starship] )); then
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
# End of lib/30-prompt.zsh
