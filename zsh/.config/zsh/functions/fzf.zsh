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
# _fuzzy_change_directory (ffcd)
# -----------------------------------------------------------------------------
# Interactively navigate to a directory using fzf.
# Excludes common build/cache directories for faster searching.
#
# Usage:
#   ffcd [initial_query]
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

  selected_dir=$(find . -maxdepth $max_depth \
    \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name .cache \) -prune \
    -o -type d -print 2>/dev/null | fzf "${fzf_options[@]}")

  if [[ -n "$selected_dir" && -d "$selected_dir" ]]; then
    cd "$selected_dir" || return 1
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# _fuzzy_edit_search_file (ffe)
# -----------------------------------------------------------------------------
# Fuzzy find a file and open it in the editor.
#
# Usage:
#   ffe [initial_query]
# -----------------------------------------------------------------------------
_fuzzy_edit_search_file() {
  local initial_query="$1"
  local selected_file
  local fzf_options=(--height "80%" --layout=reverse --preview-window right:60% --cycle)
  local max_depth=5

  if [[ -n "$initial_query" ]]; then
    fzf_options+=("--query=$initial_query")
  fi

  selected_file=$(find . -maxdepth $max_depth -type f 2>/dev/null | fzf "${fzf_options[@]}")

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
# _fuzzy_edit_search_file_content (ffec)
# -----------------------------------------------------------------------------
# Search for content in files and open matching file in editor.
#
# Usage:
#   ffec <search_pattern>
# -----------------------------------------------------------------------------
_fuzzy_edit_search_file_content() {
  local selected_file
  local fzf_options=()
  local preview_cmd

  if command -v bat &>/dev/null; then
    preview_cmd='bat --color always --style=plain --paging=never {}'
  else
    preview_cmd='cat {}'
  fi

  fzf_options+=(--height "80%" --layout=reverse --cycle --preview-window right:60% --preview "$preview_cmd")
  selected_file=$(grep -irl "${1:-}" ./ | fzf "${fzf_options[@]}")

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
# _fuzzy_search_cmd_history (ffch)
# -----------------------------------------------------------------------------
# Fuzzy search command history with preview.
#
# Usage:
#   ffch [initial_query]
# -----------------------------------------------------------------------------
_fuzzy_search_cmd_history() {
  local selected
  setopt localoptions noglobsubst noposixbuiltins pipefail no_aliases noglob nobash_rematch 2>/dev/null

  local fzf_query=""
  if [[ -n "$1" ]]; then
    fzf_query="--query=${(qqq)1}"
  else
    fzf_query="--query=${(qqq)LBUFFER}"
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
