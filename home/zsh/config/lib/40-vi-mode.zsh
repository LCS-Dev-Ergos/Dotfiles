#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#             ██╗   ██╗██╗    ███╗   ███╗ ██████╗ ██████╗ ███████╗
#             ██║   ██║██║    ████╗ ████║██╔═══██╗██╔══██╗██╔════╝
#             ██║   ██║██║    ██╔████╔██║██║   ██║██║  ██║█████╗
#             ╚██╗ ██╔╝██║    ██║╚██╔╝██║██║   ██║██║  ██║██╔══╝
#              ╚████╔╝ ██║    ██║ ╚═╝ ██║╚██████╔╝██████╔╝███████╗
#               ╚═══╝  ╚═╝    ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝
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

# +++++++++++++++++++++++++++++++ CURSOR SHAPE +++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vi_set_cursor
# @internal
# @description Sets the terminal cursor shape via a DECSCUSR escape sequence;
# skipped in VS Code's integrated terminal, which has limited cursor support.
# @arg $1 integer Cursor shape number (1-6; see the table above).
# -----------------------------------------------------------------------------
if [[ -n "$VSCODE_INJECTION" ]]; then
  _vi_set_cursor() { :; }
else
  _vi_set_cursor() {
    printf '\e[%d q' "$1"
  }
fi

# -----------------------------------------------------------------------------
# _vi_cursor_for_keymap
# @internal
# @description Sets the terminal cursor shape for the current vi keymap:
# steady block (vicmd), blinking block (viins), steady underline (visual), or
# blinking underline (viopp).
# @noargs
# -----------------------------------------------------------------------------
_vi_cursor_for_keymap() {
  case "${KEYMAP:-viins}" in
    vicmd) _vi_set_cursor 2 ;;  # Normal: steady block.
    visual) _vi_set_cursor 4 ;; # Visual: steady underline.
    viopp) _vi_set_cursor 3 ;;  # Operator pending: blinking underline.
    *) _vi_set_cursor 1 ;;      # Insert: blinking block.
  esac
}

# +++++++++++++++++++++++++++++++ ZLE WIDGETS ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vi_line_init
# @internal
# @description Resets to insert mode and syncs the cursor shape; bound to the
# zle-line-init widget when a new command line starts.
# @noargs
# -----------------------------------------------------------------------------
_vi_line_init() {
  zle -K viins
  _vi_cursor_for_keymap
}

# Capture the existing zle-keymap-select widget (e.g., Starship's) before
# overwriting it on reload, so _vi_keymap_select can chain to it below.
typeset -g _VI_PREV_KEYMAP_SELECT=
typeset -gi _VI_IN_KEYMAP=0

() {
  local keyName="zle-keymap-select"
  # Check if a previous zle-keymap-select widget exists.
  if [[ -n "${widgets[$keyName]-}" ]]; then
    typeset prev="${widgets[$keyName]#user:}"
    # Prevent self-reference loops.
    [[ "$prev" != "_vi_keymap_select" ]] && _VI_PREV_KEYMAP_SELECT="$prev"
  fi
}

# -----------------------------------------------------------------------------
# _vi_keymap_select
# @internal
# @description Updates the cursor shape on vi keymap transitions and chains to
# whatever zle-keymap-select widget (e.g. Starship's) was previously bound,
# guarding against self-reentrant recursion.
# @noargs
# -----------------------------------------------------------------------------
_vi_keymap_select() {
  # Prevent recursion when prev chains back into us.
  if ((_VI_IN_KEYMAP)); then
    _vi_cursor_for_keymap
    return
  fi

  _VI_IN_KEYMAP=1
  # Chain to previous widget (if it exists).
  [[ -n "$_VI_PREV_KEYMAP_SELECT" ]] && "$_VI_PREV_KEYMAP_SELECT" "$@"
  _VI_IN_KEYMAP=0

  _vi_cursor_for_keymap
}

# Register vi mode widgets.
zle -N zle-line-init _vi_line_init
zle -N zle-keymap-select _vi_keymap_select

# +++++++++++++++++++++++++++++++ KEYBINDINGS ++++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vi_copy_cwd
# @internal
# @description Copies $PWD to the system clipboard via pbcopy and shows a ZLE
# status message; bound to Ctrl+O. Only defined when pbcopy is available
# (macOS).
# @noargs
# -----------------------------------------------------------------------------
if command -v pbcopy >/dev/null 2>&1; then
  _vi_copy_cwd() {
    print -rn -- "$PWD" | pbcopy
    zle -M "Copied: $PWD"
  }
  zle -N _vi_copy_cwd
  bindkey '^O' _vi_copy_cwd
fi

# -----------------------------------------------------------------------------
# Terminal keybindings previously provided by OMZ key-bindings.
# -----------------------------------------------------------------------------
[[ -n "${terminfo[khome]-}" ]] && {
  bindkey -M viins "${terminfo[khome]}" beginning-of-line
  bindkey -M vicmd "${terminfo[khome]}" beginning-of-line
}

[[ -n "${terminfo[kend]-}" ]] && {
  bindkey -M viins "${terminfo[kend]}" end-of-line
  bindkey -M vicmd "${terminfo[kend]}" end-of-line
}

[[ -n "${terminfo[kpp]-}" ]] && bindkey "${terminfo[kpp]}" up-line-or-history
[[ -n "${terminfo[knp]-}" ]] && bindkey "${terminfo[knp]}" down-line-or-history
[[ -n "${terminfo[kdch1]-}" ]] && bindkey -M viins "${terminfo[kdch1]}" delete-char
[[ -n "${terminfo[kcbt]-}" ]] && bindkey "${terminfo[kcbt]}" reverse-menu-complete

bindkey -M viins '^?' backward-delete-char
bindkey -M viins '^[^?' backward-kill-word

# Emacs-style line editing restored for insert mode.
bindkey -M viins '^W' backward-kill-word
bindkey -M viins '^U' backward-kill-line
bindkey -M viins '^K' kill-line
bindkey -M viins '^A' beginning-of-line
bindkey -M viins '^E' end-of-line

# History navigation in insert mode.
bindkey -M viins '^P' up-line-or-history
bindkey -M viins '^N' down-line-or-history
bindkey -M viins '^R' history-incremental-search-backward

# Text manipulation.
bindkey -M viins '^T' transpose-chars
bindkey -M viins '^Y' yank

# Quick escape: "jk" in insert mode switches to normal mode.
bindkey -M viins 'jk' vi-cmd-mode

for seq in $'\e[1;5D' $'\e[5D' $'\eb'; do
  bindkey -M viins "$seq" backward-word
  bindkey -M vicmd "$seq" backward-word
done
for seq in $'\e[1;5C' $'\e[5C' $'\ef'; do
  bindkey -M viins "$seq" forward-word
  bindkey -M vicmd "$seq" forward-word
done

autoload -Uz edit-command-line
zle -N edit-command-line
bindkey -M vicmd 'v' edit-command-line

# ============================================================================ #
# End of lib/40-vi-mode.zsh
