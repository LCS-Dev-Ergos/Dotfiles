#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ VI MODE SETUP +++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Vi mode configuration with cursor shape changes and custom keybindings.
# Provides a vim-like editing experience in the command line.
#
# Features:
#   - Vi mode with minimal ESC key delay.
#   - Dynamic cursor shapes (block for normal, blinking for insert).
#   - Tmux-compatible cursor control.
#   - Custom widgets (copy cwd, navigation).
#   - Chainable widget system for compatibility.
#
# DECSCUSR (DEC Set Cursor Style) escape sequences:
#   \e[1 q  = blinking block
#   \e[2 q  = steady block
#   \e[3 q  = blinking underline
#   \e[4 q  = steady underline
#   \e[5 q  = blinking bar
#   \e[6 q  = steady bar
#
# Note: With tmux terminal-overrides (Ss/Se), cursor changes are tracked
# per-pane automatically. No DCS passthrough wrapping needed.
# Required in tmux.conf:
#   set -ga terminal-overrides '*:Ss=\E[%p1%d q:Se=\E[2 q'
#
# ============================================================================ #

# Enable vi mode with minimal delay for Escape key.
bindkey -v
export KEYTIMEOUT=1

# +++++++++++++++++++++++++++++++ Cursor Shape +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vi_set_cursor <shape>
# -----------------------------------------------------------------------------
# Set terminal cursor shape using DECSCUSR escape sequence.
#
# Arguments:
#   $1 - Cursor shape number (1-6, see table above)
#
# Note: VSCode's integrated terminal has limited cursor control support.
# We skip cursor changes in VSCode to avoid rendering issues.
# -----------------------------------------------------------------------------
_vi_set_cursor() {
  # Skip cursor changes in VSCode terminal.
  [[ -n "$VSCODE_INJECTION" ]] && return 0

  printf '\e[%d q' "$1"
}

# -----------------------------------------------------------------------------
# _vi_cursor_for_keymap
# -----------------------------------------------------------------------------
# Update cursor shape based on current vi keymap.
#
# Shapes:
#   vicmd (normal mode)      -> steady block (2).
#   viins (insert mode)      -> blinking block (1).
#   visual (visual mode)     -> steady underline (4).
#   viopp (operator pending) -> blinking underline (3).
# -----------------------------------------------------------------------------
_vi_cursor_for_keymap() {
  case "${KEYMAP:-viins}" in
    vicmd) _vi_set_cursor 2 ;;  # Normal: steady block.
    visual) _vi_set_cursor 4 ;; # Visual: steady underline.
    viopp) _vi_set_cursor 3 ;;  # Operator pending: blinking underline.
    *) _vi_set_cursor 1 ;;      # Insert: blinking block.
  esac
}

# +++++++++++++++++++++++++++++++ ZLE Widgets ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vi_line_init
# -----------------------------------------------------------------------------
# Initialize command line in insert mode with correct cursor.
# Called by zle-line-init widget when a new command line starts.
# -----------------------------------------------------------------------------
_vi_line_init() {
  zle -K viins
  _vi_cursor_for_keymap
}

# -----------------------------------------------------------------------------
# _vi_keymap_select
# -----------------------------------------------------------------------------
# Update cursor shape when vi mode changes (insert <-> normal).
# Called by zle-keymap-select widget on mode transitions.
#
# Chains to previous widget (e.g., Starship's) to preserve functionality.
# -----------------------------------------------------------------------------

# Capture existing widget before overwriting.
typeset -g _VI_PREV_KEYMAP_SELECT=
if [[ -n "${widgets["zle-keymap-select"]-}" ]]; then
  local prev="${widgets["zle-keymap-select"]#user:}"
  # Prevent self-reference loops.
  [[ "$prev" != "_vi_keymap_select" ]] && _VI_PREV_KEYMAP_SELECT="$prev"
fi

_vi_keymap_select() {
  # Chain to previous widget (if it exists).
  [[ -n "$_VI_PREV_KEYMAP_SELECT" ]] && "$_VI_PREV_KEYMAP_SELECT" "$@"
  _vi_cursor_for_keymap
}

# Register vi mode widgets.
zle -N zle-line-init _vi_line_init
zle -N zle-keymap-select _vi_keymap_select

# +++++++++++++++++++++++++++++++ Keybindings ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vi_copy_cwd
# -----------------------------------------------------------------------------
# Copy current working directory to system clipboard.
# Bound to Ctrl+O. Only available on macOS (requires pbcopy).
# -----------------------------------------------------------------------------
if command -v pbcopy >/dev/null 2>&1; then
  _vi_copy_cwd() {
    print -rn -- "$PWD" | pbcopy
    zle -M "Copied: $PWD"
  }
  zle -N _vi_copy_cwd
  bindkey '^O' _vi_copy_cwd
fi

#============================================================================= #
