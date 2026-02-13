#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++ VS CODE SYNC (Stable <-> Insiders) ++++++++++++++++++++ #
# ============================================================================ #
# Symlink-based synchronization of VS Code settings and extensions between
# VS Code Stable and VS Code Insiders on macOS.
#
# This script manages:
#  - Extensions directory (~/.vscode/extensions -> ~/.vscode-insiders/extensions)
#  - User settings (settings.json, keybindings.json, mcp.json)
#  - Snippets and profiles directories
#  - Backup creation before destructive operations
#  - Status reporting and health checks
#  - Clean removal with content restoration
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

# ++++++++++++++++++++++++++++ SYNC CONFIGURATION ++++++++++++++++++++++++++++ #

# Each entry: "label|source_path|target_path"
# Source = VS Code Stable (canonical copy)
# Target = VS Code Insiders (will become a symlink)
_VSCODE_SYNC_ITEMS=(
  "Extensions|${HOME}/.vscode/extensions|${HOME}/.vscode-insiders/extensions"
  "Settings|${HOME}/Library/Application Support/Code/User/settings.json|${HOME}/Library/Application Support/Code - Insiders/User/settings.json"
  "Keybindings|${HOME}/Library/Application Support/Code/User/keybindings.json|${HOME}/Library/Application Support/Code - Insiders/User/keybindings.json"
  "Snippets|${HOME}/Library/Application Support/Code/User/snippets|${HOME}/Library/Application Support/Code - Insiders/User/snippets"
  "MCP Config|${HOME}/Library/Application Support/Code/User/mcp.json|${HOME}/Library/Application Support/Code - Insiders/User/mcp.json"
)
# NOTE: VS Code profiles are NOT included here. Profile definitions and
# extension-profile associations live in globalStorage/state.vscdb (SQLite),
# not in the profiles/ directory. Use VS Code's built-in Settings Sync or
# manual Profile Export/Import to synchronize profiles across editions.

_VSCODE_SYNC_BACKUP_DIR="${HOME}/.local/share/vscode-sync-backups"

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

# +++++++++++++++++++++++++++++ HELPER UTILITIES +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_sync_check_platform
# -----------------------------------------------------------------------------
# Verifies the script is running on macOS (Darwin).
# This script only supports macOS paths and conventions.
#
# Usage:
#   _vscode_sync_check_platform
#
# Returns:
#   0 - Running on macOS.
#   1 - Not on macOS.
#
# Side Effects:
#   - Logs error message if not on macOS.
# -----------------------------------------------------------------------------
_vscode_sync_check_platform() {
  _shared_detect_platform
  if [[ "${SHARED_PLATFORM:-unknown}" != "macOS" ]]; then
    _shared_log error "This script only supports macOS. Detected: ${SHARED_PLATFORM:-unknown}"
    return 1
  fi
  return 0
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
# Uses pgrep to detect running Electron processes.
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
  if pgrep -qf "Visual Studio Code\.app" 2>/dev/null; then
    _shared_log warn "VS Code Stable appears to be running."
    running=1
  fi
  if pgrep -qf "Visual Studio Code - Insiders\.app" 2>/dev/null; then
    _shared_log warn "VS Code Insiders appears to be running."
    running=1
  fi
  return $running
}

# -----------------------------------------------------------------------------
# _vscode_sync_ensure_parent_dir
# -----------------------------------------------------------------------------
# Creates parent directory for a target path if it does not exist.
# Handles the case where VS Code Insiders User directory has not been
# created yet (e.g., app was never opened).
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
#
# Side Effects:
#   - May create directories on disk.
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
# Backups are stored in ~/.local/share/vscode-sync-backups/<timestamp>/.
# Handles both files and directories.
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
#
# Side Effects:
#   - Creates backup directory and copies content.
# -----------------------------------------------------------------------------
_vscode_sync_backup_item() {
  local label="$1" target="$2"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="${_VSCODE_SYNC_BACKUP_DIR}/${timestamp}"

  mkdir -p "$backup_dir" || {
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
# Checks source existence, target type (symlink, file, missing),
# and symlink validity.
#
# Usage:
#   sync_state=$(_vscode_sync_item_status <source> <target>)
#
# Arguments:
#   source - Path to VS Code Stable item (required).
#   target - Path to VS Code Insiders item (required).
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

# +++++++++++++++++++++++++++ MAIN SYNC FUNCTIONS ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# vscode_sync_setup
# -----------------------------------------------------------------------------
# Creates symlinks from VS Code Stable to VS Code Insiders.
# Displays a plan of actions, asks for confirmation, backs up existing
# targets, and creates symlinks. Idempotent: already-synced items are
# skipped without modification.
#
# Usage:
#   vscode_sync_setup
#
# Returns:
#   0 - Setup completed (or aborted by user).
#   1 - Platform check failed.
#
# Side Effects:
#   - Creates symlinks in VS Code Insiders config directories.
#   - Backs up existing Insiders files to ~/.local/share/vscode-sync-backups/.
#   - May create parent directories for Insiders config.
# -----------------------------------------------------------------------------
vscode_sync_setup() {
  _shared_init_colors
  _vscode_sync_check_platform || return 1

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

  echo
  printf "%sSummary: %d/%d synced, %d skipped, %d failed.%s\n" \
    "$C_BOLD" "$synced" "$total" "$skipped" "$failed" "$C_RESET"
}

# -----------------------------------------------------------------------------
# vscode_sync_status
# -----------------------------------------------------------------------------
# Displays the current synchronization state of all managed items.
# Shows whether each item is symlinked, independent, broken, or missing,
# along with symlink target paths and a summary count.
#
# Usage:
#   vscode_sync_status
#
# Returns:
#   0 - Status displayed successfully.
#   1 - Platform check failed.
#
# Side Effects:
#   - Outputs formatted status report to stdout.
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

  echo
  printf "%sSummary: %d/%d items synced.%s\n" "$C_BOLD" "$synced" "$total" "$C_RESET"
}

# -----------------------------------------------------------------------------
# vscode_sync_check
# -----------------------------------------------------------------------------
# Validates the health of VS Code synchronization configuration.
# Checks source file existence, symlink integrity, permissions, circular
# symlinks, running processes, and backup state. Reports overall health
# as HEALTHY, DEGRADED, or UNHEALTHY.
#
# Usage:
#   vscode_sync_check
#
# Returns:
#   0 - Configuration is healthy or degraded (warnings only).
#   1 - Configuration is unhealthy (errors found) or platform unsupported.
#
# Side Effects:
#   - Outputs formatted health report to stdout/stderr.
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

    if [[ -L "$_target" ]]; then
      if ! realpath "$_target" >/dev/null 2>&1; then
        _shared_log error "    Possible circular symlink: $_target"
        ((issues++))
      fi
    fi
  done

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
# symlink. For broken symlinks, simply removes them. Uses an atomic
# temp-copy-then-rename pattern to avoid data loss.
#
# Usage:
#   vscode_sync_remove
#
# Returns:
#   0 - Removal completed (or aborted by user / nothing to do).
#   1 - Platform check failed.
#
# Side Effects:
#   - Removes symlinks in VS Code Insiders config directories.
#   - Creates independent copies of configuration files.
# -----------------------------------------------------------------------------
vscode_sync_remove() {
  _shared_init_colors
  _vscode_sync_check_platform || return 1

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

  echo
  printf "%sSummary: %d restored, %d broken removed, %d skipped, %d failed.%s\n" \
    "$C_BOLD" "$restored" "$removed" "$skipped" "$failed" "$C_RESET"
}

# ============================================================================ #
# End of script.
