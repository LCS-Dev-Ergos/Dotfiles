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

  git for-each-ref \
    --sort=-committerdate refs/heads/ \
    --format='%(HEAD) %(color:yellow)%(refname:short)%(color:reset) - \
        %(color:red)%(objectname:short)%(color:reset) - %(contents:subject) - \
        %(authorname) (%(color:green)%(committerdate:relative)%(color:reset))'
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
    local stash_id=$(echo "$stash" | cut -d: -f1)
    echo "${C_CYAN}Applying stash: $stash_id${C_RESET}"
    git stash apply "$stash_id"
  fi
}

# ============================================================================ #
# End of git.zsh
