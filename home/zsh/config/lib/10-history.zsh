#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#            ██╗  ██╗██╗███████╗████████╗ ██████╗ ██████╗ ██╗   ██╗
#            ██║  ██║██║██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗╚██╗ ██╔╝
#            ███████║██║███████╗   ██║   ██║   ██║██████╔╝ ╚████╔╝
#            ██╔══██║██║╚════██║   ██║   ██║   ██║██╔══██╗  ╚██╔╝
#            ██║  ██║██║███████║   ██║   ╚██████╔╝██║  ██║   ██║
#            ╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝   ╚═╝
# ============================================================================ #
# ++++++++++++++++++++++++++ HISTORY CONFIGURATION +++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Shell history configuration with advanced features for command recall,
# deduplication, and history sharing across sessions.
#
# Features:
#   - 20K commands kept on disk, with room in memory for duplicate expiry.
#   - Timestamp and duration recording.
#   - Automatic deduplication.
#   - History expansion support.
#   - Shared history across concurrent sessions.
#
# ============================================================================ #

# Definitions for history file and sizes.
HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"

# History can hold secrets typed on the command line. Tighten the mode only
# when it is actually loose, so the common path costs a stat instead of a
# chmod fork on every startup.
() {
  local -a mode
  zmodload -F zsh/stat b:zstat 2>/dev/null &&
    zstat -L -A mode +mode -- "$HISTFILE" 2>/dev/null || return 0
  (( mode[1] & 8#077 )) && command chmod 600 -- "$HISTFILE" 2>/dev/null
  return 0
}

# Zsh only searches, deduplicates and rewrites what it holds in memory, so
# the file never keeps more than HISTSIZE entries. HIST_EXPIRE_DUPS_FIRST
# needs HISTSIZE above SAVEHIST to have duplicates to drop before unique
# commands; the gap is that headroom. Raising both grows the history read
# at every startup; Atuin keeps the long-term, searchable archive.
HISTSIZE=25000
SAVEHIST=20000
setopt BANG_HIST        # support !-style history expansion.
setopt EXTENDED_HISTORY # record timestamp/duration.
setopt HIST_VERIFY      # show before executing history expansions.
setopt HIST_EXPIRE_DUPS_FIRST HIST_IGNORE_DUPS HIST_IGNORE_SPACE
setopt HIST_NO_FUNCTIONS
# SHARE_HISTORY already appends every command as it runs; the manual asks for
# INC_APPEND_HISTORY to stay off alongside it.
setopt SHARE_HISTORY

# Report background job status immediately.
set -o notify

# ============================================================================ #
# End of lib/10-history.zsh
