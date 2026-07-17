#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ FZF FUZZY FUNCTIONS ++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Interactive fuzzy-finder functions for enhanced navigation and editing.
# These complement the fzf configuration in lib/50-tools.zsh.
#
# Functions:
#   - ffcd   Fuzzy change directory.
#   - ffe    Fuzzy find and edit file.
#   - ffec   Fuzzy find by content and edit.
#   - ffch   Fuzzy search command history.
#
# Note: fzf configuration (theme, compgen, comprun) is in lib/50-tools.zsh.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# _fuzzy_change_directory
# @internal
# @description Interactively changes to a directory selected with fzf.
# Excludes common build and cache directories and accepts an initial query.
# @arg $1 string Optional initial fzf query.
# @exitcode 1 If no directory is selected.
# -----------------------------------------------------------------------------
_fuzzy_change_directory() {
  local initial_query="$1"
  local selected_dir
  local fzf_options=('--preview=ls -p {}' '--preview-window=right:60%')
  fzf_options+=(--height "80%" --layout=reverse --cycle)
  local max_depth=7

  if [[ -n "$initial_query" ]]; then
    fzf_options+=("--query=$initial_query")
  fi

  if command -v fd >/dev/null 2>&1; then
    selected_dir=$(fd --type d --max-depth "$max_depth" --hidden \
      --exclude .git --exclude node_modules --exclude .venv --exclude target --exclude .cache . \
      2>/dev/null | fzf "${fzf_options[@]}")
  else
    selected_dir=$(find . -maxdepth $max_depth \
      \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name .cache \) -prune \
      -o -type d -print 2>/dev/null | fzf "${fzf_options[@]}")
  fi

  if [[ -n "$selected_dir" && -d "$selected_dir" ]]; then
    cd "$selected_dir" || return 1
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# _fuzzy_edit_search_file
# @internal
# @description Interactively selects a file with fzf and opens it in the editor.
# @arg $1 string Optional initial fzf query.
# @exitcode 1 If no file is selected or the editor fails.
# -----------------------------------------------------------------------------
_fuzzy_edit_search_file() {
  local initial_query="$1"
  local selected_file
  local fzf_options=(--height "80%" --layout=reverse --preview-window right:60% --cycle)
  local max_depth=5

  if [[ -n "$initial_query" ]]; then
    fzf_options+=("--query=$initial_query")
  fi

  if command -v fd >/dev/null 2>&1; then
    selected_file=$(fd --type f --max-depth "$max_depth" --hidden \
      --exclude .git --exclude node_modules --exclude .venv --exclude target --exclude .cache . \
      2>/dev/null | fzf "${fzf_options[@]}")
  else
    selected_file=$(find . -maxdepth $max_depth -type f 2>/dev/null | fzf "${fzf_options[@]}")
  fi

  if [[ -n "$selected_file" && -f "$selected_file" ]]; then
    if command -v "$EDITOR" &>/dev/null; then
      "$EDITOR" "$selected_file"
    else
      echo "EDITOR is not specified. Using vim."
      vim "$selected_file"
    fi
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# _fuzzy_edit_search_file_content
# @internal
# @description Searches files with rg or grep and opens a selected match.
# @arg $1 string Search pattern.
# @exitcode 1 If the search pattern is missing.
# -----------------------------------------------------------------------------
_fuzzy_edit_search_file_content() {
  local search_pattern="${1:-}"
  local selected_file
  local fzf_options=()
  local preview_cmd

  if [[ -z "$search_pattern" ]]; then
    echo "Usage: ffec <search_pattern>" >&2
    return 1
  fi

  if command -v bat &>/dev/null; then
    preview_cmd='bat --color always --style=plain --paging=never {}'
  else
    preview_cmd='cat {}'
  fi

  fzf_options+=(--height "80%" --layout=reverse --cycle --preview-window right:60% --preview "$preview_cmd")

  if command -v rg &>/dev/null; then
    selected_file=$(
      rg --files-with-matches --hidden --no-messages \
        --glob '!.git/**' --glob '!node_modules/**' --glob '!.venv/**' \
        --glob '!target/**' --glob '!.cache/**' --glob '!dist/**' --glob '!build/**' \
        -- "$search_pattern" . 2>/dev/null | fzf "${fzf_options[@]}"
    )
  else
    selected_file=$(
      grep -irl --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv \
        --exclude-dir=target --exclude-dir=.cache -- "$search_pattern" . 2>/dev/null \
        | fzf "${fzf_options[@]}"
    )
  fi

  if [[ -n "$selected_file" ]]; then
    if command -v "$EDITOR" &>/dev/null; then
      "$EDITOR" "$selected_file"
    else
      echo "EDITOR is not specified. Using vim."
      vim "$selected_file"
    fi
  else
    echo "No file selected or search returned no results."
  fi
}

# -----------------------------------------------------------------------------
# _fuzzy_search_cmd_history
# @internal
# @description Fuzzy-searches shell history and loads the selection into ZLE.
# @arg $1 string Optional initial fzf query.
# @exitcode 1 If fzf integration is unavailable or selection fails.
# -----------------------------------------------------------------------------
_fuzzy_search_cmd_history() {
  local selected
  setopt localoptions noglobsubst noposixbuiltins pipefail no_aliases noglob nobash_rematch 2>/dev/null

  # ffch relies on fzf's shell-integration helpers (__fzf_defaults, __fzfcmd).
  # If key-bindings.zsh wasn't sourced (outdated fzf, custom install, partial
  # integration), those helpers are missing and the call below would fail with
  # a cryptic "command not found".
  if ! typeset -f __fzf_defaults >/dev/null 2>&1 || ! typeset -f __fzfcmd >/dev/null 2>&1; then
    echo "${C_YELLOW}ffch: fzf shell integration not loaded. Source fzf's key-bindings.zsh.${C_RESET}" >&2
    return 1
  fi

  local fzf_query=""
  if [[ -n "$1" ]]; then
    fzf_query="--query=${(q)1}"
  else
    fzf_query="--query=${(q)LBUFFER}"
  fi

  if zmodload -F zsh/parameter p:{commands,history} 2>/dev/null && (( ${+commands[perl]} )); then
    selected="$(printf '%s\t%s\000' "${(kv)history[@]}" |
      perl -0 -ne 'if (!$seen{(/^\s*[0-9]+\**\t(.*)/s, $1)}++) { s/\n/\n\t/g; print; }' |
      FZF_DEFAULT_OPTS=$(__fzf_defaults "" "-n2..,.. --scheme=history --bind=ctrl-r:toggle-sort --wrap-sign '\t> ' --highlight-line ${FZF_CTRL_R_OPTS-} $fzf_query +m --read0") \
      FZF_DEFAULT_OPTS_FILE='' $(__fzfcmd))"
  else
    selected="$(fc -rl 1 | awk '{ cmd=$0; sub(/^[ \t]*[0-9]+\**[ \t]+/, "", cmd); if (!seen[cmd]++) print $0 }' |
      FZF_DEFAULT_OPTS=$(__fzf_defaults "" "-n2..,.. --scheme=history --bind=ctrl-r:toggle-sort --wrap-sign '\t> ' --highlight-line ${FZF_CTRL_R_OPTS-} $fzf_query +m") \
      FZF_DEFAULT_OPTS_FILE='' $(__fzfcmd))"
  fi

  local ret=$?
  if [[ -n "$selected" ]]; then
    if [[ $(awk '{print $1; exit}' <<< "$selected") =~ ^[1-9][0-9]* ]]; then
      zle vi-fetch-history -n $MATCH
    else
      LBUFFER="$selected"
    fi
  fi
  return $ret
}

# Aliases for quick access.
alias ffcd='_fuzzy_change_directory'
alias ffe='_fuzzy_edit_search_file'
alias ffec='_fuzzy_edit_search_file_content'
alias ffch='_fuzzy_search_cmd_history'

# ============================================================================ #
# End of fzf.zsh
