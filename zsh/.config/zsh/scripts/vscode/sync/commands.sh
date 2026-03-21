#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ VS CODE SYNC COMMANDS LAYER ++++++++++++++++++++++++ #
# ============================================================================ #
# Thin shell wrappers for the VS Code sync workflow.
# Python is the source of truth for sync planning and apply logic; this layer
# keeps the public zsh command surface, confirmation prompts, and locks.
# ============================================================================ #

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
      --dry-run|-n) dry_run=true ;;
      --skip-clean) skip_clean=true ;;
      --help|-h)
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
  if (( _VSCODE_EXT_CHECK_ISSUES > 0 )); then
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


vscode_update_extensions() {
  vscode_sync_update "$@"
}


vscode_sync_status() {
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_extensions_require_python || return 1

  _shared_banner "VS Code Sync Status"
  _vscode_sync_run_python_command sync-status
}


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
