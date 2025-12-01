#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ HISTORY CONFIGURATION ++++++++++++++++++++++++++++ #
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

HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
HISTSIZE=20000
SAVEHIST=50000
setopt BANG_HIST        # support !-style history expansion.
setopt EXTENDED_HISTORY # record timestamp/duration.
setopt HIST_VERIFY      # show before executing history expansions.
setopt HIST_EXPIRE_DUPS_FIRST HIST_IGNORE_DUPS HIST_IGNORE_SPACE
setopt INC_APPEND_HISTORY SHARE_HISTORY

# report background job status immediately.
set -o notify

# ============================================================================ #
