#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ VS CODE SYNC COMMANDS LAYER ++++++++++++++++++++++++ #
# ============================================================================ #
# Thin shell wrappers for the VS Code sync workflow.
# Python is the source of truth for sync planning and apply logic; this layer
# keeps the public zsh command surface, confirmation prompts, and locks.
# ============================================================================ #

# -----------------------------------------------------------------------------
# _vscode_sync_run_python_command
# -----------------------------------------------------------------------------
# Delegates a Python sync subcommand to the extensions module with standard
# arguments (source, destination, --home).
#
# Usage:
#   _vscode_sync_run_python_command <subcommand> [--extra-args ...]
#
# Arguments:
#   subcommand - Python subcommand name (e.g. sync-status, sync-setup).
#   ...        - Additional arguments forwarded to the Python script.
#
# Returns:
#   Exit code from _vscode_sync_extensions_run_python.
# -----------------------------------------------------------------------------
_vscode_sync_run_python_command() {
  local subcommand="$1"
  shift
  _vscode_sync_extensions_run_python \
    "$subcommand" \
    "$_VSCODE_EXTENSIONS_SRC" \
    "$_VSCODE_EXTENSIONS_DST" \
    --home "$HOME" \
    "$@"
}

# -----------------------------------------------------------------------------
# _vscode_sync_update_usage
# -----------------------------------------------------------------------------
# Prints usage help for the vscode_sync_update command to stdout.
#
# Usage:
#   _vscode_sync_update_usage
# -----------------------------------------------------------------------------
_vscode_sync_update_usage() {
  printf "%s\n" \
    "Usage:" \
    "  vscode_sync_update [--dry-run|-n] [--skip-clean]" \
    "" \
    "Options:" \
    "  --dry-run, -n  Show the planned update/repair workflow without changing anything." \
    "  --skip-clean   Skip duplicate cleanup in the shared Stable extensions root." \
    "  --help, -h     Show this help message."
}

# -----------------------------------------------------------------------------
# vscode_sync_setup
# -----------------------------------------------------------------------------
# Interactive setup: mirrors Stable extensions into Insiders via symlinks.
# Requires no VS Code instances running; acquires lock and creates a profile
# state snapshot before delegating to the Python sync-setup subcommand.
#
# Usage:
#   vscode_sync_setup
#
# Returns:
#   0 - Setup completed or aborted by user.
#   1 - Platform check, Python check, lock, or VS Code running.
# -----------------------------------------------------------------------------
vscode_sync_setup() {
  setopt localoptions localtraps
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_extensions_require_python || return 1
  _vscode_sync_acquire_lock || return 1
  trap '_vscode_sync_release_lock' EXIT

  _shared_banner "VS Code Sync Setup" "Stable -> Insiders"

  if ! _vscode_sync_check_vscode_running; then
    _shared_log error "Refusing to run setup while VS Code is open."
    _shared_log error "Close VS Code Stable and Insiders, then retry."
    return 1
  fi

  _shared_section "Current State"
  _vscode_sync_run_python_command sync-status || return 1
  printf "\n"
  _shared_log warn "Extension sync mirrors Stable installed extensions into Insiders (except exclusions)."
  _shared_log info "Profile manifests use safe update-only rebinds for version/location drift."
  _shared_log info "Manifest removals stay read-only, and manifest-named folders stay protected during cleanup."
  printf "\n"

  _shared_confirm "Proceed with setup?" || {
    _shared_log info "Aborted by user."
    return 0
  }
  echo

  _vscode_sync_backup_profile_state || {
    _shared_log error "Aborting: failed to snapshot profile state."
    return 1
  }

  _vscode_sync_run_python_command sync-setup
}

# -----------------------------------------------------------------------------
# vscode_sync_update
# -----------------------------------------------------------------------------
# Maintains the shared extensions root and reconciles Insiders state.
# Supports --dry-run for a read-only preview, and --skip-clean to skip
# duplicate cleanup in the shared Stable root. Acquires lock and requires
# no VS Code instances running (unless dry-run).
#
# Usage:
#   vscode_sync_update [--dry-run|-n] [--skip-clean] [--help|-h]
#
# Options:
#   --dry-run, -n  Show planned actions without making changes.
#   --skip-clean   Skip duplicate cleanup in the shared Stable extensions root.
#   --help, -h     Show usage help.
#
# Returns:
#   0 - Update completed or aborted by user.
#   1 - Platform, Python, lock, VS Code running, or extension issues.
#   2 - Unknown option.
# -----------------------------------------------------------------------------
vscode_sync_update() {
  setopt localoptions localtraps
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_extensions_require_python || return 1

  local dry_run=false
  local skip_clean=false
  local arg
  for arg in "$@"; do
    case "$arg" in
    --dry-run | -n) dry_run=true ;;
    --skip-clean) skip_clean=true ;;
    --help | -h)
      _vscode_sync_update_usage
      return 0
      ;;
    *)
      _shared_log error "Unknown option: $arg"
      _vscode_sync_update_usage
      return 2
      ;;
    esac
  done

  _shared_banner "VS Code Extension Update" "Shared root maintenance and Insiders reconcile"

  if [[ "$dry_run" != "true" ]]; then
    _vscode_sync_acquire_lock || return 1
    trap '_vscode_sync_release_lock' EXIT
  fi

  if [[ "$dry_run" == "true" ]]; then
    local -a plan_args=(sync-update)
    [[ "$skip_clean" == "true" ]] && plan_args+=(--skip-clean)
    _shared_section "Planned Actions"
    _vscode_sync_run_python_command "${plan_args[@]}"
    return $?
  fi

  if ! _vscode_sync_check_vscode_running; then
    _shared_log error "Refusing to run update while VS Code is open."
    _shared_log error "Close VS Code Stable and Insiders, then retry."
    return 1
  fi

  _vscode_sync_check_extensions || return 1
  if ((_VSCODE_EXT_CHECK_ISSUES > 0)); then
    _shared_log error "Refusing to run update while extension state has unresolved issues."
    _shared_log error "Repair or re-import profiles first, then retry."
    return 1
  fi

  _shared_section "Planned Actions"
  local -a preview_args=(sync-update)
  [[ "$skip_clean" == "true" ]] && preview_args+=(--skip-clean)
  _vscode_sync_run_python_command "${preview_args[@]}" || return 1
  printf "\n"

  _shared_confirm "Proceed with update and repair?" || {
    _shared_log info "Aborted by user."
    return 0
  }
  echo

  _vscode_sync_backup_profile_state || {
    _shared_log error "Aborting: failed to snapshot profile state."
    return 1
  }

  local -a apply_args=(sync-update --apply)
  [[ "$skip_clean" == "true" ]] && apply_args+=(--skip-clean)
  _vscode_sync_run_python_command "${apply_args[@]}"
}

# -----------------------------------------------------------------------------
# vscode_update_extensions
# -----------------------------------------------------------------------------
# Compatibility alias for vscode_sync_update. Forwards all arguments unchanged.
#
# Usage:
#   vscode_update_extensions [--dry-run|-n] [--skip-clean]
# -----------------------------------------------------------------------------
vscode_update_extensions() {
  vscode_sync_update "$@"
}

# -----------------------------------------------------------------------------
# vscode_sync_status
# -----------------------------------------------------------------------------
# Displays current sync state by delegating to the Python sync-status
# subcommand. No lock is acquired; safe to run while VS Code is open.
#
# Usage:
#   vscode_sync_status
#
# Returns:
#   0 - Status displayed successfully.
#   1 - Platform check, Python check, or sync-status failed.
# -----------------------------------------------------------------------------
vscode_sync_status() {
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_extensions_require_python || return 1

  _shared_banner "VS Code Sync Status"
  _vscode_sync_run_python_command sync-status
}

# -----------------------------------------------------------------------------
# vscode_sync_check
# -----------------------------------------------------------------------------
# Runs a health check: Python sync-check, VS Code process detection, and
# backup directory inspection. Reports overall health as HEALTHY, DEGRADED,
# or UNHEALTHY based on issue and warning counts.
#
# Usage:
#   vscode_sync_check
#
# Returns:
#   0 - HEALTHY or DEGRADED state.
#   1 - UNHEALTHY state (one or more errors).
# -----------------------------------------------------------------------------
vscode_sync_check() {
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_extensions_require_python || return 1

  _shared_banner "VS Code Sync Health Check"

  local check_output
  check_output="$(_vscode_sync_run_python_command sync-check 2>&1)"
  local check_status=$?
  printf "%s\n" "$check_output"

  local issues warnings
  issues=$(printf "%s\n" "$check_output" | awk -F= '/^ISSUES=/{value=$2} END{print value+0}')
  warnings=$(printf "%s\n" "$check_output" | awk -F= '/^WARNINGS=/{value=$2} END{print value+0}')

  printf "\n"
  _shared_section "Environment"
  if _vscode_sync_check_vscode_running 2>/dev/null; then
    _shared_log ok "No VS Code processes running."
  else
    ((warnings++))
  fi

  if [[ -d "$_VSCODE_SYNC_BACKUP_DIR" ]]; then
    local -a backup_dirs
    backup_dirs=("$_VSCODE_SYNC_BACKUP_DIR"/*(N/))
    _shared_log info "${#backup_dirs[@]} backup(s) in $_VSCODE_SYNC_BACKUP_DIR"
  else
    _shared_log info "No backups yet."
  fi

  printf "\n"
  if ((issues > 0)); then
    printf "%s%sHealth: UNHEALTHY%s (%d error(s), %d warning(s))\n" "$C_BOLD" "$C_RED" "$C_RESET" "$issues" "$warnings"
    return 1
  fi
  if ((warnings > 0)); then
    printf "%s%sHealth: DEGRADED%s (%d warning(s))\n" "$C_BOLD" "$C_YELLOW" "$C_RESET" "$warnings"
    return 0
  fi

  printf "%s%sHealth: HEALTHY%s\n" "$C_BOLD" "$C_GREEN" "$C_RESET"
  return $check_status
}

# -----------------------------------------------------------------------------
# vscode_sync_remove
# -----------------------------------------------------------------------------
# Interactive removal: replaces symlinks with independent copies, restoring
# Insiders extension independence. Requires no VS Code instances running;
# acquires lock and creates a profile state snapshot before delegating to
# the Python sync-remove subcommand.
#
# Usage:
#   vscode_sync_remove
#
# Returns:
#   0 - Removal completed or aborted by user.
#   1 - Platform check, Python check, lock, or VS Code running.
# -----------------------------------------------------------------------------
vscode_sync_remove() {
  setopt localoptions localtraps
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_extensions_require_python || return 1
  _vscode_sync_acquire_lock || return 1
  trap '_vscode_sync_release_lock' EXIT

  _shared_banner "VS Code Sync Remove" "Restore independence for Insiders"

  if ! _vscode_sync_check_vscode_running; then
    _shared_log error "Refusing to run remove while VS Code is open."
    _shared_log error "Close VS Code Stable and Insiders, then retry."
    return 1
  fi

  _shared_section "Current State"
  _vscode_sync_run_python_command sync-status || return 1
  printf "\n"

  _shared_confirm "Remove symlinks and restore independent copies?" || {
    _shared_log info "Aborted by user."
    return 0
  }
  echo

  _vscode_sync_backup_profile_state || {
    _shared_log error "Aborting: failed to snapshot profile state."
    return 1
  }

  _vscode_sync_run_python_command sync-remove
}

# ============================================================================ #
# End of script.
