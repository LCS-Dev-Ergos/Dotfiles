#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ PRODUCTIVITY FUNCTIONS ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Productivity and system management utilities.
# Tools for notes, bookmarks, cleanup, and system information.
#
# Functions:
#   - note      Quick note-taking with timestamps.
#   - bm        Directory bookmark system.
#   - cleanup   Clean temporary and cache files.
#   - zshcache  Reset Zsh-related caches (compdump, lazy caches, completions).
#   - fkill     Interactive process killer.
#   - dshell    Docker container shell access.
#   - preview   Interactive file preview with fzf.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# note
# -----------------------------------------------------------------------------
# Quick note-taking function with automatic timestamping and monthly organization.
# Notes are stored in markdown format in monthly files.
#
# Usage:
#   note [text]    - Add note with text.
#   note           - Interactive mode (Ctrl+D to finish).
#
# Environment:
#   NOTES_DIR - Custom notes directory (default: ~/.notes)
# -----------------------------------------------------------------------------
function note() {
  local notes_dir="${NOTES_DIR:-$HOME/.notes}"
  local notes_file="$notes_dir/notes_$(date +'%Y-%m').md"

  # Create notes directory if it doesn't exist.
  [[ ! -d "$notes_dir" ]] && mkdir -p "$notes_dir"

  local timestamp="$(date +'%Y-%m-%d %H:%M:%S')"

  if [[ $# -eq 0 ]]; then
    # Interactive mode.
    echo "${C_CYAN}Enter note (Ctrl+D to finish):${C_RESET}"
    local note_content
    note_content=$(cat)
    if [[ -n "$note_content" ]]; then
      echo -e "\n## $timestamp\n$note_content" >>"$notes_file"
      echo "${C_GREEN}Note saved to $notes_file${C_RESET}"
    fi
  else
    # Quick mode with arguments.
    echo -e "\n## $timestamp\n$*" >>"$notes_file"
    echo "${C_GREEN}Note saved to $notes_file${C_RESET}"
  fi
}

# -----------------------------------------------------------------------------
# bm
# -----------------------------------------------------------------------------
# Simple bookmark system for directories with add/delete/list/jump operations.
# Bookmarks are stored in ~/.directory_bookmarks
#
# Usage:
#   bm add <name>    - Bookmark current directory.
#   bm del <name>    - Delete bookmark.
#   bm list          - List all bookmarks (default).
#   bm <name>        - Jump to bookmarked directory.
# -----------------------------------------------------------------------------
function bm() {
  local bookmarks_file="$HOME/.directory_bookmarks"
  local action="${1:-list}"
  local name="$2"

  case "$action" in
    add)
      if [[ -z "$name" ]]; then
        echo "${C_YELLOW}Usage: bm add <name>${C_RESET}" >&2
        return 1
      fi
      local current_dir="$(pwd)"
      echo "$name=$current_dir" >>"$bookmarks_file"
      echo "${C_GREEN}Bookmark '$name' added for $current_dir${C_RESET}"
      ;;

    del)
      if [[ -z "$name" ]]; then
        echo "${C_YELLOW}Usage: bm del <name>${C_RESET}" >&2
        return 1
      fi
      if [[ -f "$bookmarks_file" ]]; then
        grep -v "^$name=" "$bookmarks_file" >"${bookmarks_file}.tmp"
        mv "${bookmarks_file}.tmp" "$bookmarks_file"
        echo "${C_GREEN}Bookmark '$name' deleted${C_RESET}"
      fi
      ;;

    list)
      if [[ -f "$bookmarks_file" ]]; then
        echo "${C_CYAN}Directory Bookmarks:${C_RESET}"
        while IFS='=' read -r name dir; do
          echo "  ${C_YELLOW}$name${C_RESET} -> $dir"
        done <"$bookmarks_file"
      else
        echo "${C_YELLOW}No bookmarks found.${C_RESET}"
      fi
      ;;

    *)
      if [[ -f "$bookmarks_file" ]]; then
        local dir=$(grep "^$action=" "$bookmarks_file" | cut -d= -f2-)
        if [[ -n "$dir" ]]; then
          cd "$dir"
          echo "${C_GREEN}Jumped to bookmark '$action': $(pwd)${C_RESET}"
        else
          echo "${C_RED}Error: Bookmark '$action' not found.${C_RESET}" >&2
          return 1
        fi
      else
        echo "${C_RED}Error: No bookmarks file found.${C_RESET}" >&2
        return 1
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# cleanup
# -----------------------------------------------------------------------------
# Clean various temporary and cache files across the system.
# Supports dry-run mode to preview what will be deleted.
#
# Cleaned locations:
#   - System temp directories (/tmp, /private/var/tmp)
#   - User caches (~/.cache, ~/Library/Caches on macOS)
#   - Package manager caches (npm, yarn)
#
# Usage:
#   cleanup [--dry-run]
#
# Arguments:
#   --dry-run - Show what would be deleted without actually removing files.
# -----------------------------------------------------------------------------
function cleanup() {
  local dry_run=false
  [[ "$1" == "--dry-run" ]] && dry_run=true

  echo "${C_CYAN}Cleaning temporary files...${C_RESET}"

  local total_size=0
  local files_to_clean=()

  # Add directories to clean based on platform.
  if [[ "$PLATFORM" == "macOS" ]]; then
    files_to_clean+=(
      "$HOME/Library/Caches/*"
      "$HOME/.Trash/*"
      "/private/var/tmp/*"
    )
  fi

  # Common directories for all platforms.
  files_to_clean+=(
    "/tmp/*"
    "$HOME/.cache/*"
    "$HOME/.npm/_cacache/*"
    "$HOME/.yarn/cache/*"
  )

  if [[ "$dry_run" == true ]]; then
    echo "${C_YELLOW}DRY RUN - No files will be deleted${C_RESET}"
    for pattern in "${files_to_clean[@]}"; do
      if ls $pattern >/dev/null 2>&1; then
        du -sh $pattern 2>/dev/null | while read size path; do
          echo "  Would remove: $path ($size)"
        done
      fi
    done
  else
    for pattern in "${files_to_clean[@]}"; do
      if ls $pattern >/dev/null 2>&1; then
        rm -rf $pattern 2>/dev/null
      fi
    done
    echo "${C_GREEN}Cleanup completed!${C_RESET}"
  fi
}

# -----------------------------------------------------------------------------
# zshcache
# -----------------------------------------------------------------------------
# Reset Zsh-related caches to fix inconsistencies after config changes.
# Removes compdump files, cached completions, and lazy cache stubs.
#
# Usage:
#   zshcache [--dry-run] [--rebuild] [--quiet]
#
# Arguments:
#   --dry-run - Show what would be removed without deleting.
#   --rebuild - Run compinit after cleanup to rebuild caches.
#   --quiet   - Suppress informational output.
# -----------------------------------------------------------------------------
function zshcache() {
  local dry_run=false
  local rebuild=false
  local quiet=false

  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      --rebuild) rebuild=true ;;
      --quiet) quiet=true ;;
    esac
  done

  setopt localoptions nullglob

  local zdot="${ZDOTDIR:-$HOME}"
  local xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  local -a targets

  # Zsh compdump files (ZDOTDIR now points to $HOME).
  targets+=( "$zdot/.zcompdump"* )

  # OMZ compdump cache if present.
  if [[ -n "${ZSH:-}" ]]; then
    targets+=( "$ZSH/cache/.zcompdump-"* )
  fi

  # Custom caches created by this config.
  targets+=( "$xdg_cache/zsh"/* )

  if [[ "$dry_run" == true ]]; then
    [[ "$quiet" == true ]] || echo "${C_YELLOW}DRY RUN - Zsh cache files that would be removed:${C_RESET}"
    for item in "${targets[@]}"; do
      [[ "$quiet" == true ]] || echo "  $item"
    done
  else
    (( ${#targets[@]} )) && command rm -rf -- "${targets[@]}" 2>/dev/null
    [[ "$quiet" == true ]] || echo "${C_GREEN}Zsh cache cleanup completed.${C_RESET}"
  fi

  if [[ "$rebuild" == true ]]; then
    autoload -Uz compinit
    compinit -C
    [[ "$quiet" == true ]] || echo "${C_GREEN}compinit rebuilt.${C_RESET}"
  fi
}

# -----------------------------------------------------------------------------
# fkill
# -----------------------------------------------------------------------------
# Interactively find and kill processes using fzf for selection.
# Allows multi-selection and sends specified signal to selected processes.
#
# Usage:
#   fkill [signal]
#
# Arguments:
#   signal - Signal number to send (default: 15/SIGTERM)
# -----------------------------------------------------------------------------
function fkill() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
    return 1
  fi

  local pid
  # Use ps to get processes, pipe to fzf for selection, and awk to get the PID.
  # Added -r to read to prevent backslash interpretation.
  pid=$(ps -ef | sed 1d | fzf -m --tac --header='Select process(es) to kill. Press CTRL-C to cancel' | awk '{print $2}')

  if [[ -n "$pid" ]]; then
    # Kill the selected process(es) with SIGTERM (15) by default, or specified signal.
    local signal="${1:-15}"
    # Use quotes to handle multiple PIDs correctly.
    echo "$pid" | xargs kill -"${signal}" 2>/dev/null
    if [[ $? -eq 0 ]]; then
      echo "${C_GREEN}Process(es) with PID(s): $pid killed with signal ${signal}.${C_RESET}"
    else
      echo "${C_RED}Error: Failed to kill some processes. Try with sudo.${C_RESET}" >&2
      return 1
    fi
  else
    echo "${C_YELLOW}No process selected.${C_RESET}"
  fi
}

# -----------------------------------------------------------------------------
# dshell
# -----------------------------------------------------------------------------
# Interactively select a running Docker container and access its shell.
#
# Usage:
#   dshell
# -----------------------------------------------------------------------------
function dshell() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "${C_RED}Error: Docker is not installed.${C_RESET}" >&2
    return 1
  fi

  if ! command -v fzf >/dev/null 2>&1; then
    echo "${C_RED}Error: fzf is required.${C_RESET}" >&2
    return 1
  fi

  # Select a running container using fzf.
  local container
  container=$(docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}" |
    fzf --header-lines=1 --header='Select container for shell access' |
    awk '{print $1}')

  if [[ -n "$container" ]]; then
    echo "${C_CYAN}Accessing shell in container: $container${C_RESET}"
    docker exec -it "$container" sh -c 'bash || sh'
  fi
}

# -----------------------------------------------------------------------------
# preview
# -----------------------------------------------------------------------------
# Interactively preview and select files using fzf with bat/eza integration.
# Shows directory tree for folders and syntax-highlighted content for files.
#
# Usage:
#   preview
# -----------------------------------------------------------------------------
function preview() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
    return 1
  fi

  # Use eza for directory listings, bat for file previews.
  fzf --preview '
    if [ -d {} ]; then
      command -v eza >/dev/null 2>&1 && eza --tree --color=always {} || ls -la {}
    else
      command -v bat >/dev/null 2>&1 && bat --color=always --style=numbers --line-range=:200 {} || head -200 {}
    fi'
}

# ============================================================================ #
