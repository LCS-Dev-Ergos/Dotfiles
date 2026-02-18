#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ VS CODE SYNC CORE LAYER ++++++++++++++++++++++++++ #
# ============================================================================ #
# Internal core for VS Code sync:
#  - static/path configuration
#  - platform and process checks
#  - lock, backup, and generic sync helper primitives
# Used by extension and command submodules.
# ============================================================================ #

# +++++++++++++++++++++++++++ STATIC CONFIGURATION +++++++++++++++++++++++++++ #

# NOTE: VS Code profiles are NOT included in sync items. Profile definitions
# live in globalStorage/state.vscdb (SQLite). Use VS Code's built-in Settings
# Sync or manual Profile Export/Import to synchronize profiles across editions.

_VSCODE_SYNC_BACKUP_DIR="${HOME}/.local/share/vscode-sync-backups"
_VSCODE_SYNC_LOCK_DIR="${HOME}/.cache/vscode_sync.lock"

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
  local lock_parent
  lock_parent="${_VSCODE_SYNC_LOCK_DIR%/*}"
  mkdir -p "$lock_parent" 2>/dev/null || {
    _shared_log error "Failed to create lock parent directory: $lock_parent"
    return 1
  }

  if [[ -e "$_VSCODE_SYNC_LOCK_DIR" && ! -d "$_VSCODE_SYNC_LOCK_DIR" ]]; then
    _shared_log error "Lock path exists and is not a directory: $_VSCODE_SYNC_LOCK_DIR"
    return 1
  fi

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

  rm -f "$_VSCODE_SYNC_LOCK_DIR/pid" 2>/dev/null
  if ! rmdir "$_VSCODE_SYNC_LOCK_DIR" 2>/dev/null; then
    _shared_log error "Failed to reclaim stale lock directory: $_VSCODE_SYNC_LOCK_DIR"
    return 1
  fi

  if mkdir "$_VSCODE_SYNC_LOCK_DIR" 2>/dev/null; then
    printf "%s" "$$" > "$_VSCODE_SYNC_LOCK_DIR/pid"
    return 0
  fi
  _shared_log error "Failed to acquire lock."
  return 1
}

_vscode_sync_release_lock() {
  rm -f "$_VSCODE_SYNC_LOCK_DIR/pid" 2>/dev/null
  rmdir "$_VSCODE_SYNC_LOCK_DIR" 2>/dev/null
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
# _vscode_sync_path_is_within_home
# -----------------------------------------------------------------------------
# Validates that a path is anchored within HOME.
#
# Usage:
#   _vscode_sync_path_is_within_home <path>
# -----------------------------------------------------------------------------
_vscode_sync_path_is_within_home() {
  local path="$1"
  [[ -n "$path" && "$path" == "${HOME}/"* ]]
}

# -----------------------------------------------------------------------------
# _vscode_sync_validate_extensions_paths
# -----------------------------------------------------------------------------
# Ensures extension source/target roots are inside HOME before mutating ops.
# -----------------------------------------------------------------------------
_vscode_sync_validate_extensions_paths() {
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  if ! _vscode_sync_path_is_within_home "$src"; then
    _shared_log error "Extensions source path outside HOME: $src"
    return 1
  fi
  if ! _vscode_sync_path_is_within_home "$dst"; then
    _shared_log error "Extensions target path outside HOME: $dst"
    return 1
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

  mkdir -p "$backup_dir" || {
    _shared_log error "Failed to create backup directory: $backup_dir"
    return 1
  }
  chmod 700 "$backup_dir" 2>/dev/null

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

# ============================================================================ #
# End of script.
