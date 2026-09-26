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
_VSCODE_SYNC_PROFILE_SNAPSHOT_RETENTION=5

# Platform-aware config: populated by _vscode_sync_init_config at source time.
_VSCODE_EXTENSIONS_SRC=""
_VSCODE_EXTENSIONS_DST=""
_VSCODE_EXTENSIONS_EXCLUDE=()
_VSCODE_USER_STABLE=""
_VSCODE_USER_INSIDERS=""

# Output vars for _vscode_sync_check_extensions (read by vscode_sync_check).
_VSCODE_EXT_CHECK_ISSUES=0
_VSCODE_EXT_CHECK_WARNINGS=0

# +++++++++++++++++++++++++++++ HELPER UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_sync_acquire_lock
# @internal
# @description Acquires the mkdir-based sync lock for mutating operations
# (setup, remove), reclaiming a stale lock left by a dead process.
# @noargs
# @exitcode 1 If another instance is running or the lock cannot be created.
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

# -----------------------------------------------------------------------------
# _vscode_sync_release_lock
# @internal
# @description Releases the sync lock; safe to call even if not held.
# @noargs
# -----------------------------------------------------------------------------
_vscode_sync_release_lock() {
  rm -f "$_VSCODE_SYNC_LOCK_DIR/pid" 2>/dev/null
  rmdir "$_VSCODE_SYNC_LOCK_DIR" 2>/dev/null
}

# -----------------------------------------------------------------------------
# _vscode_sync_check_platform
# @internal
# @description Verifies the platform is macOS or Linux; logs an error if not.
# @noargs
# @exitcode 1 If the platform is unsupported.
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
# _vscode_sync_check_vscode_running
# @internal
# @description Detects running VS Code Stable/Insiders processes (macOS .app
# or Linux process name), warning for each instance found.
# @noargs
# @exitcode 1 If one or more VS Code processes are running.
# -----------------------------------------------------------------------------
_vscode_sync_check_vscode_running() {
  local stable_running=0 insiders_running=0

  if pgrep -qf "/Visual Studio Code\.app/Contents/MacOS/" 2>/dev/null; then
    stable_running=1
  fi
  if pgrep -qf "/Visual Studio Code - Insiders\.app/Contents/MacOS/" 2>/dev/null; then
    insiders_running=1
  fi

  if pgrep -qf '(^|[/[:space:]])code($|[[:space:]])' 2>/dev/null \
    || pgrep -qx "code" 2>/dev/null; then
    stable_running=1
  fi
  if pgrep -qf '(^|[/[:space:]])code-insiders($|[[:space:]])' 2>/dev/null \
    || pgrep -qx "code-insiders" 2>/dev/null; then
    insiders_running=1
  fi

  (( stable_running )) && _shared_log warn "VS Code Stable appears to be running."
  (( insiders_running )) && _shared_log warn "VS Code Insiders appears to be running."

  (( stable_running == 0 && insiders_running == 0 ))
}

# -----------------------------------------------------------------------------
# _vscode_sync_path_is_within_home
# @internal
# @description Validates that a path is anchored within HOME.
# @arg $1 path Path to validate.
# @exitcode 1 If the path is empty or outside HOME.
# -----------------------------------------------------------------------------
_vscode_sync_path_is_within_home() {
  local path="$1"
  [[ -n "$path" ]] || return 1

  local canonical_home="${HOME:a}"
  local canonical_path="${path:a}"
  [[ "$canonical_path" == "$canonical_home" || "$canonical_path" == "${canonical_home}/"* ]]
}

# -----------------------------------------------------------------------------
# _vscode_sync_prune_backup_dirs
# @internal
# @description Retains only the newest _VSCODE_SYNC_PROFILE_SNAPSHOT_RETENTION
# profile-state snapshot directories; names are timestamp-prefixed so sort
# order is stable. Other backup subtypes (quarantine, sync items) are pruned
# per subtype by the Python backend and are never touched here.
# @noargs
# @exitcode 1 If the backup root is anchored outside HOME.
# -----------------------------------------------------------------------------
_vscode_sync_prune_backup_dirs() {
  local keep_count="${_VSCODE_SYNC_PROFILE_SNAPSHOT_RETENTION:-5}"
  [[ "$keep_count" == <-> ]] || keep_count=5
  (( keep_count > 0 )) || keep_count=5

  [[ -d "$_VSCODE_SYNC_BACKUP_DIR" ]] || return 0
  if ! _vscode_sync_path_is_within_home "$_VSCODE_SYNC_BACKUP_DIR"; then
    _shared_log error "Refusing to prune snapshots outside HOME: $_VSCODE_SYNC_BACKUP_DIR"
    return 1
  fi

  local -a backup_dirs prune_dirs
  backup_dirs=("${(@f)$(
    find "$_VSCODE_SYNC_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
      -name "*_profile-state" 2>/dev/null |
      LC_ALL=C sort
  )}")

  (( ${#backup_dirs[@]} > keep_count )) || return 0
  prune_dirs=("${backup_dirs[@]:0:${#backup_dirs[@]}-keep_count}")

  local backup_path
  for backup_path in "${prune_dirs[@]}"; do
    [[ -n "$backup_path" ]] || continue
    if ! _vscode_sync_path_is_within_home "$backup_path"; then
      _shared_log warn "Skipping unsafe backup prune target: $backup_path"
      continue
    fi
    if [[ "${backup_path:a:h}" != "${_VSCODE_SYNC_BACKUP_DIR:a}" ]]; then
      _shared_log warn "Skipping non-direct backup entry: $backup_path"
      continue
    fi
    rm -rf -- "$backup_path" 2>/dev/null || {
      _shared_log warn "Failed to prune old backup directory: $backup_path"
      continue
    }
    _shared_log info "Pruned old backup directory: $backup_path"
  done

  return 0
}

# -----------------------------------------------------------------------------
# _vscode_sync_backup_profile_state
# @internal
# @description Snapshots state.vscdb and root/profile extensions manifests for
# Stable and Insiders before a mutating operation, to support manual rollback.
# @noargs
# @exitcode 1 If the snapshot cannot be created.
# -----------------------------------------------------------------------------
_vscode_sync_backup_profile_state() {
  local state_stable="${_VSCODE_USER_STABLE}/globalStorage/state.vscdb"
  local state_insiders="${_VSCODE_USER_INSIDERS}/globalStorage/state.vscdb"
  local -a manifest_candidates=(
    "${_VSCODE_EXTENSIONS_SRC}/extensions.json"
    "${_VSCODE_EXTENSIONS_DST}/extensions.json"
  )
  local manifest_path profile_root
  local has_snapshot_inputs=false

  local timestamp snapshot_dir copied=0
  timestamp="$(date +%Y%m%d_%H%M%S)_$$"
  snapshot_dir="${_VSCODE_SYNC_BACKUP_DIR}/${timestamp}_profile-state"

  if [[ -f "$state_stable" || -f "$state_insiders" ]]; then
    has_snapshot_inputs=true
  fi
  for manifest_path in "${manifest_candidates[@]}"; do
    if [[ -f "$manifest_path" ]]; then
      has_snapshot_inputs=true
      break
    fi
  done
  if ! $has_snapshot_inputs; then
    for profile_root in \
      "${_VSCODE_USER_STABLE}/profiles" \
      "${_VSCODE_USER_INSIDERS}/profiles"; do
      if [[ -d "$profile_root" ]]; then
        has_snapshot_inputs=true
        break
      fi
    done
  fi

  if ! $has_snapshot_inputs; then
    _shared_log info "Profile state snapshot: no profile state or manifest files found."
    return 0
  fi

  mkdir -p "$snapshot_dir" || {
    _shared_log error "Profile state snapshot failed: cannot create $snapshot_dir"
    return 1
  }
  chmod 700 "$snapshot_dir" 2>/dev/null

  if [[ -f "$state_stable" ]]; then
    cp "$state_stable" "$snapshot_dir/state.stable.vscdb" || {
      _shared_log error "Profile state snapshot failed for Stable: $state_stable"
      return 1
    }
    ((copied++))
  fi

  if [[ -f "$state_insiders" ]]; then
    cp "$state_insiders" "$snapshot_dir/state.insiders.vscdb" || {
      _shared_log error "Profile state snapshot failed for Insiders: $state_insiders"
      return 1
    }
    ((copied++))
  fi

  local manifests_snapshot_dir="${snapshot_dir}/manifests"
  local manifest_dest

  for manifest_path in "${manifest_candidates[@]}"; do
    [[ -f "$manifest_path" ]] || continue
    manifest_dest="${manifests_snapshot_dir}/${manifest_path#${HOME}/}"
    mkdir -p "${manifest_dest:h}" || {
      _shared_log error "Profile state snapshot failed: cannot create ${manifest_dest:h}"
      return 1
    }
    cp "$manifest_path" "$manifest_dest" || {
      _shared_log error "Profile state snapshot failed for manifest: $manifest_path"
      return 1
    }
    ((copied++))
  done

  for profile_root in \
    "${_VSCODE_USER_STABLE}/profiles" \
    "${_VSCODE_USER_INSIDERS}/profiles"; do
    [[ -d "$profile_root" ]] || continue
    while IFS= read -r manifest_path; do
      [[ -n "$manifest_path" ]] || continue
      manifest_dest="${manifests_snapshot_dir}/${manifest_path#${HOME}/}"
      mkdir -p "${manifest_dest:h}" || {
        _shared_log error "Profile state snapshot failed: cannot create ${manifest_dest:h}"
        return 1
      }
      cp "$manifest_path" "$manifest_dest" || {
        _shared_log error "Profile state snapshot failed for profile manifest: $manifest_path"
        return 1
      }
      ((copied++))
    done < <(
      find "$profile_root" -mindepth 2 -maxdepth 2 -type f -name "extensions.json" 2>/dev/null |
        LC_ALL=C sort
    )
  done

  if (( copied > 0 )); then
    _shared_log ok "Profile state snapshot created: $snapshot_dir"
    _vscode_sync_prune_backup_dirs || {
      _shared_log warn "Backup retention could not be fully applied."
    }
  fi
  return 0
}

# ++++++++++++++++++++++ PLATFORM-AWARE CONFIG INIT ++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_sync_init_config
# @internal
# @description Initializes platform-aware VS Code user roots and extension
# paths; called automatically at source time (end of this file).
# @noargs
# @set _VSCODE_USER_STABLE path Stable user-data root.
# @set _VSCODE_USER_INSIDERS path Insiders user-data root.
# @set _VSCODE_EXTENSIONS_SRC path Canonical extensions directory (Stable).
# @set _VSCODE_EXTENSIONS_DST path Insiders extensions directory.
# @set _VSCODE_EXTENSIONS_EXCLUDE array Glob patterns for excluded extensions.
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

  _VSCODE_USER_STABLE="$user_stable"
  _VSCODE_USER_INSIDERS="$user_insiders"

  _VSCODE_EXTENSIONS_SRC="${HOME}/.vscode/extensions"
  _VSCODE_EXTENSIONS_DST="${HOME}/.vscode-insiders/extensions"
  _VSCODE_EXTENSIONS_EXCLUDE=(
    "anthropic.claude-code-*"  # Platform-specific binary (Mach-O arm64 != linux-x64)
    "github.copilot-*"         # Version-incompatible between Stable and Insiders
  )
}

# ============================================================================ #
# End of vscode/sync/_core.zsh
