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

# ================================== ATUIN =================================== #

# Initialize Atuin (Magical Shell History).
if command -v atuin >/dev/null 2>&1; then
  eval "$(atuin init zsh)"
fi

# =================================== YAZI =================================== #

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

# ============================ LAZY-LOADED TOOLS ============================= #

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
add-zsh-hook precmd _tools_lazy_init

# ============================ FZF CONFIGURATION ============================= #

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
elif [[ "${ZSH_DEFER_FZF_GIT:-1}" == "1" ]]; then
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

# ================================ YABAI TOOLS =============================== #

# -----------------------------------------------------------------------------#
# yabai_windows_table
# -----------------------------------------------------------------------------#
# Print a table of all windows across spaces/displays using yabai metadata.
# Tries Nushell for nice formatting, falls back to jq, then raw JSON.
# -----------------------------------------------------------------------------#
yabai_windows_table() {
  if ! command -v yabai >/dev/null 2>&1; then
    echo "yabai not found in PATH" >&2
    return 1
  fi

  local json
  json="$(yabai -m query --windows 2>/dev/null)" || {
    echo "failed to query yabai windows" >&2
    return 1
  }

  if [[ -z "$json" ]]; then
    echo "no windows reported by yabai"
    return 0
  fi

  if command -v nu >/dev/null 2>&1; then
    # Nushell pretty table.
    printf '%s\n' "$json" | nu --stdin -c '
      from json
      | select display space app title id
      | sort-by display space app title
      | table -w 160
    '
    return $?
  fi

  if command -v jq >/dev/null 2>&1; then
    printf "%-7s %-7s %-30s %-14s %s\n" "display" "space" "app" "window_id" "title"
    echo "$json" | jq -r '.[] | [.display, .space, .app, .id, .title] | @tsv' |
    while IFS=$'\t' read -r d s a i t; do
      printf "%-7s %-7s %-30s %-14s %s\n" "$d" "$s" "$a" "$i" "$t"
    done
    return 0
  fi

  # Last resort: raw JSON
  echo "$json"
}

# ================================= GHOSTTY ================================== #

# Command alias (only needed on macOS where app bundle isn't in PATH).
# On Linux (Arch), ghostty is typically installed via package manager and already in PATH.
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

# =============================== ORBSTACK =================================== #

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

# ================================== KITTY =================================== #

# -----------------------------------------------------------------------------
# kitty_save_session
# -----------------------------------------------------------------------------
# Save the current kitty instance (all windows/tabs) into ~/.kitty-saved by
# calling kitty's built-in remote-control action `save_as_session`. Behaves
# like a simple “resurrect”: run inside kitty, then later start kitty with
# `kitty --session ~/.kitty-saved/<name>.kitty-session`.
#
# Usage:
#   kitty_save_session [name]   # default: session-YYYYMMDD-HHMMSS
#
# Env vars:
#   KITTY_SAVE_DIR   Directory to store sessions (default: ~/.kitty-saved)
#   KITTY_LISTEN_ON  Remote control socket (default: unix:/tmp/kitty)
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
# Restore a saved kitty session. Prefers switching the current kitty instance
# via the goto_session action; if no RC socket is reachable, falls back to
# launching a new kitty process with --session.
#
# Usage:
#   kitty_restore_session [name]   # default: newest file in save dir
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

# ============================================================================ #
