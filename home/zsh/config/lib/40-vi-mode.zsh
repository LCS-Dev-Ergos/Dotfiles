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
#   - Vim text objects for quotes and brackets (ci", da(, yi{, ...).
#   - Home/End/Delete in every encoding terminals use.
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

# Enable vi mode with minimal delay for Escape key. KEYTIMEOUT is a shell
# parameter, not something child processes need, so it stays unexported.
bindkey -v
KEYTIMEOUT=1

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
# @description Copies $PWD to the system clipboard and shows a ZLE status
# message; bound to Ctrl+O. It goes through clipcopy
# (functions/omz-compatibility.zsh), which picks pbcopy, wl-copy, xclip, and
# so on, and falls back to pbcopy while that bundle is not loaded yet.
# @noargs
# -----------------------------------------------------------------------------
_vi_copy_cwd() {
  if (( $+functions[clipcopy] )); then
    print -rn -- "$PWD" | clipcopy
  elif (( $+commands[pbcopy] )); then
    print -rn -- "$PWD" | pbcopy
  else
    zle -M "No clipboard tool available"
    return 1
  fi
  zle -M "Copied: $PWD"
}
zle -N _vi_copy_cwd
bindkey '^O' _vi_copy_cwd

# -----------------------------------------------------------------------------
# Navigation keys, previously provided by OMZ key-bindings. terminfo's khome
# and kend are the application-keypad forms (ESC O H), which a terminal only
# sends while that mode is on, and nothing here turns it on: in normal mode
# Home and End arrive as ESC [ H / ESC [ F, or as ESC [ 1~ / ESC [ 4~ under
# tmux and the Linux console. Unbound, the leading Escape switched to normal
# mode and the rest of the sequence ran as vi commands, so Home deleted a
# character. Every form is bound in both keymaps.
# -----------------------------------------------------------------------------
() {
  local -a home_keys=("${terminfo[khome]-}" $'\e[H' $'\eOH' $'\e[1~' $'\e[7~')
  local -a end_keys=("${terminfo[kend]-}" $'\e[F' $'\eOF' $'\e[4~' $'\e[8~')
  local -a delete_keys=("${terminfo[kdch1]-}" $'\e[3~')
  local seq keymap
  for keymap in viins vicmd; do
    for seq in ${(u)home_keys:#}; do
      bindkey -M "$keymap" "$seq" beginning-of-line
    done
    for seq in ${(u)end_keys:#}; do
      bindkey -M "$keymap" "$seq" end-of-line
    done
  done
  for seq in ${(u)delete_keys:#}; do
    bindkey -M viins "$seq" delete-char
    bindkey -M vicmd "$seq" vi-delete-char
  done
}

[[ -n "${terminfo[kpp]-}" ]] && bindkey "${terminfo[kpp]}" up-line-or-history
[[ -n "${terminfo[knp]-}" ]] && bindkey "${terminfo[knp]}" down-line-or-history
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

# No multi-key "jk" escape: with KEYTIMEOUT=1 the second key must arrive
# within 10 ms, which only pasted text or key repeat can do. Escape itself is
# instant, which is the trade-off this module is built around.

# Word motion with Ctrl/Alt+arrows and Alt+b/f in both keymaps.
() {
  local seq
  for seq in $'\e[1;5D' $'\e[5D' $'\eb'; do
    bindkey -M viins "$seq" backward-word
    bindkey -M vicmd "$seq" backward-word
  done
  for seq in $'\e[1;5C' $'\e[5C' $'\ef'; do
    bindkey -M viins "$seq" forward-word
    bindkey -M vicmd "$seq" forward-word
  done
}

autoload -Uz edit-command-line
zle -N edit-command-line
bindkey -M vicmd 'v' edit-command-line

# Vim text objects for quotes and brackets: ci", da(, yi{, vib, and so on,
# from the widgets zsh ships. They live in the operator-pending and visual
# keymaps, where `a` and `i` are never bound on their own, so the second key
# has no KEYTIMEOUT race (unlike multi-key sequences in vicmd).
autoload -Uz select-bracketed select-quoted
zle -N select-bracketed
zle -N select-quoted
() {
  local keymap c
  for keymap in viopp visual; do
    for c in {a,i}{\',\",\`}; do
      bindkey -M "$keymap" -- "$c" select-quoted
    done
    for c in {a,i}${(s..)^:-'()[]{}<>bB'}; do
      bindkey -M "$keymap" -- "$c" select-bracketed
    done
  done
}

# ============================================================================ #
# End of lib/40-vi-mode.zsh
