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
#   - Large history size (20K in memory, 50K saved).
#   - Timestamp and duration recording.
#   - Automatic deduplication.
#   - History expansion support.
#   - Shared history across concurrent sessions.
#
# ============================================================================ #

# Definitions for history file and sizes.
HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
[[ -f "$HISTFILE" ]] && chmod 600 "$HISTFILE" 2>/dev/null
# Keep the in-memory working set smaller than the on-disk archive. Duplicate
# expiry therefore prioritizes the most recent 20k commands while 50k remain
# searchable across sessions.
HISTSIZE=20000
SAVEHIST=50000
setopt BANG_HIST        # support !-style history expansion.
setopt EXTENDED_HISTORY # record timestamp/duration.
setopt HIST_VERIFY      # show before executing history expansions.
setopt HIST_EXPIRE_DUPS_FIRST HIST_IGNORE_DUPS HIST_IGNORE_SPACE
setopt HIST_NO_FUNCTIONS
setopt INC_APPEND_HISTORY SHARE_HISTORY

# Report background job status immediately.
set -o notify

# ============================================================================ #
# End of lib/10-history.zsh
