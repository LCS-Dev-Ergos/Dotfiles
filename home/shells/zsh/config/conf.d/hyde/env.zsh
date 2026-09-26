#!/usr/bin/env zsh
# ============================================================================ #
#!      ██╗  ██╗██╗   ██╗██████╗ ███████╗    ███████╗███╗   ██╗██╗   ██╗
#!      ██║  ██║╚██╗ ██╔╝██╔══██╗██╔════╝    ██╔════╝████╗  ██║██║   ██║
#!      ███████║ ╚████╔╝ ██║  ██║█████╗      █████╗  ██╔██╗ ██║██║   ██║
#!      ██╔══██║  ╚██╔╝  ██║  ██║██╔══╝      ██╔══╝  ██║╚██╗██║╚██╗ ██╔╝
#!      ██║  ██║   ██║   ██████╔╝███████╗    ███████╗██║ ╚████║ ╚████╔╝
#!      ╚═╝  ╚═╝   ╚═╝   ╚═════╝ ╚══════╝    ╚══════╝╚═╝  ╚═══╝  ╚═══╝
# ============================================================================ #

# Hyde's Shell Environment Initialization Script.
# If users used UWSM, uwsm will override any variables set anywhere in your
# shell configurations.

# User local bin first. Moving it instead of prepending keeps nested shells,
# which all source this file, from stacking duplicates.
path=("$HOME/.local/bin" "${(@)path:#$HOME/.local/bin}")

# XDG Base Directory Specification variables with defaults.
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_DATA_DIRS="${XDG_DATA_DIRS:-$XDG_DATA_HOME:/usr/local/share:/usr/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# XDG user directories, when xdg-user-dirs is installed. This file runs for
# every zsh, scripts included, so instead of eight `xdg-user-dir` calls (each a
# shell script sourcing the same file) it reads user-dirs.dirs once, with
# xdg-user-dir's own defaults: $HOME/Desktop for DESKTOP, $HOME otherwise.
if (( $+commands[xdg-user-dir] )); then
  () {
    setopt localoptions extendedglob
    local file="$XDG_CONFIG_HOME/user-dirs.dirs" line key var
    local -A dirs
    local -a match mbegin mend
    if [[ -r "$file" ]]; then
      while IFS= read -r line; do
        [[ "$line" == (#b)XDG_([A-Z]##)_DIR=\"(*)\" ]] || continue
        dirs[${match[1]}]="${match[2]/#\$HOME/$HOME}"
      done < "$file"
    fi
    for key in DESKTOP DOWNLOAD TEMPLATES PUBLICSHARE DOCUMENTS MUSIC \
        PICTURES VIDEOS; do
      var="XDG_${key}_DIR"
      [[ -n "${(P)var}" ]] && continue
      if [[ -n "${dirs[$key]-}" ]]; then
        typeset -g "$var=${dirs[$key]}"
      elif [[ "$key" == DESKTOP ]]; then
        typeset -g "$var=$HOME/Desktop"
      else
        typeset -g "$var=$HOME"
      fi
    done
  }
fi

# Less history in the user's state directory. A fixed name in the shared,
# world-writable /tmp let another local user read the search history or
# pre-create the file as a symlink.
LESSHISTFILE="${LESSHISTFILE:-$XDG_STATE_HOME/lesshst}"

# Application config files.
PARALLEL_HOME="$XDG_CONFIG_HOME/parallel"
SCREENRC="$XDG_CONFIG_HOME/screen/screenrc"
TERMINFO="$XDG_DATA_HOME"/terminfo
TERMINFO_DIRS="$XDG_DATA_HOME"/terminfo:/usr/share/terminfo
WGETRC="${XDG_CONFIG_HOME}/wgetrc"
PYTHON_HISTORY="$XDG_STATE_HOME/python_history"

# HyDEs Compositor Configuration.
export HYPRLAND_CONFIG="${XDG_DATA_HOME:-$HOME/.local/share}/hypr/hyprland.conf"

# Signal that HyDE environment is active.
# This flag is used by .zshrc to conditionally skip lib/20-zinit.zsh and lib/30-prompt.zsh
# when HyDE's shell.zsh handles OMZ and prompt initialization.
HYDE_ENABLED=1

# Export all variables.
export PATH \
  XDG_CONFIG_HOME XDG_DATA_HOME XDG_DATA_DIRS XDG_STATE_HOME XDG_CACHE_HOME \
  XDG_DESKTOP_DIR XDG_DOWNLOAD_DIR XDG_TEMPLATES_DIR XDG_PUBLICSHARE_DIR \
  XDG_DOCUMENTS_DIR XDG_MUSIC_DIR XDG_PICTURES_DIR XDG_VIDEOS_DIR \
  LESSHISTFILE PARALLEL_HOME SCREENRC HYDE_ENABLED

# ============================================================================ #
# End of hyde/env.zsh
