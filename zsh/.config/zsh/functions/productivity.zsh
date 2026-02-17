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
      if [[ "$name" == *"="* || "$name" == *$'\n'* ]]; then
        echo "${C_RED}Error: Bookmark name cannot contain '=' or newlines.${C_RESET}" >&2
        return 1
      fi

      local current_dir="$PWD"
      local tmp_file="${bookmarks_file}.tmp.$$"

      if [[ -f "$bookmarks_file" ]]; then
        if ! command awk -F= -v key="$name" '$1 != key { print }' "$bookmarks_file" >"$tmp_file"; then
          command rm -f -- "$tmp_file" 2>/dev/null
          echo "${C_RED}Error: Failed to update bookmarks.${C_RESET}" >&2
          return 1
        fi
      else
        : >"$tmp_file" || {
          echo "${C_RED}Error: Cannot create bookmarks file.${C_RESET}" >&2
          return 1
        }
      fi

      print -r -- "$name=$current_dir" >>"$tmp_file" || {
        command rm -f -- "$tmp_file" 2>/dev/null
        echo "${C_RED}Error: Failed to write bookmark.${C_RESET}" >&2
        return 1
      }

      command mv -- "$tmp_file" "$bookmarks_file" || {
        command rm -f -- "$tmp_file" 2>/dev/null
        echo "${C_RED}Error: Failed to save bookmarks.${C_RESET}" >&2
        return 1
      }

      command chmod 600 "$bookmarks_file" 2>/dev/null || :
      echo "${C_GREEN}Bookmark '$name' saved for $current_dir${C_RESET}"
      ;;

    del)
      if [[ -z "$name" ]]; then
        echo "${C_YELLOW}Usage: bm del <name>${C_RESET}" >&2
        return 1
      fi
      if [[ "$name" == *"="* || "$name" == *$'\n'* ]]; then
        echo "${C_RED}Error: Invalid bookmark name.${C_RESET}" >&2
        return 1
      fi

      if [[ ! -f "$bookmarks_file" ]]; then
        echo "${C_RED}Error: No bookmarks file found.${C_RESET}" >&2
        return 1
      fi

      if ! command awk -F= -v key="$name" 'BEGIN { found = 0 } $1 == key { found = 1 } END { exit found ? 0 : 1 }' "$bookmarks_file"; then
        echo "${C_RED}Error: Bookmark '$name' not found.${C_RESET}" >&2
        return 1
      fi

      local tmp_file="${bookmarks_file}.tmp.$$"
      if ! command awk -F= -v key="$name" '$1 != key { print }' "$bookmarks_file" >"$tmp_file"; then
        command rm -f -- "$tmp_file" 2>/dev/null
        echo "${C_RED}Error: Failed to update bookmarks.${C_RESET}" >&2
        return 1
      fi

      command mv -- "$tmp_file" "$bookmarks_file" || {
        command rm -f -- "$tmp_file" 2>/dev/null
        echo "${C_RED}Error: Failed to save bookmarks.${C_RESET}" >&2
        return 1
      }

      echo "${C_GREEN}Bookmark '$name' deleted${C_RESET}"
      ;;

    list)
      if [[ -f "$bookmarks_file" ]]; then
        echo "${C_CYAN}Directory Bookmarks:${C_RESET}"
        local bm_name dir
        while IFS='=' read -r bm_name dir; do
          [[ -z "$bm_name" ]] && continue
          echo "  ${C_YELLOW}$bm_name${C_RESET} -> $dir"
        done <"$bookmarks_file"
      else
        echo "${C_YELLOW}No bookmarks found.${C_RESET}"
      fi
      ;;

    *)
      if [[ -f "$bookmarks_file" ]]; then
        if [[ "$action" == *"="* || "$action" == *$'\n'* ]]; then
          echo "${C_RED}Error: Invalid bookmark name.${C_RESET}" >&2
          return 1
        fi

        local dir
        dir="$(command awk -v key="$action" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$bookmarks_file")"
        if [[ -n "$dir" ]]; then
          if builtin cd -- "$dir"; then
            echo "${C_GREEN}Jumped to bookmark '$action': $PWD${C_RESET}"
          else
            echo "${C_RED}Error: Target directory for bookmark '$action' is not accessible.${C_RESET}" >&2
            return 1
          fi
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
  emulate -L zsh
  setopt noxtrace noverbose nullglob

  local dry_run=false
  local min_age_days="${CLEANUP_MIN_AGE_DAYS:-7}"
  case "${1:-}" in
    --dry-run) dry_run=true ;;
    "")
      ;;
    *)
      echo "${C_YELLOW}Usage: cleanup [--dry-run]${C_RESET}" >&2
      return 1
      ;;
  esac

  if ! [[ "$min_age_days" =~ ^[0-9]+$ ]]; then
    min_age_days=7
  fi

  echo "${C_CYAN}Cleaning temporary files older than ${min_age_days} days...${C_RESET}"

  local -a tmp_roots=()
  local -a cache_roots=()
  local -a targets=()
  local root item

  # Add directories to clean based on platform.
  if [[ "$PLATFORM" == "macOS" ]]; then
    tmp_roots+=("/private/var/tmp")
    cache_roots+=(
      "$HOME/Library/Caches"
      "$HOME/.Trash"
    )
  fi

  # Common directories for all platforms.
  tmp_roots+=("/tmp")
  cache_roots+=(
    "$HOME/.cache"
    "$HOME/.npm/_cacache"
    "$HOME/.yarn/cache"
  )

  # System temp roots: only user-owned entries, older than threshold.
  for root in "${tmp_roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' item; do
      targets+=("$item")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -user "$USER" -mtime "+$min_age_days" -print0 2>/dev/null)
  done

  # User cache roots: only top-level entries older than threshold.
  for root in "${cache_roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' item; do
      targets+=("$item")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -mtime "+$min_age_days" -print0 2>/dev/null)
  done

  if (( ${#targets[@]} == 0 )); then
    echo "${C_YELLOW}No temporary/cache files found to clean.${C_RESET}"
    return 0
  fi

  if [[ "$dry_run" == true ]]; then
    echo "${C_YELLOW}DRY RUN - No files will be deleted${C_RESET}"
    local item size
    for item in "${targets[@]}"; do
      size="$(du -sh -- "$item" 2>/dev/null | awk '{print $1}')"
      [[ -z "$size" ]] && size="?"
      echo "  Would remove: $item ($size)"
    done
  else
    command rm -rf -- "${targets[@]}" 2>/dev/null
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
#   zshcache [--dry-run] [--rebuild] [--compile] [--quiet]
#
# Arguments:
#   --dry-run - Show what would be removed without deleting.
#   --rebuild - Run compinit after cleanup to rebuild caches.
#   --compile - Compile Zsh files to .zwc bytecode.
#   --quiet   - Suppress informational output.
# -----------------------------------------------------------------------------
function zshcache() {
  local dry_run=false
  local rebuild=false
  local compile=false
  local quiet=false

  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      --rebuild) rebuild=true ;;
      --compile) compile=true ;;
      --quiet) quiet=true ;;
    esac
  done

  if [[ "$rebuild" == true && "${ZSH_CACHE_COMPILE:-1}" == "1" ]]; then
    compile=true
  fi

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

  _zshcache_compile() {
    emulate -L zsh
    setopt noxtrace noverbose nullglob

    local cfg_root="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}"
    local zdot="${ZDOTDIR:-$HOME}"
    local -a compile_files

    compile_files=(
      "$cfg_root"/*.zsh(N.)
      "$cfg_root"/lib/**/*.zsh(N.)
      "$cfg_root"/functions/**/*.zsh(N.)
      "$cfg_root"/conf.d/**/*.zsh(N.)
      "$cfg_root"/others/**/*.zsh(N.)
      "$zdot"/.zshrc(N)
      "$zdot"/.zshenv(N)
      "$zdot"/.zprofile(N)
    )
    typeset -U compile_files

    (( ${#compile_files[@]} )) || return 0

    local file
    local failed=0
    for file in "${compile_files[@]}"; do
      if ! zcompile -U "$file" 2>/dev/null; then
        failed=1
        [[ "$quiet" == true ]] || echo "${C_YELLOW}Warning: zcompile failed for $file${C_RESET}"
      fi
    done

    if (( failed == 0 )); then
      [[ "$quiet" == true ]] || echo "${C_GREEN}Zsh bytecode compiled.${C_RESET}"
    fi
  }

  if [[ "$rebuild" == true ]]; then
    autoload -Uz compinit
    compinit -C
    [[ "$quiet" == true ]] || echo "${C_GREEN}compinit rebuilt.${C_RESET}"
  fi

  if [[ "$compile" == true ]]; then
    if [[ "$dry_run" == true ]]; then
      [[ "$quiet" == true ]] || echo "${C_YELLOW}DRY RUN - zcompile skipped.${C_RESET}"
    else
      _zshcache_compile
    fi
  fi

  unfunction _zshcache_compile 2>/dev/null
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
# End of productivity.zsh
