#!/usr/bin/env zsh
# shellcheck shell=zsh
# zsh-load: deferred
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
# @description Appends a timestamped note to a monthly Markdown file under
# NOTES_DIR or ~/.notes; without text, reads until CTRL-D.
# @arg $@ string Optional note text; multiple arguments are joined with spaces.
# @exitcode 1 If the notes directory or file cannot be created.
# -----------------------------------------------------------------------------
function note() {
  local notes_dir="${NOTES_DIR:-$HOME/.notes}"
  local notes_file="$notes_dir/notes_$(date +'%Y-%m').md"

  # Create notes directory if it doesn't exist (private: notes may contain
  # sensitive information like tokens, credentials jotted down).
  if [[ ! -d "$notes_dir" ]]; then
    (umask 077 && command mkdir -p -- "$notes_dir") || {
      echo "${C_RED}Error: Cannot create notes directory '$notes_dir'.${C_RESET}" >&2
      return 1
    }
  fi
  command chmod 700 "$notes_dir" 2>/dev/null || :

  local timestamp="$(date +'%Y-%m-%d %H:%M:%S')"

  # Ensure file exists with restrictive perms before any append.
  if [[ ! -f "$notes_file" ]]; then
    (umask 077 && : >>"$notes_file") || {
      echo "${C_RED}Error: Cannot create notes file '$notes_file'.${C_RESET}" >&2
      return 1
    }
  fi
  command chmod 600 "$notes_file" 2>/dev/null || :

  if [[ $# -eq 0 ]]; then
    echo "${C_CYAN}Enter note (Ctrl+D to finish):${C_RESET}"
    local note_content
    note_content=$(cat)
    if [[ -n "$note_content" ]]; then
      echo -e "\n## $timestamp\n$note_content" >>"$notes_file"
      echo "${C_GREEN}Note saved to $notes_file${C_RESET}"
    fi
  else
    echo -e "\n## $timestamp\n$*" >>"$notes_file"
    echo "${C_GREEN}Note saved to $notes_file${C_RESET}"
  fi
}

# -----------------------------------------------------------------------------
# bm
# @description Adds, deletes, lists, or jumps to bookmarks stored in
# ~/.directory_bookmarks.
# @arg $1 string Optional subcommand or bookmark name; defaults to list.
# @arg $2 string Optional bookmark name for the add or del subcommands.
# @exitcode 1 If a name is invalid, absent, or cannot be entered.
# -----------------------------------------------------------------------------
function bm() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1

  local bookmarks_file="$HOME/.directory_bookmarks"
  local action="${1:-list}"
  local name="$2"

  # Refuse links and non-regular files before any chmod or redirection. This
  # keeps a compromised bookmark path from targeting another user file.
  if [[ -L "$bookmarks_file" ]]; then
    _zsh_ui_log error "Refusing symlinked bookmarks file: $bookmarks_file"
    return 1
  fi
  if [[ -e "$bookmarks_file" && ! -f "$bookmarks_file" ]]; then
    _zsh_ui_log error "Bookmarks path is not a regular file."
    return 1
  fi

  # Bookmark names and paths can reveal sensitive directories.
  if [[ ! -e "$bookmarks_file" ]]; then
    (umask 077 && : >| "$bookmarks_file") 2>/dev/null || {
      _zsh_ui_log error "Cannot create the bookmarks file."
      return 1
    }
  fi
  command chmod 600 "$bookmarks_file" 2>/dev/null || {
    _zsh_ui_log error "Cannot secure the bookmarks file."
    return 1
  }
  if ! typeset -f _zsh_is_secure_file >/dev/null 2>&1 ||
      ! _zsh_is_secure_file "$bookmarks_file"; then
    _zsh_ui_log error "Bookmarks file ownership or permissions are unsafe."
    return 1
  fi

  case "$action" in
    add)
      if [[ -z "$name" ]]; then
        _zsh_ui_log error "Usage: bm add <name>"
        return 1
      fi
      if [[ "$name" == *"="* || "$name" == *[[:cntrl:]]* ]]; then
        _zsh_ui_log error \
          "Bookmark names cannot contain '=', tabs, or newlines."
        return 1
      fi

      local current_dir="$PWD"
      if [[ "$current_dir" == *[[:cntrl:]]* ]]; then
        _zsh_ui_log error \
          "Directory paths containing control characters cannot be saved."
        return 1
      fi
      local tmp_file
      tmp_file="$(command mktemp "${bookmarks_file}.tmp.XXXXXX" \
        2>/dev/null)" || {
        _zsh_ui_log error "Cannot create a secure temporary file."
        return 1
      }

      {
        if ! command env BM_KEY="$name" awk -F= \
            '$1 != ENVIRON["BM_KEY"] { print }' \
            "$bookmarks_file" >| "$tmp_file"; then
          _zsh_ui_log error "Failed to update bookmarks."
          return 1
        fi

        print -r -- "$name=$current_dir" >> "$tmp_file" || {
          _zsh_ui_log error "Failed to write bookmark '$name'."
          return 1
        }
        command chmod 600 "$tmp_file" 2>/dev/null || {
          _zsh_ui_log error "Failed to secure updated bookmarks."
          return 1
        }
        command mv -f -- "$tmp_file" "$bookmarks_file" || {
          _zsh_ui_log error "Failed to save bookmarks."
          return 1
        }
        tmp_file=""
      } always {
        if [[ -n "$tmp_file" ]]; then
          command rm -f -- "$tmp_file" 2>/dev/null
        fi
      }
      _zsh_ui_log ok "Bookmark '$name' saved for $current_dir."
      ;;

    del)
      if [[ -z "$name" ]]; then
        _zsh_ui_log error "Usage: bm del <name>"
        return 1
      fi
      if [[ "$name" == *"="* || "$name" == *[[:cntrl:]]* ]]; then
        _zsh_ui_log error "Invalid bookmark name."
        return 1
      fi

      if [[ ! -f "$bookmarks_file" ]]; then
        _zsh_ui_log error "No bookmarks file found."
        return 1
      fi

      if ! command env BM_KEY="$name" awk -F= \
          'BEGIN { found = 0 }
           $1 == ENVIRON["BM_KEY"] { found = 1 }
           END { exit found ? 0 : 1 }' "$bookmarks_file"; then
        _zsh_ui_log error "Bookmark '$name' not found."
        return 1
      fi

      local tmp_file
      tmp_file="$(command mktemp "${bookmarks_file}.tmp.XXXXXX" \
        2>/dev/null)" || {
        _zsh_ui_log error "Cannot create a secure temporary file."
        return 1
      }
      {
        if ! command env BM_KEY="$name" awk -F= \
            '$1 != ENVIRON["BM_KEY"] { print }' \
            "$bookmarks_file" >| "$tmp_file"; then
          _zsh_ui_log error "Failed to update bookmarks."
          return 1
        fi
        command chmod 600 "$tmp_file" 2>/dev/null || {
          _zsh_ui_log error "Failed to secure updated bookmarks."
          return 1
        }
        command mv -f -- "$tmp_file" "$bookmarks_file" || {
          _zsh_ui_log error "Failed to save bookmarks."
          return 1
        }
        tmp_file=""
      } always {
        if [[ -n "$tmp_file" ]]; then
          command rm -f -- "$tmp_file" 2>/dev/null
        fi
      }

      _zsh_ui_log ok "Bookmark '$name' deleted."
      ;;

    list)
      if [[ -f "$bookmarks_file" ]]; then
        local bm_name dir
        local -a bookmark_rows=()
        while IFS='=' read -r bm_name dir; do
          [[ -z "$bm_name" ]] && continue
          bm_name="${bm_name//$'\t'/\\t}"
          dir="${dir//$'\t'/\\t}"
          bookmark_rows+=("${bm_name}"$'\t'"${dir}")
        done <"$bookmarks_file"
        if (( ${#bookmark_rows[@]} )); then
          _zsh_ui_section "Directory bookmarks · ${#bookmark_rows[@]}"
          _zsh_ui_table $'Name\tDirectory' "${bookmark_rows[@]}"
        else
          _zsh_ui_log info "No bookmarks found."
        fi
      else
        _zsh_ui_log info "No bookmarks found."
      fi
      ;;

    *)
      if [[ -f "$bookmarks_file" ]]; then
        if [[ "$action" == *"="* || "$action" == *[[:cntrl:]]* ]]; then
          _zsh_ui_log error "Invalid bookmark name."
          return 1
        fi

        local dir
        dir="$(command env BM_KEY="$action" awk \
          'index($0, ENVIRON["BM_KEY"] "=") == 1 {
             print substr($0, length(ENVIRON["BM_KEY"]) + 2)
             exit
           }' "$bookmarks_file")"
        if [[ -n "$dir" ]]; then
          if builtin cd -- "$dir"; then
            _zsh_ui_log ok "Jumped to bookmark '$action': $PWD"
          else
            _zsh_ui_log error \
              "Target for bookmark '$action' is not accessible."
            return 1
          fi
        else
          _zsh_ui_log error "Bookmark '$action' not found."
          return 1
        fi
      else
        _zsh_ui_log error "No bookmarks file found."
        return 1
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# cleanup
# @description Removes old user-owned temp and cache entries, or previews
# deletions. CLEANUP_MIN_AGE_DAYS sets the threshold; default is 7.
# @option --dry-run Preview targets without deleting them.
# @exitcode 1 If an unsupported option is supplied.
# -----------------------------------------------------------------------------
function cleanup() {
  emulate -L zsh
  setopt noxtrace noverbose nullglob
  _zsh_ui_load || return 1

  local dry_run=false
  local min_age_days="${CLEANUP_MIN_AGE_DAYS:-7}"
  case "${1:-}" in
    --dry-run) dry_run=true ;;
    "")
      ;;
    *)
      _zsh_ui_log error "Usage: cleanup [--dry-run]"
      return 1
      ;;
  esac

  if ! [[ "$min_age_days" =~ ^[0-9]+$ ]]; then
    _zsh_ui_log warn \
      "Invalid CLEANUP_MIN_AGE_DAYS; using the 7-day default."
    min_age_days=7
  fi

  _zsh_ui_section "User cache cleanup · older than $min_age_days days"

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

  # User cache roots: top-level, user-owned entries older than the threshold.
  for root in "${cache_roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' item; do
      targets+=("$item")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -user "$USER" -mtime "+$min_age_days" -print0 2>/dev/null)
  done

  if (( ${#targets[@]} == 0 )); then
    _zsh_ui_log info "No eligible temporary or cache entries found."
    return 0
  fi

  if [[ "$dry_run" == true ]]; then
    local item size
    local -a preview_rows=()
    for item in "${targets[@]}"; do
      size="$(du -sh -- "$item" 2>/dev/null | awk '{print $1}')"
      [[ -z "$size" ]] && size="?"
      preview_rows+=("${size}"$'\t'"${item//$'\t'/\\t}")
    done
    _zsh_ui_table $'Size\tCandidate' "${preview_rows[@]}"
    _zsh_ui_log info \
      "Dry run only; ${#targets[@]} entries would be removed."
  else
    # Defense-in-depth: validate each target is a regular file, directory, or
    # symlink before deletion. Skips device/socket/fifo and silently bypasses
    # entries that vanished between enumeration and removal.
    local item
    local -i removed=0 failed=0 skipped=0
    for item in "${targets[@]}"; do
      if [[ -f "$item" || -d "$item" || -L "$item" ]]; then
        if command rm -rf -- "$item" 2>/dev/null; then
          (( removed++ ))
        else
          (( failed++ ))
        fi
      else
        (( skipped++ ))
      fi
    done
    if (( failed )); then
      _zsh_ui_log warn \
        "Removed $removed entries; $failed failed and $skipped disappeared."
      return 1
    fi
    local cleanup_summary="Removed $removed entries"
    (( skipped )) &&
      cleanup_summary+="; $skipped disappeared before cleanup"
    _zsh_ui_log ok "${cleanup_summary}."
  fi
}

# -----------------------------------------------------------------------------
# zshcache
# @description Removes Zsh completion and related caches with optional
# dry-run, rebuild, compile, and quiet modes.
# @option --dry-run | --dryrun Preview removals without changing files.
# @option --rebuild Rebuild compinit; compile when configured.
# @option --compile Compile the configured Zsh files to `.zwc` bytecode.
# @option --quiet Suppress informational output.
# @option --help Show usage information.
# @exitcode 1 If an unknown option is supplied.
# -----------------------------------------------------------------------------
function zshcache() {
  emulate -L zsh
  setopt localoptions nullglob

  local dry_run=false
  local rebuild=false
  local compile=false
  local quiet=false

  for arg in "$@"; do
    case "$arg" in
      --dry-run|--dryrun) dry_run=true ;;
      --rebuild)          rebuild=true ;;
      --compile)          compile=true ;;
      --quiet)            quiet=true ;;
      --help)
        echo "Usage: zshcache [--dry-run] [--rebuild] [--compile] [--quiet] [--help]"
        echo "  Cleans stale entries and rebuilds the zsh completion cache."
        echo ""
        echo "  --dry-run  Preview what would be removed without making changes"
        echo "  --rebuild  Run compinit after cleanup to rebuild the cache"
        echo "  --compile  Compile zsh files to .zwc bytecode"
        echo "  --quiet    Suppress informational output"
        return 0 ;;
      *) echo "zshcache: unknown option: $arg" >&2; return 1 ;;
    esac
  done

  [[ "$quiet" == true ]] || _zsh_ui_load || return 1

  if [[ "$rebuild" == true && "${ZSH_CACHE_COMPILE:-1}" == "1" ]]; then
    compile=true
  fi

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

  # Broken symlinks in the zinit completions directory.
  local zinit_completions="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/completions"
  local -a broken_links=()
  local _link
  if [[ -d "$zinit_completions" ]]; then
    for _link in "$zinit_completions"/_*(N@); do
      [[ ! -e "$_link" ]] && broken_links+=("$_link")
    done
  fi

  if [[ "$dry_run" == true ]]; then
    if [[ "$quiet" != true ]]; then
      local -a cache_rows=()
      for item in "${targets[@]}"; do
        cache_rows+=($'Cache\t'"${item//$'\t'/\\t}")
      done
      for _link in "${broken_links[@]}"; do
        cache_rows+=($'Broken link\t'"${_link//$'\t'/\\t}")
      done
      if (( ${#cache_rows[@]} )); then
        _zsh_ui_section "Zsh cache dry run"
        _zsh_ui_table $'Type\tPath' "${cache_rows[@]}"
      else
        _zsh_ui_log info "No Zsh cache entries would be removed."
      fi
      [[ "$rebuild" == true ]] &&
        _zsh_ui_log info "Dry run: compinit rebuild skipped."
      [[ "$compile" == true ]] &&
        _zsh_ui_log info "Dry run: bytecode compilation skipped."
    fi
    return 0
  else
    (( ${#targets[@]} )) && command rm -rf -- "${targets[@]}" 2>/dev/null
    # Remove broken symlinks.
    # Safety: must be a broken symlink (-L, !-e) within the expected directory.
    for _link in "${broken_links[@]}"; do
      if [[ "$_link" == "${zinit_completions}/"* && -L "$_link" && ! -e "$_link" ]]; then
        command rm -- "$_link" 2>/dev/null
      fi
    done
    [[ "$quiet" == true ]] || _zsh_ui_log ok "Zsh cache cleanup completed."
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
        [[ "$quiet" == true ]] ||
          _zsh_ui_log warn "zcompile failed for $file."
      fi
    done

    if (( failed == 0 )); then
      [[ "$quiet" == true ]] || _zsh_ui_log ok "Zsh bytecode compiled."
    fi
  }

  if [[ "$rebuild" == true ]]; then
    autoload -Uz compinit
    local _compdump="${ZSH_COMPDUMP:-${xdg_cache}/zsh/.zcompdump-${HOST}}"
    local _insecure_mode="-i"
    [[ "${ZSH_DISABLE_COMPFIX:-false}" == true ]] && _insecure_mode="-u"
    command mkdir -p "${xdg_cache}/zsh" 2>/dev/null
    if compinit "$_insecure_mode" -d "$_compdump" 2>/dev/null; then
      # Update the stamp and signature so startup can use compinit -C.
      : >| "${xdg_cache}/zsh/compinit.last" 2>/dev/null
      print -r -- "${_compdump}|${(j.:.)fpath}" >| "${xdg_cache}/zsh/compinit.sig" 2>/dev/null
      [[ "$quiet" == true ]] || _zsh_ui_log ok "compinit rebuilt."
    else
      if [[ "$quiet" == true ]]; then
        print -u2 "zshcache: compinit returned an error"
      else
        _zsh_ui_log error "compinit returned an error."
      fi
    fi
  fi

  if [[ "$compile" == true ]]; then
    _zshcache_compile
  fi

  unfunction _zshcache_compile 2>/dev/null
}

# -----------------------------------------------------------------------------
# fkill
# @description Interactively selects processes with fzf and sends a signal.
# Defaults to SIGTERM (15) and supports multiple selections.
# @arg $1 integer Optional signal number; defaults to 15.
# @exitcode 1 If fzf is unavailable or killing a selected process fails.
# -----------------------------------------------------------------------------
function fkill() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
    return 1
  fi

  local pid
  pid=$(ps -ef | sed 1d | fzf -m --tac --header='Select process(es) to kill. Press CTRL-C to cancel' | awk '{print $2}')

  if [[ -n "$pid" ]]; then
    local signal="${1:-15}"
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
# @description Selects a running Docker container with fzf and opens
# a shell through docker exec.
# @noargs
# @exitcode 1 If Docker or fzf is unavailable, or shell access fails.
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
# @description Selects files or directories with fzf and previews them using
# eza or tree, and bat or head.
# @noargs
# @exitcode 1 If fzf is unavailable or the preview command fails.
# -----------------------------------------------------------------------------
function preview() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "${C_RED}Error: fzf is required for this function.${C_RESET}" >&2
    return 1
  fi

  fzf --preview '
    if [ -d {} ]; then
      command -v eza >/dev/null 2>&1 && eza --tree --color=always {} || ls -la {}
    else
      command -v bat >/dev/null 2>&1 && bat --color=always --style=numbers --line-range=:200 {} || head -200 {}
    fi'
}

# ============================================================================ #
# End of productivity.zsh
