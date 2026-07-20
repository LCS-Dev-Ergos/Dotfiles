#!/usr/bin/env zsh
# ============================================================================ #
#! ██╗  ██╗██╗   ██╗██████╗ ███████╗    ███████╗██╗  ██╗███████╗██╗     ██╗
#! ██║  ██║╚██╗ ██╔╝██╔══██╗██╔════╝    ██╔════╝██║  ██║██╔════╝██║     ██║
#! ███████║ ╚████╔╝ ██║  ██║█████╗      ███████╗███████║█████╗  ██║     ██║
#! ██╔══██║  ╚██╔╝  ██║  ██║██╔══╝      ╚════██║██╔══██║██╔══╝  ██║     ██║
#! ██║  ██║   ██║   ██████╔╝███████╗    ███████║██║  ██║███████╗███████╗███████╗
#! ╚═╝  ╚═╝   ╚═╝   ╚═════╝ ╚══════╝    ╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝
# ============================================================================ #
# +++++++++++++++++++++++++ HyDE Shell Configuration +++++++++++++++++++++++++ #
# ============================================================================ #
#
# This file is loaded by .zshrc ONLY when HYDE_ENABLED=1 (Arch Linux).
# It consolidates functionality from the old terminal.zsh and prompt.zsh.
#
# Responsibilities:
#   1. Load user preferences (user.zsh) FIRST.
#   2. Initialize Oh-My-Zsh (if not disabled).
#   3. Initialize prompt system (if not disabled).
#   4. Load custom functions and completions.
#
# This replaces:
#   - terminal.zsh (complex, ~250 lines, caused duplications).
#   - prompt.zsh (now integrated here with conditional loading).
#
# ============================================================================ #

# Prerequisite check.
if [[ "$HYDE_ENABLED" != "1" ]]; then
  return 1
fi

# ============================================================================ #
# +++++++++++++++++++++++++++ 1. USER PREFERENCES ++++++++++++++++++++++++++++ #
# ============================================================================ #

# Load user customizations BEFORE any plugin/prompt initialization.
# This allows HYDE_ZSH_NO_PLUGINS and HYDE_ZSH_PROMPT to take effect.
if [[ -f "$HOME/.hyde.zshrc" ]]; then
  source "$HOME/.hyde.zshrc"
elif [[ -f "$HOME/.user.zsh" ]]; then
  source "$HOME/.user.zsh"
elif [[ -f "$ZDOTDIR/user.zsh" ]]; then
  source "$ZDOTDIR/user.zsh"
fi

# ============================================================================ #
# ++++++++++++++++ 2. OH-MY-ZSH INITIALIZATION (Conditional) +++++++++++++++++ #
# ============================================================================ #

# HyDE default settings (can be overridden in user.zsh).
: ${HYDE_ZSH_NO_PLUGINS:=0}
: ${HYDE_ZSH_PROMPT:=1}
: ${HYDE_ZSH_COMPINIT_CHECK:=24}

ZSH_AUTOSUGGEST_STRATEGY=(history completion)
export ZSH_AUTOSUGGEST_STRATEGY

# History settings are owned by $ZDOTDIR/lib/10-history.zsh which is sourced
# before this file in .zshrc. Setting HISTFILE/HISTSIZE/SAVEHIST here would
# clobber the larger limits configured there.

if [[ "${HYDE_ZSH_NO_PLUGINS}" != "1" ]]; then
  # Find Oh-My-Zsh installation.
  local -a zsh_paths=(
    "/usr/share/oh-my-zsh"
    "/usr/local/share/oh-my-zsh"
    "$HOME/.oh-my-zsh"
  )

  for zsh_path in "${zsh_paths[@]}"; do
    if [[ -d "$zsh_path" ]]; then
      export ZSH="$zsh_path"
      break
    fi
  done

  if [[ -n "$ZSH" ]]; then
    # Set ZSH_CUSTOM for Arch Linux custom plugins.
    # Check if ZSH_CUSTOM has a valid plugins directory, otherwise use system-wide.
    if [[ -z "${ZSH_CUSTOM:-}" ]] || [[ ! -d "$ZSH_CUSTOM/plugins" ]]; then
      if [[ -d "/usr/share/oh-my-zsh/custom" ]]; then
        export ZSH_CUSTOM="/usr/share/oh-my-zsh/custom"
      fi
    fi

    # HyDE default plugins.
    local -a hyde_plugins=(git zsh-256color zsh-autosuggestions zsh-syntax-highlighting)

    # Merge with user plugins (if any defined in user.zsh).
    plugins=(${plugins[@]} ${hyde_plugins[@]})

    # Deduplicate plugins using Zsh native unique.
    plugins=(${(u)plugins[@]})

    # Load Oh-My-Zsh.
    [[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

    # Start autosuggestions if available.
    if typeset -f _zsh_autosuggest_start >/dev/null; then
      _zsh_autosuggest_start
    fi
  fi
fi

# ============================================================================ #
# ++++++++++++++++++ 3. PROMPT INITIALIZATION (Conditional) ++++++++++++++++++ #
# ============================================================================ #

if [[ "${HYDE_ZSH_PROMPT}" == "1" ]]; then
  if command -v starship >/dev/null 2>&1; then
    # Starship prompt.
    eval "$(starship init zsh)"
    export STARSHIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/starship"
    export STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship/starship.toml"
  elif [[ -r "$HOME/.p10k.zsh" ]] || [[ -r "$ZDOTDIR/.p10k.zsh" ]]; then
    # PowerLevel10k fallback.
    local p10k_theme="/usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme"
    if [[ -r "$p10k_theme" ]]; then
      source "$p10k_theme"
      if [[ -f "$HOME/.p10k.zsh" ]]; then
        source "$HOME/.p10k.zsh"
      elif [[ -f "$ZDOTDIR/.p10k.zsh" ]]; then
        source "$ZDOTDIR/.p10k.zsh"
      fi
    fi
  fi
fi

# ============================================================================ #
# ++++++++++++++++++++++++ 4. FUNCTIONS & COMPLETIONS ++++++++++++++++++++++++ #
# ============================================================================ #

# Load custom functions.
for file in "$ZDOTDIR"/functions/*.zsh(N); do
  [[ -r "$file" ]] && source "$file"
done

# Load custom completions.
for file in "$ZDOTDIR"/completions/*.zsh(N); do
  [[ -r "$file" ]] && source "$file"
done

# ============================================================================ #
# +++++++++++++++++++++++++++++++ 5. COMPINIT ++++++++++++++++++++++++++++++++ #
# ============================================================================ #

# Add completions directory to fpath.
fpath=("$ZDOTDIR/completions" "${fpath[@]}")

autoload -Uz compinit
setopt EXTENDED_GLOB

# Only regenerate completion dump if older than HYDE_ZSH_COMPINIT_CHECK hours.
if [[ -n ${ZDOTDIR}/.zcompdump(#qN.mh+${HYDE_ZSH_COMPINIT_CHECK:-24}) ]]; then
  compinit
else
  compinit -C
fi

_comp_options+=(globdots)  # Tab complete hidden files.

# ============================================================================ #
# +++++++++++++++++++++++++ 6. HYDE-SPECIFIC ALIASES +++++++++++++++++++++++++ #
# ============================================================================ #

# HyDE Package Manager wrapper.
if command -v hyde-shell >/dev/null 2>&1; then
  __hyde_package_manager() {
    hyde-shell pm "$@"
  }
  alias in='__hyde_package_manager install'
  alias un='__hyde_package_manager remove'
  alias up='__hyde_package_manager upgrade'
fi

# ============================================================================ #
# ++++++++++++++++++++++ 7. TERMINAL RENDERING HELPERS +++++++++++++++++++++++ #
# ============================================================================ #

# Detect terminal once at shell start; do_render() is called often (potentially
# per-prompt), so the nested ps invocation gets cached here instead.
typeset -g _HYDE_CURRENT_TERMINAL="${TERM_PROGRAM:-}"
if [[ -z "$_HYDE_CURRENT_TERMINAL" ]]; then
  _HYDE_CURRENT_TERMINAL="$(ps -o comm= -p "$(ps -o ppid= -p $$ 2>/dev/null)" 2>/dev/null)"
fi

# Check if terminal supports specific rendering.
do_render() {
  local type="${1:-image}"
  local -a terminal_image_support=(kitty konsole ghostty WezTerm)
  local -a terminal_no_art=(vscode code codium)

  case "${type}" in
    image)
      [[ " ${terminal_image_support[*]} " =~ " ${_HYDE_CURRENT_TERMINAL} " ]]
      ;;
    art)
      [[ ! " ${terminal_no_art[*]} " =~ " ${_HYDE_CURRENT_TERMINAL} " ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# ============================================================================ #
