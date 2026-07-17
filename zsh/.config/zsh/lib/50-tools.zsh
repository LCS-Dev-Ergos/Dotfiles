#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#                 ████████╗ ██████╗  ██████╗ ██╗     ███████╗
#                 ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝
#                    ██║   ██║   ██║██║   ██║██║     ███████╗
#                    ██║   ██║   ██║██║   ██║██║     ╚════██║
#                    ██║   ╚██████╔╝╚██████╔╝███████╗███████║
#                    ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
# ============================================================================ #
# +++++++++++++++++++++++++ MODERN TOOLS & UTILITIES +++++++++++++++++++++++++ #
# ============================================================================ #
#
# Integration of modern command-line tools with lazy-loading for performance.
# These tools enhance shell productivity and user experience.
#
# Tools integrated:
#   - Atuin, fzf, zoxide, and direnv (deferred initialization).
#   - Yazi and Kitty file/session helpers.
#   - OrbStack, man-page tooling, and tldr/man dispatch through `hlp`.
#
# Performance:
#   - Deferred loading for atuin, fzf, zoxide, direnv.
#   - Immediate loading only for lightweight shell wrappers.
#
# ============================================================================ #

# ++++++++++++++++++++++++++++++++++ ATUIN +++++++++++++++++++++++++++++++++++ #

# Initialize Atuin (Magical Shell History).
if command -v atuin >/dev/null 2>&1; then
  _atuin_lazy_init() {
    [[ -n "${_ATUIN_INIT_DONE:-}" ]] && return 0
    _ATUIN_INIT_DONE=1
    eval "$(atuin init zsh)" || echo "${C_YELLOW}Warning: atuin init failed.${C_RESET}"
    unfunction _atuin_lazy_init 2>/dev/null
  }

  if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
    : # skip during fast start.
  elif typeset -f _zsh_defer >/dev/null 2>&1; then
    _zsh_defer _atuin_lazy_init
  else
    add-zsh-hook precmd _atuin_lazy_init
  fi
fi

# +++++++++++++++++++++++++++++++++++ YAZI +++++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# y
# -----------------------------------------------------------------------------
# @description Runs yazi and changes to its selected directory on exit.
# @arg $@ path Optional yazi directory and options.
# -----------------------------------------------------------------------------
function y() {
  local tmp cwd
  tmp="$(mktemp -t "yazi-cwd.XXXXXX")" || return 1
  {
    yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd <"$tmp"
    [[ -n "$cwd" && "$cwd" != "$PWD" ]] && builtin cd -- "$cwd"
  } always {
    rm -f -- "$tmp"
  }
}

# ++++++++++++++++++++++++++++ LAZY-LOADED TOOLS +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _tools_lazy_init
# @internal
# @description Initializes fzf, zoxide, and direnv shell integration on first
# precmd, then removes its own hook.
# @noargs
# -----------------------------------------------------------------------------
_tools_lazy_init() {
  # Remove hook before running to avoid re-entry races.
  add-zsh-hook -d precmd _tools_lazy_init

  if command -v fzf >/dev/null 2>&1; then
    eval "$(fzf --zsh 2>/dev/null)" || echo "${C_YELLOW}Warning: fzf init failed.${C_RESET}"
  fi

  if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh 2>/dev/null)" || echo "${C_YELLOW}Warning: zoxide init failed.${C_RESET}"
  fi

  if command -v direnv >/dev/null 2>&1; then
    eval "$(direnv hook zsh 2>/dev/null)" || echo "${C_YELLOW}Warning: direnv init failed.${C_RESET}"
  fi

  # Self-destruct after first run.
  unfunction _tools_lazy_init 2>/dev/null
}

if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
  : # skip during fast start.
elif typeset -f _zsh_defer >/dev/null 2>&1; then
  _zsh_defer _tools_lazy_init
else
  add-zsh-hook precmd _tools_lazy_init
fi

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

  local color_opts="\
 --color=bg+:$color01,bg:$color00,spinner:$color0C,hl:$color0D\
 --color=fg:$color04,header:$color0D,info:$color0A,pointer:$color0C\
 --color=marker:$color0C,fg+:$color06,prompt:$color0A,hl+:$color0D"

  # Strip any previous color opts to avoid accumulation on re-source.
  export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS//${~color_opts}/}${color_opts}"
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

# Source fzf-git.sh (deferred by default to improve startup time).
_fzf_git_source() {
  if [[ -f "$HOME/.config/fzf-git/fzf-git.sh" ]]; then
    source "$HOME/.config/fzf-git/fzf-git.sh"
    unfunction _fzf_git_source 2>/dev/null
    return
  fi
  if [[ "$PLATFORM" == "Linux" && -f "/usr/share/fzf/fzf-git.sh" ]]; then
    source "/usr/share/fzf/fzf-git.sh"
    unfunction _fzf_git_source 2>/dev/null
  fi
}

if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
  : # skip during fast start.
elif [[ "${ZSH_DEFER_FZF_GIT:-1}" == "1" ]] && typeset -f _zsh_defer >/dev/null 2>&1; then
  _zsh_defer _fzf_git_source
else
  _fzf_git_source
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

# ++++++++++++++++++++++++++++++++ MAN PAGES +++++++++++++++++++++++++++++++++ #

# Colored man pages: bat > most > less with ANSI colors.
if command -v bat >/dev/null 2>&1; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
  export MANROFFOPT="-c"
elif command -v most >/dev/null 2>&1; then
  export MANPAGER="most"
else
  export LESS_TERMCAP_mb=$'\e[1;32m'
  export LESS_TERMCAP_md=$'\e[1;34m'
  export LESS_TERMCAP_me=$'\e[0m'
  export LESS_TERMCAP_se=$'\e[0m'
  export LESS_TERMCAP_so=$'\e[1;33m'
  export LESS_TERMCAP_ue=$'\e[0m'
  export LESS_TERMCAP_us=$'\e[1;4;35m'
fi

# -----------------------------------------------------------------------------
# hlp
# @description Shows concise tldr examples, falling back to a man page.
# @arg $@ string Command or topic plus optional arguments.
# @exitcode 1 If no help tool is available or lookup fails.
# -----------------------------------------------------------------------------
hlp() {
  if (( $# == 0 )); then
    echo "Usage: hlp <command>" >&2
    return 1
  fi

  local cmd="$1"
  shift

  # Try tldr first for concise examples; if it fails, fall back to man.
  if command -v tldr >/dev/null 2>&1 && tldr "$cmd" "$@" 2>/dev/null; then
    return 0
  fi

  if command -v man >/dev/null 2>&1; then
    man "$cmd" "$@"
    return $?
  fi

  echo "Neither tldr nor man available for: $cmd" >&2
  return 1
}

# `h` is the colorized help function from functions/cli-tools.zsh. Keep `hlp`
# as the tldr/man dispatcher without shadowing that function.

# +++++++++++++++++++++++++++++++ YABAI TOOLS ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------#
# yabai_windows_table
# -----------------------------------------------------------------------------#
# @description Prints yabai windows across spaces and displays.
# Uses jq for structured extraction and the shared Gum/native table renderer.
# @noargs
# @exitcode 1 If yabai is unavailable or its query fails.
# -----------------------------------------------------------------------------#
yabai_windows_table() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1

  if ! command -v yabai >/dev/null 2>&1; then
    _zsh_ui_log error "yabai not found in PATH."
    return 1
  fi

  local json
  json="$(command yabai -m query --windows 2>/dev/null)" || {
    _zsh_ui_log error "Failed to query yabai windows."
    return 1
  }

  if [[ -z "$json" ]]; then
    _zsh_ui_log info "No windows reported by yabai."
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local table_data window_count
    window_count="$(print -r -- "$json" | command jq -er \
      'if type == "array" then length else error("expected an array") end' \
      2>/dev/null)" || {
      _zsh_ui_log error "jq could not parse the yabai response."
      return 1
    }
    if (( window_count == 0 )); then
      _zsh_ui_log info "No windows reported by yabai."
      return 0
    fi
    table_data="$(print -r -- "$json" | command jq -r \
      'sort_by(.display, .space, .app, .title)[] |
       [.display, .space, .app, .id, .title] | @tsv')" || {
      _zsh_ui_log error "jq could not parse the yabai response."
      return 1
    }
    local -a rows=("${(@f)table_data}")
    _zsh_ui_section "Yabai windows · $window_count"
    _zsh_ui_table \
      $'Display\tSpace\tApplication\tWindow ID\tTitle' "${rows[@]}"
    return $?
  fi

  _zsh_ui_log warn "jq is unavailable; printing raw yabai JSON."
  print -r -- "$json"
}

# +++++++++++++++++++++++++++++++++ GHOSTTY ++++++++++++++++++++++++++++++++++ #

# Command alias (only needed on macOS where app bundle isn't in PATH).
# On Linux, Ghostty is typically installed by the package manager.
if [[ "$PLATFORM" == "macOS" && -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
  alias ghostty="/Applications/Ghostty.app/Contents/MacOS/ghostty"
fi

# -----------------------------------------------------------------------------
# _init_ghostty
# -----------------------------------------------------------------------------
# Initialize Ghostty shell integration (cross-platform).
# Only runs when TERM indicates Ghostty (xterm-ghostty or ghostty).
# Uses GHOSTTY_RESOURCES_DIR to source integration script if available.
#
# Platforms:
#   - macOS: GHOSTTY_RESOURCES_DIR set by Ghostty.app.
#   - Linux: GHOSTTY_RESOURCES_DIR typically /usr/share/ghostty or similar.
# -----------------------------------------------------------------------------
if [[ "$TERM" == *ghostty* ]]; then
  _init_ghostty() {
    local integration_script=""

    # Try GHOSTTY_RESOURCES_DIR first (set by Ghostty itself).
    if [[ -n "${GHOSTTY_RESOURCES_DIR}" ]]; then
      integration_script="${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/ghostty-integration"
    # Fallback paths for Linux installations.
    elif [[ -f "/usr/share/ghostty/shell-integration/zsh/ghostty-integration" ]]; then
      integration_script="/usr/share/ghostty/shell-integration/zsh/ghostty-integration"
    elif [[ -f "/usr/local/share/ghostty/shell-integration/zsh/ghostty-integration" ]]; then
      integration_script="/usr/local/share/ghostty/shell-integration/zsh/ghostty-integration"
    fi

    [[ -f "$integration_script" ]] && source "$integration_script"
  }
  _init_ghostty
  unfunction _init_ghostty 2>/dev/null
fi

# +++++++++++++++++++++++++++++++++ ORBSTACK +++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------#
# _orbstack_init
# -----------------------------------------------------------------------------#
# Initialize OrbStack shell integration (deferred by default).
# This keeps startup fast while still enabling features when idle.
# -----------------------------------------------------------------------------#
_orbstack_init() {
  [[ -n "${_ORBSTACK_INIT_DONE:-}" ]] && return 0
  _ORBSTACK_INIT_DONE=1
  source "$HOME/.orbstack/shell/init.zsh" 2>/dev/null || :
  unfunction _orbstack_init 2>/dev/null
}

if [[ -f "$HOME/.orbstack/shell/init.zsh" ]]; then
  if [[ "${ZSH_FAST_START:-}" == "1" ]]; then
    : # skip during fast start.
  elif [[ "${ZSH_DEFER_ORBSTACK:-1}" == "1" ]]; then
    _zsh_defer _orbstack_init
  else
    _orbstack_init
  fi
fi

# ++++++++++++++++++++++++++++++++++ KITTY +++++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# kitty_save_session
# -----------------------------------------------------------------------------
# @description Saves the current Kitty windows and tabs as a session file.
# @arg $1 string Optional session name; defaults to a timestamp.
# KITTY_SAVE_DIR and KITTY_LISTEN_ON override the save directory and socket.
# @exitcode 1 If Kitty or its remote-control socket is unavailable.
# -----------------------------------------------------------------------------
kitty_save_session() {
  if ! command -v kitty >/dev/null 2>&1; then
    echo "kitty not in PATH" >&2
    return 1
  fi

  # Prepare paths and names.
  local save_dir="${KITTY_SAVE_DIR:-$HOME/.kitty-saved}"
  local target="${KITTY_LISTEN_ON:-unix:/tmp/kitty}"
  local name="${1:-session-$(date +%Y%m%d-%H%M%S)}"
  local out_name="${name%.kitty-session}.kitty-session"
  local out_path="$save_dir/$out_name"

  mkdir -p -- "$save_dir" || return 1

  # Try quick readiness check; fall back to plain ls if option unsupported.
  if ! kitty @ --to "$target" --wait-for-ready 1 ls >/dev/null 2>&1 \
    && ! kitty @ --to "$target" ls >/dev/null 2>&1; then
    echo "kitty remote control not reachable at $target" >&2
    return 1
  fi

  # Save session via remote control.
  if ! kitty @ --to "$target" action save_as_session --save-only --base-dir "$save_dir" "$out_name"; then
    echo "failed to save kitty session" >&2
    return 1
  fi

  printf 'Saved kitty session to %s\n' "$out_path"
}

alias ksave='kitty_save_session'

# -----------------------------------------------------------------------------
# kitty_restore_session
# -----------------------------------------------------------------------------
# @description Restores a saved Kitty session in the current or a new instance.
# @arg $1 string Optional session name; otherwise selects with fzf or newest.
# @exitcode 1 If the session directory, file, or Kitty control is unavailable.
# -----------------------------------------------------------------------------
kitty_restore_session() {
  if ! command -v kitty >/dev/null 2>&1; then
    echo "kitty not in PATH" >&2
    return 1
  fi

  local save_dir="${KITTY_SAVE_DIR:-$HOME/.kitty-saved}"
  local target_file=""

  # Check save dir exists.
  if [[ ! -d "$save_dir" ]]; then
    echo "No kitty session dir found at $save_dir" >&2
    return 1
  fi

  # Determine target session file.
  if [[ -n "${1:-}" ]]; then
    target_file="$save_dir/${1%.kitty-session}.kitty-session"
  elif command -v fzf >/dev/null 2>&1; then
    target_file="$(find "$save_dir" -maxdepth 1 -type f -name '*.kitty-session' 2>/dev/null \
      | fzf --prompt='kitty sessions> ' --tac)"
    [[ -z "$target_file" ]] && return 1  # user cancelled
  else
    target_file="$(ls -1t "$save_dir"/*.kitty-session 2>/dev/null | head -n 1)"
  fi

  # Validate target file.
  if [[ -z "$target_file" ]]; then
    echo "No kitty session found in $save_dir" >&2
    return 1
  fi
  if [[ ! -f "$target_file" ]]; then
    echo "Session file not found: $target_file" >&2
    return 1
  fi

  local target="${KITTY_LISTEN_ON:-unix:/tmp/kitty}"
  if kitty @ --to "$target" --wait-for-ready 1 ls >/dev/null 2>&1 \
     || kitty @ --to "$target" ls >/dev/null 2>&1; then
    # Switch session inside the running instance.
    if ! kitty @ --to "$target" action goto_session "$target_file"; then
      echo "Failed to switch session via goto_session" >&2
      return 1
    fi
  else
    # Fallback: spawn new instance with the session.
    kitty --session "$target_file" >/dev/null 2>&1 &
    disown
  fi
}

alias krest='kitty_restore_session'

# -----------------------------------------------------------------------------
# kget
# -----------------------------------------------------------------------------
# @description Downloads files through Kitty's compressed transfer protocol.
# @arg $@ path Remote files and optional local destination.
# Requires an SSH session on the remote host.
# @exitcode 1 If not in SSH or no files are supplied.
# -----------------------------------------------------------------------------
kget() {
  if [[ -z "${SSH_CONNECTION:-}" ]]; then
    echo "Not in an SSH session (run this from the remote host)" >&2
    return 1
  fi
  if (( $# == 0 )); then
    echo "Usage: kget <remote-file>... [local-destination]" >&2
    return 1
  fi

  local -a args=("$@")
  local last="${args[-1]}"

  # Auto-add trailing slash for directory destinations.
  # Multiple files or a last argument without an extension imply a directory.
  if (( $# > 1 )) && [[ "$last" != */ ]]; then
    local basename="${last:t}"
    # No dot in basename = likely a directory, not a file.
    if [[ "$basename" != *.* ]] || (( $# > 2 )); then
      args[-1]="${last}/"
    fi
  fi

  kitten transfer --compress=auto "${args[@]}"
}

# -----------------------------------------------------------------------------
# kput
# -----------------------------------------------------------------------------
# @description Uploads files through Kitty's compressed transfer protocol.
# With no arguments, uses fzf to select files when available.
# @arg $@ path Local files and optional remote destination.
# Requires an SSH session on the remote host.
# @exitcode 1 If not in SSH, selection is cancelled, or transfer fails.
# -----------------------------------------------------------------------------
kput() {
  if [[ -z "${SSH_CONNECTION:-}" ]]; then
    echo "Not in an SSH session (run this from the remote host)" >&2
    return 1
  fi

  local -a files
  if (( $# == 0 )); then
    if command -v fzf >/dev/null 2>&1; then
      local selection
      if command -v fd >/dev/null 2>&1; then
        selection="$(fd --type f --hidden --exclude .git | fzf --multi --prompt='upload> ')"
      else
        selection="$(find . -type f -not -path '*/.*' 2>/dev/null | fzf --multi --prompt='upload> ')"
      fi
      [[ -z "$selection" ]] && return 1
      files=("${(@f)selection}")
    else
      echo "Usage: kput <local-file>... [remote-destination]" >&2
      return 1
    fi
  else
    files=("$@")
  fi

  kitten transfer --direction=upload --compress=auto "${files[@]}"
}

# ============================================================================ #
# End of lib/50-tools.zsh
