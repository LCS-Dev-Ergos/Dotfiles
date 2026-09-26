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
# This file is loaded by .zshrc ONLY when HYDE_ENABLED=1 (Arch Linux) and
# HYDE_ZSH_NO_PLUGINS is not 1, in the slot of lib/20-zinit.zsh.
#
# Responsibilities:
#   1. Initialize Oh-My-Zsh with HyDE's plugin set.
#   2. Initialize HyDE's prompt when HYDE_ZSH_PROMPT=1.
#   3. Completion paths and compinit.
#   4. HyDE package-manager aliases and rendering helpers.
#
# .zshrc loads the user preferences (user.zsh) before this file and the
# function bundles after all modules, as it does without HyDE. ZDOTDIR is
# $HOME (see .zshenv), so paths into this tree go through ZSH_CONFIG_DIR.
# The file is sourced at top level (Oh-My-Zsh must be), so its temporaries
# carry a _hyde_ prefix and are unset again.
#
# ============================================================================ #

# Prerequisite check.
if [[ "$HYDE_ENABLED" != "1" ]]; then
  return 1
fi

typeset _hyde_cfg="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}"

# HyDE default settings (can be overridden in user.zsh).
: ${HYDE_ZSH_NO_PLUGINS:=0}
: ${HYDE_ZSH_PROMPT:=1}
: ${HYDE_ZSH_COMPINIT_CHECK:=24}

ZSH_AUTOSUGGEST_STRATEGY=(history completion)

# History settings are owned by lib/10-history.zsh, which is sourced before
# this file. Setting HISTFILE/HISTSIZE/SAVEHIST here would clobber them.

# Completion directories go in before anything runs compinit, and the dump
# joins the other caches instead of landing in $HOME.
_zsh_fpath_prepend "$_hyde_cfg/completions" "$HOME/.docker/completions"
export ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/.zcompdump"

# ++++++++++++++++ 1. OH-MY-ZSH INITIALIZATION (Conditional) +++++++++++++++++ #

if [[ "${HYDE_ZSH_NO_PLUGINS}" != "1" ]]; then
  # Find Oh-My-Zsh installation.
  typeset _hyde_omz
  for _hyde_omz in /usr/share/oh-my-zsh /usr/local/share/oh-my-zsh \
      "$HOME/.oh-my-zsh"; do
    if [[ -d "$_hyde_omz" ]]; then
      export ZSH="$_hyde_omz"
      break
    fi
  done
  unset _hyde_omz

  if [[ -n "$ZSH" ]]; then
    # Set ZSH_CUSTOM for Arch Linux custom plugins.
    # Check if ZSH_CUSTOM has a valid plugins directory, otherwise use system-wide.
    if [[ -z "${ZSH_CUSTOM:-}" ]] || [[ ! -d "$ZSH_CUSTOM/plugins" ]]; then
      if [[ -d "/usr/share/oh-my-zsh/custom" ]]; then
        export ZSH_CUSTOM="/usr/share/oh-my-zsh/custom"
      fi
    fi
    # The system-wide installation is read-only; keep Oh-My-Zsh's own cache
    # (generated completions, update stamps) in the user's cache directory.
    : ${ZSH_CACHE_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-zsh}

    # HyDE default plugins merged with the user's (from user.zsh), deduplicated.
    plugins=(${plugins[@]} git zsh-256color zsh-autosuggestions zsh-syntax-highlighting)
    plugins=(${(u)plugins[@]})

    # Load Oh-My-Zsh; it runs compinit with ZSH_COMPDUMP.
    [[ -f "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

    # Start autosuggestions if available.
    if (( $+functions[_zsh_autosuggest_start] )); then
      _zsh_autosuggest_start
    fi
  fi
fi

# ++++++++++++++++++ 2. PROMPT INITIALIZATION (Conditional) ++++++++++++++++++ #

if [[ "${HYDE_ZSH_PROMPT}" == "1" ]]; then
  if (( $+commands[starship] )); then
    # Starship prompt.
    export STARSHIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/starship"
    export STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship/starship.toml"
    _zsh_cached_init starship-hyde "${commands[starship]}" init zsh ||
      print -u2 "Warning: Starship init failed"
  elif [[ -r "$HOME/.p10k.zsh" ]]; then
    # PowerLevel10k fallback.
    typeset _hyde_p10k="/usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme"
    if [[ -r "$_hyde_p10k" ]]; then
      source "$_hyde_p10k"
      source "$HOME/.p10k.zsh"
    fi
    unset _hyde_p10k
  fi
fi

# ++++++++++++++++++++++++++++++ 3. COMPLETIONS ++++++++++++++++++++++++++++++ #

# Custom completion scripts.
typeset _hyde_file
for _hyde_file in "$_hyde_cfg"/completions/*.zsh(N); do
  [[ -r "$_hyde_file" ]] && source "$_hyde_file"
done
unset _hyde_file

# Oh-My-Zsh has run compinit already; without it, rebuild the dump only when
# it is older than HYDE_ZSH_COMPINIT_CHECK hours.
if (( ! ${+_comps} )); then
  autoload -Uz compinit
  () {
    setopt localoptions extendedglob
    if [[ ! -f "$ZSH_COMPDUMP" ||
          -n $ZSH_COMPDUMP(#qN.mh+${HYDE_ZSH_COMPINIT_CHECK:-24}) ]]; then
      compinit -d "$ZSH_COMPDUMP"
    else
      compinit -C -d "$ZSH_COMPDUMP"
    fi
  }
fi

_comp_options+=(globdots)  # Tab complete hidden files.

# +++++++++++++++++++++++++ 4. HYDE-SPECIFIC ALIASES +++++++++++++++++++++++++ #

# HyDE Package Manager wrapper. The upgrade alias is `upg`, not HyDE's `up`,
# which would shadow the `up` directory function (functions/core.zsh).
if (( $+commands[hyde-shell] )); then
  __hyde_package_manager() {
    hyde-shell pm "$@"
  }
  alias in='__hyde_package_manager install'
  alias un='__hyde_package_manager remove'
  alias upg='__hyde_package_manager upgrade'
fi

# ++++++++++++++++++++++ 5. TERMINAL RENDERING HELPERS +++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# do_render
# @description Checks whether the terminal supports a rendering type. The
# terminal is detected on the first call and remembered, so startup pays for
# no `ps` call.
# @arg $1 string "image" (default) or "art".
# @exitcode 1 If the terminal does not support the rendering type.
# -----------------------------------------------------------------------------
do_render() {
  local type="${1:-image}"
  local -a terminal_image_support=(kitty konsole ghostty WezTerm)
  local -a terminal_no_art=(vscode code codium)

  if (( ! ${+_HYDE_CURRENT_TERMINAL} )); then
    typeset -g _HYDE_CURRENT_TERMINAL="${TERM_PROGRAM:-}"
    [[ -n "$_HYDE_CURRENT_TERMINAL" ]] ||
      _HYDE_CURRENT_TERMINAL="$(command ps -o comm= -p "$PPID" 2>/dev/null)"
  fi

  case "${type}" in
    image)
      (( ${terminal_image_support[(Ie)$_HYDE_CURRENT_TERMINAL]} ))
      ;;
    art)
      (( ! ${terminal_no_art[(Ie)$_HYDE_CURRENT_TERMINAL]} ))
      ;;
    *)
      return 1
      ;;
  esac
}

unset _hyde_cfg

# ============================================================================ #
# End of hyde/shell.zsh
