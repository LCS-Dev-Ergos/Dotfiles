#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++ VS CODE SYNC (Stable <-> Insiders) ++++++++++++++++++++ #
# ============================================================================ #
# Symlink-based synchronization of VS Code settings and extensions between
# VS Code Stable and VS Code Insiders on macOS and Linux.
#
# This script manages:
#  - Extensions (per-extension symlinks with exclusion list)
#  - User settings (settings.json, keybindings.json, mcp.json)
#  - Snippets directories
#  - Backup creation before destructive operations
#  - Status reporting and health checks
#  - Clean removal with content restoration
#
# Extension sync strategy:
#  Per-extension symlinks replace the legacy single directory symlink. This
#  allows platform-specific extensions (e.g. anthropic.claude-code-* with
#  Mach-O arm64 binaries) and version-incompatible extensions (e.g.
#  github.copilot-*) to be managed independently by each VS Code edition.
#  Excluded extensions are not symlinked; VS Code handles them autonomously.
#
#  vscode_extension_cleaner canonical source: ~/.vscode/extensions (Stable).
#  Optionally also run on ~/.vscode-insiders/extensions to clean excluded
#  extensions managed independently by VS Code Insiders.
#
# Supported platforms: macOS, Linux
#
# Functions:
#  vscode_sync_setup   - Create symlinks from Stable to Insiders
#  vscode_sync_status  - Show current synchronization state
#  vscode_sync_check   - Validate configuration health
#  vscode_sync_remove  - Remove symlinks and restore independence
#
# Author: XtremeXSPC
# License: MIT
# ============================================================================ #

# ++++++++++++++++++++++++++ SHARED HELPERS LOADER +++++++++++++++++++++++++++ #

# Source shared helpers for color, logging, and confirmation utilities.
_vscode_sync_helpers_dir="${ZSH_CONFIG_DIR:-$HOME/.config/zsh}/scripts"
if [[ -r "${_vscode_sync_helpers_dir}/_shared_helpers.sh" ]]; then
  # shellcheck disable=SC1091
  source "${_vscode_sync_helpers_dir}/_shared_helpers.sh"
else
  printf "[ERROR] Shared helpers not found: %s/_shared_helpers.sh\n" "$_vscode_sync_helpers_dir" >&2
  return 1 2>/dev/null || exit 1
fi
unset _vscode_sync_helpers_dir

# ++++++++++++++++++++++++++ STATIC CONFIGURATION ++++++++++++++++++++++++++++ #

# NOTE: VS Code profiles are NOT included in sync items. Profile definitions
# live in globalStorage/state.vscdb (SQLite). Use VS Code's built-in Settings
# Sync or manual Profile Export/Import to synchronize profiles across editions.

_VSCODE_SYNC_BACKUP_DIR="${HOME}/.local/share/vscode-sync-backups"
_VSCODE_SYNC_LOCK_DIR="${TMPDIR:-/tmp}/vscode_sync.lock"

# Platform-aware config: populated by _vscode_sync_init_config at source time.
_VSCODE_SYNC_ITEMS=()
_VSCODE_EXTENSIONS_SRC=""
_VSCODE_EXTENSIONS_DST=""
_VSCODE_EXTENSIONS_EXCLUDE=()

# Output vars for _vscode_sync_check_extensions (read by vscode_sync_check).
_VSCODE_EXT_CHECK_ISSUES=0
_VSCODE_EXT_CHECK_WARNINGS=0

# +++++++++++++++++++++++++++++ HELPER UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_sync_acquire_lock / _vscode_sync_release_lock
# -----------------------------------------------------------------------------
# Provides mutual exclusion for mutating operations (setup, remove).
# Uses mkdir atomicity. Detects and reclaims stale locks from dead processes.
#
# Usage:
#   _vscode_sync_acquire_lock   # returns 1 if another instance is running
#   _vscode_sync_release_lock   # safe to call even if lock not held
# -----------------------------------------------------------------------------
_vscode_sync_acquire_lock() {
  if mkdir "$_VSCODE_SYNC_LOCK_DIR" 2>/dev/null; then
    printf "%s" "$$" > "$_VSCODE_SYNC_LOCK_DIR/pid"
    return 0
  fi
  local lock_pid
  lock_pid=$(cat "$_VSCODE_SYNC_LOCK_DIR/pid" 2>/dev/null)
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    _shared_log error "Another vscode_sync operation is running (PID: $lock_pid)."
    return 1
  fi
  rm -rf "$_VSCODE_SYNC_LOCK_DIR"
  if mkdir "$_VSCODE_SYNC_LOCK_DIR" 2>/dev/null; then
    printf "%s" "$$" > "$_VSCODE_SYNC_LOCK_DIR/pid"
    return 0
  fi
  _shared_log error "Failed to acquire lock."
  return 1
}

_vscode_sync_release_lock() {
  rm -rf "$_VSCODE_SYNC_LOCK_DIR" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vscode_sync_check_platform
# -----------------------------------------------------------------------------
# Verifies the script is running on a supported platform (macOS or Linux).
#
# Usage:
#   _vscode_sync_check_platform
#
# Returns:
#   0 - Running on macOS or Linux.
#   1 - Unsupported platform.
#
# Side Effects:
#   - Logs error message if platform is unsupported.
# -----------------------------------------------------------------------------
_vscode_sync_check_platform() {
  _shared_detect_platform
  case "${SHARED_PLATFORM:-unknown}" in
    macOS|Linux) return 0 ;;
    *)
      _shared_log error "Unsupported platform: ${SHARED_PLATFORM:-unknown}"
      return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# _vscode_sync_parse_item
# -----------------------------------------------------------------------------
# Parses a pipe-delimited sync item into component variables.
# Sets _label, _source, and _target variables in the caller's scope.
#
# Usage:
#   _vscode_sync_parse_item <item>
#
# Arguments:
#   item - Pipe-delimited string "label|source_path|target_path" (required).
#
# Side Effects:
#   - Sets _label, _source, _target in calling scope.
# -----------------------------------------------------------------------------
_vscode_sync_parse_item() {
  local item="$1"
  _label="${item%%|*}"
  local rest="${item#*|}"
  _source="${rest%%|*}"
  _target="${rest#*|}"
}

# -----------------------------------------------------------------------------
# _vscode_sync_check_vscode_running
# -----------------------------------------------------------------------------
# Checks if VS Code Stable or Insiders processes are running.
# Detects both macOS (.app) and Linux (process name) patterns.
#
# Usage:
#   _vscode_sync_check_vscode_running
#
# Returns:
#   0 - No VS Code processes detected.
#   1 - One or more VS Code processes are running.
#
# Side Effects:
#   - Logs warnings for each running instance found.
# -----------------------------------------------------------------------------
_vscode_sync_check_vscode_running() {
  local running=0
  # macOS process patterns
  if pgrep -qf "/Visual Studio Code\.app/Contents/MacOS/" 2>/dev/null; then
    _shared_log warn "VS Code Stable appears to be running."
    running=1
  fi
  if pgrep -qf "/Visual Studio Code - Insiders\.app/Contents/MacOS/" 2>/dev/null; then
    _shared_log warn "VS Code Insiders appears to be running."
    running=1
  fi
  # Linux process patterns
  if pgrep -qx "code" 2>/dev/null; then
    _shared_log warn "VS Code Stable appears to be running."
    running=1
  fi
  if pgrep -qx "code-insiders" 2>/dev/null; then
    _shared_log warn "VS Code Insiders appears to be running."
    running=1
  fi
  return $running
}

# -----------------------------------------------------------------------------
# _vscode_sync_ensure_parent_dir
# -----------------------------------------------------------------------------
# Creates parent directory for a target path if it does not exist.
#
# Usage:
#   _vscode_sync_ensure_parent_dir <target_path>
#
# Arguments:
#   target_path - File or directory path whose parent must exist (required).
#
# Returns:
#   0 - Parent directory exists or was created.
#   1 - Failed to create parent directory.
# -----------------------------------------------------------------------------
_vscode_sync_ensure_parent_dir() {
  local target="$1"
  local parent_dir
  parent_dir="$(dirname "$target")"
  if [[ ! -d "$parent_dir" ]]; then
    _shared_log info "Creating directory: $parent_dir"
    mkdir -p "$parent_dir" || {
      _shared_log error "Failed to create directory: $parent_dir"
      return 1
    }
  fi
  return 0
}

# -----------------------------------------------------------------------------
# _vscode_sync_backup_item
# -----------------------------------------------------------------------------
# Creates a timestamped backup of an existing target before replacement.
#
# Usage:
#   _vscode_sync_backup_item <label> <target_path>
#
# Arguments:
#   label       - Human-readable item name for backup naming (required).
#   target_path - Path to file or directory to back up (required).
#
# Returns:
#   0 - Backup created successfully.
#   1 - Backup failed.
# -----------------------------------------------------------------------------
_vscode_sync_backup_item() {
  local label="$1" target="$2"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)_$$"
  local backup_dir="${_VSCODE_SYNC_BACKUP_DIR}/${timestamp}"

  mkdir -p -m 0700 "$backup_dir" || {
    _shared_log error "Failed to create backup directory: $backup_dir"
    return 1
  }

  local safe_label
  safe_label=$(printf "%s" "$label" | tr ' ' '_' | tr -cd '[:alnum:]_-')
  local backup_path="${backup_dir}/${safe_label}"

  if [[ -d "$target" ]]; then
    cp -R "$target" "$backup_path" || {
      _shared_log error "Failed to backup directory: $target"
      return 1
    }
  elif [[ -f "$target" ]]; then
    cp "$target" "$backup_path" || {
      _shared_log error "Failed to backup file: $target"
      return 1
    }
  fi

  _shared_log ok "Backed up: $target -> $backup_path"
  return 0
}

# -----------------------------------------------------------------------------
# _vscode_sync_item_status
# -----------------------------------------------------------------------------
# Determines the synchronization status of a single item.
#
# Usage:
#   sync_state=$(_vscode_sync_item_status <source> <target>)
#
# Side Effects:
#   - Outputs one of: synced, symlink_broken, symlink_wrong,
#     independent, missing, source_missing.
# -----------------------------------------------------------------------------
_vscode_sync_item_status() {
  local source="$1" target="$2"

  if [[ ! -e "$source" && ! -L "$source" ]]; then
    printf "source_missing"
    return
  fi

  if [[ -L "$target" ]]; then
    local link_dest
    link_dest=$(readlink "$target" 2>/dev/null)
    if [[ "$link_dest" == "$source" ]]; then
      if [[ -e "$target" ]]; then
        printf "synced"
      else
        printf "symlink_broken"
      fi
    else
      printf "symlink_wrong"
    fi
  elif [[ -e "$target" ]]; then
    printf "independent"
  else
    printf "missing"
  fi
}

# ++++++++++++++++++++++ PLATFORM-AWARE CONFIG INIT ++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_sync_init_config
# -----------------------------------------------------------------------------
# Initializes platform-aware configuration for sync items and extensions.
# Called automatically at source time (end of this file).
#
# Sets:
#   _VSCODE_SYNC_ITEMS         - "label|source|target" tuples for settings,
#                                keybindings, snippets, mcp config.
#   _VSCODE_EXTENSIONS_SRC     - Canonical extensions directory (Stable).
#   _VSCODE_EXTENSIONS_DST     - Insiders extensions directory.
#   _VSCODE_EXTENSIONS_EXCLUDE - Glob patterns for excluded extensions.
# -----------------------------------------------------------------------------
_vscode_sync_init_config() {
  _shared_detect_platform
  local user_stable user_insiders
  case "${SHARED_PLATFORM}" in
    macOS)
      user_stable="${HOME}/Library/Application Support/Code/User"
      user_insiders="${HOME}/Library/Application Support/Code - Insiders/User"
      ;;
    Linux)
      user_stable="${HOME}/.config/Code/User"
      user_insiders="${HOME}/.config/Code - Insiders/User"
      ;;
    *)
      user_stable=""
      user_insiders=""
      ;;
  esac

  _VSCODE_SYNC_ITEMS=(
    "Settings|${user_stable}/settings.json|${user_insiders}/settings.json"
    "Keybindings|${user_stable}/keybindings.json|${user_insiders}/keybindings.json"
    "Snippets|${user_stable}/snippets|${user_insiders}/snippets"
    "MCP Config|${user_stable}/mcp.json|${user_insiders}/mcp.json"
  )
  # Extensions managed separately via per-extension symlinks (see below).
  _VSCODE_EXTENSIONS_SRC="${HOME}/.vscode/extensions"
  _VSCODE_EXTENSIONS_DST="${HOME}/.vscode-insiders/extensions"
  _VSCODE_EXTENSIONS_EXCLUDE=(
    "anthropic.claude-code-*"  # Platform-specific binary (Mach-O arm64 != linux-x64)
    "github.copilot-*"         # Version-incompatible between Stable and Insiders
  )
}

# ++++++++++++++++++++++++ EXTENSION SYNC HELPERS +++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_sync_ext_is_excluded <name>
# -----------------------------------------------------------------------------
# Returns 0 if the extension name matches any pattern in _VSCODE_EXTENSIONS_EXCLUDE.
# Uses zsh case glob matching (no external dependencies).
# -----------------------------------------------------------------------------
_vscode_sync_ext_is_excluded() {
  local name="$1" pattern
  for pattern in "${_VSCODE_EXTENSIONS_EXCLUDE[@]}"; do
    case "$name" in
      $~pattern) return 0 ;;
    esac
  done
  return 1
}

# -----------------------------------------------------------------------------
# _vscode_sync_setup_extensions
# -----------------------------------------------------------------------------
# Sets up per-extension symlinks from _VSCODE_EXTENSIONS_SRC to
# _VSCODE_EXTENSIONS_DST, skipping excluded extensions.
#
# Handles migration from legacy directory symlink automatically.
# Idempotent: already-correct symlinks are skipped.
#
# Returns:
#   0 - Setup completed (possibly with failures logged).
#   1 - Fatal error (e.g. could not create dst directory).
# -----------------------------------------------------------------------------
_vscode_sync_setup_extensions() {
  setopt localoptions nullglob
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  if [[ ! -d "$src" ]]; then
    _shared_log warn "Extensions: source not found: $src"
    return 0
  fi

  # 1. Migration: replace legacy directory symlink with a real directory.
  if [[ -L "$dst" ]]; then
    _shared_log info "Extensions: migrating legacy directory symlink to real directory."
    rm -f "$dst" || {
      _shared_log error "Extensions: failed to remove legacy symlink: $dst"
      return 1
    }
  fi

  # 2. Ensure destination directory exists.
  mkdir -p "$dst" || {
    _shared_log error "Extensions: failed to create directory: $dst"
    return 1
  }

  # 3. Create per-extension symlinks.
  local synced=0 already=0 excluded=0 failed=0
  local name link link_dest ext_path
  for ext_path in "$src"/*/; do
    name="${ext_path%/}"
    name="${name##*/}"

    if _vscode_sync_ext_is_excluded "$name"; then
      ((excluded++))
      continue
    fi

    link="$dst/$name"
    if [[ -L "$link" ]]; then
      link_dest=$(readlink "$link" 2>/dev/null)
      if [[ "$link_dest" == "$src/$name" && -e "$link" ]]; then
        ((already++))
        continue
      fi
      # Stale or broken symlink — remove and recreate.
      rm -f "$link" || {
        _shared_log error "Extensions: failed to remove stale symlink: $link"
        ((failed++))
        continue
      }
    elif [[ -d "$link" ]]; then
      # Real directory (e.g. Insiders installed its own copy) — remove it so
      # the symlink to Stable's copy can be created.
      rm -rf "$link" || {
        _shared_log error "Extensions: failed to remove real directory: $link"
        ((failed++))
        continue
      }
    fi

    ln -s "$src/$name" "$link" || {
      _shared_log error "Extensions: failed to create symlink: $link"
      ((failed++))
      continue
    }
    ((synced++))
  done

  # 4. Report.
  _shared_log ok "Extensions: $synced synced, $already already linked, $excluded excluded, $failed failed."
}

# -----------------------------------------------------------------------------
# _vscode_sync_status_extensions
# -----------------------------------------------------------------------------
# Prints a one-line summary of extension sync status followed by details
# on excluded and broken-symlink extensions.
# -----------------------------------------------------------------------------
_vscode_sync_status_extensions() {
  setopt localoptions nullglob
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  if [[ ! -d "$src" ]]; then
    printf "  %s[NO SRC]%s  Extensions  Source not found: %s\n" "$C_RED" "$C_RESET" "$src"
    return
  fi

  if [[ -L "$dst" ]]; then
    printf "  %s[LEGACY]%s  Extensions  Legacy directory symlink (run setup to migrate)\n" \
      "$C_YELLOW" "$C_RESET"
    return
  fi

  if [[ ! -d "$dst" ]]; then
    printf "  %s[MISS]%s    Extensions  Target directory does not exist (not synced)\n" \
      "$C_RED" "$C_RESET"
    return
  fi

  local total=0 symlinked=0 excluded=0 broken=0
  local excluded_list=() broken_list=()
  local name ext_path link

  for ext_path in "$src"/*/; do
    name="${ext_path%/}"
    name="${name##*/}"
    ((total++))

    if _vscode_sync_ext_is_excluded "$name"; then
      ((excluded++))
      excluded_list+=("$name")
      continue
    fi

    link="$dst/$name"
    if [[ -L "$link" && -e "$link" ]]; then
      ((symlinked++))
    elif [[ -L "$link" && ! -e "$link" ]]; then
      ((broken++))
      broken_list+=("$name")
    fi
  done

  local expected=$(( total - excluded ))
  printf "  %s[SYNCED]%s  Extensions  %d/%d symlinked, %d excluded, %d broken\n" \
    "$C_GREEN" "$C_RESET" "$symlinked" "$expected" "$excluded" "$broken"

  if (( ${#excluded_list[@]} > 0 )); then
    printf "             %sExcluded:%s\n" "$C_BOLD" "$C_RESET"
    local n
    for n in "${excluded_list[@]}"; do
      printf "               - %s\n" "$n"
    done
  fi

  if (( ${#broken_list[@]} > 0 )); then
    printf "             %sBroken symlinks:%s\n" "$C_BOLD" "$C_RESET"
    local n
    for n in "${broken_list[@]}"; do
      printf "               - %s\n" "$n"
    done
  fi
}

# -----------------------------------------------------------------------------
# _vscode_sync_remove_extensions
# -----------------------------------------------------------------------------
# Removes per-extension symlinks from _VSCODE_EXTENSIONS_DST.
# Real directories (excluded extensions managed by VS Code) are skipped.
# Handles the legacy directory-symlink case.
# -----------------------------------------------------------------------------
_vscode_sync_remove_extensions() {
  setopt localoptions nullglob
  local dst="$_VSCODE_EXTENSIONS_DST"

  # Legacy directory symlink.
  if [[ -L "$dst" ]]; then
    _shared_log info "Extensions: removing legacy directory symlink."
    rm -f "$dst" || {
      _shared_log error "Extensions: failed to remove legacy symlink."
      return 1
    }
    _shared_log ok "Extensions: legacy symlink removed."
    return 0
  fi

  if [[ ! -d "$dst" ]]; then
    _shared_log info "Extensions: target directory does not exist, nothing to do."
    return 0
  fi

  local removed=0 skipped=0 failed=0
  local link_path name
  for link_path in "$dst"/*/; do
    name="${link_path%/}"
    if [[ -L "$name" ]]; then
      rm -f "$name" || {
        _shared_log error "Extensions: failed to remove symlink: $name"
        ((failed++))
        continue
      }
      ((removed++))
    else
      # Real directory: excluded extension managed by VS Code — skip.
      ((skipped++))
    fi
  done

  _shared_log ok "Extensions: $removed symlink(s) removed, $skipped real dir(s) skipped, $failed failed."
}

# -----------------------------------------------------------------------------
# _vscode_sync_check_extensions
# -----------------------------------------------------------------------------
# Validates extension sync health. Results stored in global vars:
#   _VSCODE_EXT_CHECK_ISSUES   - count of issues (broken symlinks)
#   _VSCODE_EXT_CHECK_WARNINGS - count of warnings (legacy symlink, wrong targets)
#
# Called by vscode_sync_check, which adds these counts to its local counters.
# -----------------------------------------------------------------------------
_vscode_sync_check_extensions() {
  setopt localoptions nullglob
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  _VSCODE_EXT_CHECK_ISSUES=0
  _VSCODE_EXT_CHECK_WARNINGS=0

  printf "  %sChecking:%s Extensions\n" "$C_BOLD" "$C_RESET"

  # Legacy directory symlink.
  if [[ -L "$dst" ]]; then
    _shared_log warn "    Extensions target is a legacy directory symlink (run setup to migrate)."
    ((_VSCODE_EXT_CHECK_WARNINGS++))
    return 0
  fi

  if [[ ! -d "$dst" ]]; then
    _shared_log info "    Extensions target directory does not exist (not yet synced)."
    return 0
  fi

  # Check for broken/wrong symlinks in dst.
  local broken_count=0 outside_count=0
  local broken_names=() outside_names=()
  local link_path name link_dest

  for link_path in "$dst"/*/; do
    name="${link_path%/}"
    [[ -L "$name" ]] || continue
    link_dest=$(readlink "$name" 2>/dev/null)
    if [[ ! -e "$name" ]]; then
      ((broken_count++))
      broken_names+=("${name##*/}")
      ((_VSCODE_EXT_CHECK_ISSUES++))
    elif [[ "$link_dest" != "$src/"* ]]; then
      ((outside_count++))
      outside_names+=("${name##*/}")
      ((_VSCODE_EXT_CHECK_WARNINGS++))
    fi
  done

  # Count excluded extensions (info only).
  local excluded_count=0 ext_path
  for ext_path in "$src"/*/; do
    _vscode_sync_ext_is_excluded "${${ext_path%/}##*/}" && ((excluded_count++))
  done

  if ((_VSCODE_EXT_CHECK_ISSUES == 0 && _VSCODE_EXT_CHECK_WARNINGS == 0)); then
    _shared_log ok "    All extension symlinks valid."
  fi

  if ((broken_count > 0)); then
    _shared_log error "    $broken_count broken extension symlink(s):"
    local n
    for n in "${broken_names[@]}"; do
      printf "       - %s\n" "$n"
    done
  fi

  if ((outside_count > 0)); then
    _shared_log warn "    $outside_count symlink(s) point outside ${src}:"
    local n
    for n in "${outside_names[@]}"; do
      printf "       - %s\n" "$n"
    done
  fi

  _shared_log info "    Excluded: $excluded_count extension(s) matching: ${(j:, :)_VSCODE_EXTENSIONS_EXCLUDE}"
}

# +++++++++++++++++++++++++++ MAIN SYNC FUNCTIONS ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# vscode_sync_setup
# -----------------------------------------------------------------------------
# Creates symlinks from VS Code Stable to VS Code Insiders.
# Displays a plan of actions, asks for confirmation, backs up existing
# targets, creates symlinks for settings items, then sets up per-extension
# symlinks (with automatic migration from legacy directory symlink).
# Idempotent: already-synced items are skipped without modification.
#
# Usage:
#   vscode_sync_setup
#
# Returns:
#   0 - Setup completed (or aborted by user).
#   1 - Platform check failed.
# -----------------------------------------------------------------------------
vscode_sync_setup() {
  setopt localoptions localtraps nullglob
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_acquire_lock || return 1
  trap '_vscode_sync_release_lock' EXIT

  printf "%s%s[+] VS Code Sync Setup (Stable -> Insiders)%s\n\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  _vscode_sync_check_vscode_running || {
    _shared_log warn "Modifying symlinks while VS Code is running may cause issues."
    _shared_log warn "Consider closing both editors before proceeding."
    echo
  }

  printf "%sPlanned actions:%s\n" "$C_BOLD" "$C_RESET"
  local _label _source _target item sync_state
  for item in "${_VSCODE_SYNC_ITEMS[@]}"; do
    _vscode_sync_parse_item "$item"
    sync_state=$(_vscode_sync_item_status "$_source" "$_target")
    case "$sync_state" in
      synced)
        printf "  %s[SKIP]%s  %-12s Already symlinked\n" "$C_GREEN" "$C_RESET" "$_label" ;;
      source_missing)
        printf "  %s[SKIP]%s  %-12s Source does not exist\n" "$C_YELLOW" "$C_RESET" "$_label" ;;
      *)
        printf "  %s[LINK]%s  %-12s %s -> %s\n" "$C_BLUE" "$C_RESET" "$_label" "$_target" "$_source" ;;
    esac
  done

  # Extensions planned actions preview.
  local ext_total=0 ext_excluded=0 ext_name ext_path
  for ext_path in "$_VSCODE_EXTENSIONS_SRC"/*/; do
    ext_name="${ext_path%/}"
    ext_name="${ext_name##*/}"
    ((ext_total++))
    _vscode_sync_ext_is_excluded "$ext_name" && ((ext_excluded++))
  done
  if [[ -L "$_VSCODE_EXTENSIONS_DST" ]]; then
    printf "  %s[MIGRATE]%s %-12s Legacy symlink -> per-extension (%d to link, %d excluded)\n" \
      "$C_YELLOW" "$C_RESET" "Extensions" "$((ext_total - ext_excluded))" "$ext_excluded"
  else
    printf "  %s[LINK]%s  %-12s %d to symlink, %d excluded\n" \
      "$C_BLUE" "$C_RESET" "Extensions" "$((ext_total - ext_excluded))" "$ext_excluded"
  fi
  if (( ${#_VSCODE_EXTENSIONS_EXCLUDE[@]} > 0 )); then
    printf "             Excluded patterns:"
    local p
    for p in "${_VSCODE_EXTENSIONS_EXCLUDE[@]}"; do
      printf " %s" "$p"
    done
    printf "\n"
  fi
  echo

  _shared_confirm "Proceed with setup?" || {
    _shared_log info "Aborted by user."
    return 0
  }
  echo

  local synced=0 skipped=0 failed=0 total=${#_VSCODE_SYNC_ITEMS[@]}
  for item in "${_VSCODE_SYNC_ITEMS[@]}"; do
    _vscode_sync_parse_item "$item"
    sync_state=$(_vscode_sync_item_status "$_source" "$_target")

    case "$sync_state" in
      synced)
        _shared_log ok "$_label: already synced, skipping."
        ((synced++))
        continue ;;
      source_missing)
        _shared_log warn "$_label: source not found ($_source), skipping."
        ((skipped++))
        continue ;;
    esac

    case "$_target" in
      "${HOME}"/*) ;;
      *)
        _shared_log error "$_label: target path outside HOME, skipping: $_target"
        ((failed++))
        continue ;;
    esac

    if [[ -e "$_target" || -L "$_target" ]]; then
      if [[ -e "$_target" ]]; then
        _vscode_sync_backup_item "$_label" "$_target" || {
          _shared_log error "$_label: backup failed, skipping."
          ((failed++))
          continue
        }
      fi
      rm -rf "$_target" || {
        _shared_log error "$_label: failed to remove existing target."
        ((failed++))
        continue
      }
    fi

    _vscode_sync_ensure_parent_dir "$_target" || {
      ((failed++))
      continue
    }

    ln -s "$_source" "$_target" || {
      _shared_log error "$_label: failed to create symlink."
      ((failed++))
      continue
    }

    _shared_log ok "$_label: symlinked."
    ((synced++))
  done

  _vscode_sync_setup_extensions

  echo
  printf "%sSummary: %d/%d items synced, %d skipped, %d failed.%s\n" \
    "$C_BOLD" "$synced" "$total" "$skipped" "$failed" "$C_RESET"
}

# -----------------------------------------------------------------------------
# vscode_sync_status
# -----------------------------------------------------------------------------
# Displays the current synchronization state of all managed items and
# extension symlinks. Shows whether each item is symlinked, independent,
# broken, or missing, along with a summary count.
#
# Usage:
#   vscode_sync_status
#
# Returns:
#   0 - Status displayed successfully.
#   1 - Platform check failed.
# -----------------------------------------------------------------------------
vscode_sync_status() {
  _shared_init_colors
  _vscode_sync_check_platform || return 1

  printf "%s%s[*] VS Code Sync Status%s\n\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  local synced=0 total=${#_VSCODE_SYNC_ITEMS[@]}
  local _label _source _target item sync_state dest

  for item in "${_VSCODE_SYNC_ITEMS[@]}"; do
    _vscode_sync_parse_item "$item"
    sync_state=$(_vscode_sync_item_status "$_source" "$_target")

    case "$sync_state" in
      synced)
        printf "  %s[SYNCED]%s  %-12s -> %s\n" "$C_GREEN" "$C_RESET" "$_label" "$_source"
        ((synced++)) ;;
      symlink_broken)
        dest=$(readlink "$_target" 2>/dev/null)
        printf "  %s[BROKEN]%s  %-12s -> %s (target missing)\n" "$C_RED" "$C_RESET" "$_label" "$dest" ;;
      symlink_wrong)
        dest=$(readlink "$_target" 2>/dev/null)
        printf "  %s[WRONG]%s   %-12s -> %s (expected: %s)\n" "$C_YELLOW" "$C_RESET" "$_label" "$dest" "$_source" ;;
      independent)
        printf "  %s[INDEP]%s   %-12s Regular file/directory (not synced)\n" "$C_YELLOW" "$C_RESET" "$_label" ;;
      missing)
        printf "  %s[MISS]%s    %-12s Target does not exist\n" "$C_RED" "$C_RESET" "$_label" ;;
      source_missing)
        printf "  %s[NO SRC]%s  %-12s Source not found: %s\n" "$C_RED" "$C_RESET" "$_label" "$_source" ;;
    esac
  done

  _vscode_sync_status_extensions

  echo
  printf "%sSummary: %d/%d items synced.%s\n" "$C_BOLD" "$synced" "$total" "$C_RESET"
}

# -----------------------------------------------------------------------------
# vscode_sync_check
# -----------------------------------------------------------------------------
# Validates the health of VS Code synchronization configuration.
# Checks source existence, symlink integrity, extension health, running
# processes, and backup state. Reports HEALTHY, DEGRADED, or UNHEALTHY.
#
# Usage:
#   vscode_sync_check
#
# Returns:
#   0 - Configuration is healthy or degraded (warnings only).
#   1 - Configuration is unhealthy (errors found) or platform unsupported.
# -----------------------------------------------------------------------------
vscode_sync_check() {
  _shared_init_colors
  _vscode_sync_check_platform || return 1

  printf "%s%s[*] VS Code Sync Health Check%s\n\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  local issues=0 warnings=0
  local _label _source _target item sync_state dest

  for item in "${_VSCODE_SYNC_ITEMS[@]}"; do
    _vscode_sync_parse_item "$item"
    printf "  %sChecking:%s %s\n" "$C_BOLD" "$C_RESET" "$_label"

    if [[ ! -e "$_source" ]]; then
      _shared_log error "    Source missing: $_source"
      ((issues++))
      continue
    fi

    if [[ ! -r "$_source" ]]; then
      _shared_log warn "    Source not readable: $_source"
      ((warnings++))
    fi

    sync_state=$(_vscode_sync_item_status "$_source" "$_target")

    case "$sync_state" in
      synced)
        _shared_log ok "    Symlink valid." ;;
      symlink_broken)
        _shared_log error "    Broken symlink: $_target"
        ((issues++)) ;;
      symlink_wrong)
        dest=$(readlink "$_target" 2>/dev/null)
        _shared_log warn "    Symlink points to unexpected target: $dest"
        ((warnings++)) ;;
      independent)
        _shared_log info "    Independent file/directory (not synced)." ;;
      missing)
        _shared_log info "    Target does not exist (not yet synced)." ;;
      source_missing)
        _shared_log error "    Source missing: $_source"
        ((issues++)) ;;
    esac

    if [[ -L "$_target" ]] && command -v realpath >/dev/null 2>&1; then
      if ! realpath "$_target" >/dev/null 2>&1; then
        _shared_log error "    Possible circular symlink: $_target"
        ((issues++))
      fi
    fi
  done

  _vscode_sync_check_extensions
  ((issues += _VSCODE_EXT_CHECK_ISSUES))
  ((warnings += _VSCODE_EXT_CHECK_WARNINGS))

  echo
  printf "  %sProcess check:%s\n" "$C_BOLD" "$C_RESET"
  if _vscode_sync_check_vscode_running 2>/dev/null; then
    _shared_log ok "    No VS Code processes running."
  else
    ((warnings++))
  fi

  printf "  %sBackup directory:%s\n" "$C_BOLD" "$C_RESET"
  if [[ -d "$_VSCODE_SYNC_BACKUP_DIR" ]]; then
    local backup_count
    backup_count=$(find "$_VSCODE_SYNC_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    _shared_log info "    ${backup_count} backup(s) in $_VSCODE_SYNC_BACKUP_DIR"
  else
    _shared_log info "    No backups yet."
  fi

  echo
  if ((issues > 0)); then
    printf "  %s%sHealth: UNHEALTHY%s (%d error(s), %d warning(s))\n" "$C_BOLD" "$C_RED" "$C_RESET" "$issues" "$warnings"
    return 1
  elif ((warnings > 0)); then
    printf "  %s%sHealth: DEGRADED%s (%d warning(s))\n" "$C_BOLD" "$C_YELLOW" "$C_RESET" "$warnings"
    return 0
  else
    printf "  %s%sHealth: HEALTHY%s\n" "$C_BOLD" "$C_GREEN" "$C_RESET"
    return 0
  fi
}

# -----------------------------------------------------------------------------
# vscode_sync_remove
# -----------------------------------------------------------------------------
# Removes symlinks and restores independent copies for VS Code Insiders.
# For valid symlinks, copies the actual content back before removing the
# symlink. For broken symlinks, simply removes them. Also removes
# per-extension symlinks (real directories for excluded extensions are kept).
#
# Usage:
#   vscode_sync_remove
#
# Returns:
#   0 - Removal completed (or aborted by user / nothing to do).
#   1 - Platform check failed.
# -----------------------------------------------------------------------------
vscode_sync_remove() {
  setopt localoptions localtraps nullglob
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_acquire_lock || return 1
  trap '_vscode_sync_release_lock' EXIT

  printf "%s%s[-] VS Code Sync Remove (Restore Independence)%s\n\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  _vscode_sync_check_vscode_running || {
    _shared_log warn "Consider closing both editors before proceeding."
    echo
  }

  printf "%sPlanned actions:%s\n" "$C_BOLD" "$C_RESET"
  local _label _source _target item dest
  local any_action=false
  for item in "${_VSCODE_SYNC_ITEMS[@]}"; do
    _vscode_sync_parse_item "$item"
    if [[ -L "$_target" ]]; then
      dest=$(readlink "$_target" 2>/dev/null)
      if [[ -e "$_target" ]]; then
        printf "  %s[COPY+RM]%s %-12s Copy content back, remove symlink\n" "$C_BLUE" "$C_RESET" "$_label"
      else
        printf "  %s[RM]%s      %-12s Remove broken symlink (-> %s)\n" "$C_RED" "$C_RESET" "$_label" "$dest"
      fi
      any_action=true
    else
      printf "  %s[SKIP]%s    %-12s Not a symlink\n" "$C_GREEN" "$C_RESET" "$_label"
    fi
  done

  # Extensions planned actions preview.
  if [[ -L "$_VSCODE_EXTENSIONS_DST" ]]; then
    printf "  %s[RM]%s      %-12s Legacy directory symlink will be removed\n" \
      "$C_RED" "$C_RESET" "Extensions"
    any_action=true
  elif [[ -d "$_VSCODE_EXTENSIONS_DST" ]]; then
    local ext_rm_count=0 link_path
    for link_path in "$_VSCODE_EXTENSIONS_DST"/*/; do
      [[ -L "${link_path%/}" ]] && ((ext_rm_count++))
    done
    if ((ext_rm_count > 0)); then
      printf "  %s[RM]%s      %-12s %d symlink(s) will be removed\n" \
        "$C_RED" "$C_RESET" "Extensions" "$ext_rm_count"
      any_action=true
    else
      printf "  %s[SKIP]%s    %-12s No symlinks to remove\n" "$C_GREEN" "$C_RESET" "Extensions"
    fi
  else
    printf "  %s[SKIP]%s    %-12s Directory does not exist\n" "$C_GREEN" "$C_RESET" "Extensions"
  fi
  echo

  if [[ "$any_action" == false ]]; then
    _shared_log info "Nothing to remove. No symlinks found."
    return 0
  fi

  _shared_confirm "Remove symlinks and restore independent copies?" || {
    _shared_log info "Aborted by user."
    return 0
  }
  echo

  local restored=0 removed=0 skipped=0 failed=0 total=${#_VSCODE_SYNC_ITEMS[@]}
  for item in "${_VSCODE_SYNC_ITEMS[@]}"; do
    _vscode_sync_parse_item "$item"

    if [[ ! -L "$_target" ]]; then
      ((skipped++))
      continue
    fi

    if [[ -e "$_target" ]]; then
      local tmp_target="${_target}.vscode_sync_tmp.$$"
      if [[ -d "$_source" ]]; then
        cp -R "$_source" "$tmp_target" || {
          _shared_log error "$_label: failed to copy directory content."
          ((failed++))
          continue
        }
      else
        cp "$_source" "$tmp_target" || {
          _shared_log error "$_label: failed to copy file content."
          ((failed++))
          continue
        }
      fi
      rm -f "$_target" || {
        _shared_log error "$_label: failed to remove symlink."
        rm -rf "$tmp_target" 2>/dev/null
        ((failed++))
        continue
      }
      mv "$tmp_target" "$_target" || {
        _shared_log error "$_label: failed to move restored content into place."
        ((failed++))
        continue
      }
      _shared_log ok "$_label: restored independent copy."
      ((restored++))
    else
      rm -f "$_target" || {
        _shared_log error "$_label: failed to remove broken symlink."
        ((failed++))
        continue
      }
      _shared_log ok "$_label: removed broken symlink."
      ((removed++))
    fi
  done

  _vscode_sync_remove_extensions

  echo
  printf "%sSummary: %d restored, %d broken removed, %d skipped, %d failed.%s\n" \
    "$C_BOLD" "$restored" "$removed" "$skipped" "$failed" "$C_RESET"
}

# ============================================================================ #
# Source-time initialization.
_vscode_sync_init_config
# End of script.
