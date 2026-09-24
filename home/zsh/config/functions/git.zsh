#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ GIT FUNCTIONS +++++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Git workflow enhancement functions.
# Provides interactive tools for branch and stash management.
#
# Functions:
#   - gbr     Show branches sorted by recent commit.
#   - gstash  Interactive stash management with fzf.
#
# ============================================================================ #

# The OMZ git plugin (lib/20-zinit.zsh, or HyDE's plugin set) aliases gbr to
# `git branch --remotes`, and an alias shadows a function of the same name.
# The gbr below is the one this configuration documents.
unalias gbr 2>/dev/null

# -----------------------------------------------------------------------------
# gbr
# @description Lists local branches by most recent commit, including each
# branch's latest commit summary and relative commit date.
# @noargs
# @exitcode 1 If the current directory is not inside a Git repository.
# -----------------------------------------------------------------------------
function gbr() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "${C_RED}Error: Not in a git repository.${C_RESET}" >&2
    return 1
  fi

  # Built from pieces: a backslash-newline inside single quotes is literal, so
  # a wrapped quoted format would print every branch across three lines.
  local format='%(HEAD) %(color:yellow)%(refname:short)%(color:reset)'
  format+=' - %(color:red)%(objectname:short)%(color:reset)'
  format+=' - %(contents:subject) - %(authorname)'
  format+=' (%(color:green)%(committerdate:relative)%(color:reset))'

  git for-each-ref --sort=-committerdate --format="$format" refs/heads/
}

# -----------------------------------------------------------------------------
# gstash
# @description Interactively selects a stash with fzf, previews its diff, and
# applies the selected stash without removing it.
# @noargs
# @exitcode 1 If Git validation, fzf detection, or stash application fails.
# -----------------------------------------------------------------------------
function gstash() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "${C_RED}Error: Not in a git repository.${C_RESET}" >&2
    return 1
  fi

  if ! command -v fzf >/dev/null 2>&1; then
    echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
    return 1
  fi

  local stash
  stash=$(git stash list | fzf --preview 'git stash show -p $(echo {} | cut -d: -f1)' \
    --header='Select stash to apply. Press CTRL-C to cancel')

  if [[ -n "$stash" ]]; then
    local stash_id="${stash%%:*}"
    echo "${C_CYAN}Applying stash: $stash_id${C_RESET}"
    git stash apply "$stash_id"
  fi
}

# ============================================================================ #
# End of git.zsh
