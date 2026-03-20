#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ VS CODE SYNC COMMANDS LAYER ++++++++++++++++++++++++ #
# ============================================================================ #
# Public command orchestrators for VS Code sync:
#  - vscode_sync_setup
#  - vscode_sync_status
#  - vscode_sync_check
#  - vscode_sync_remove
#  - vscode_sync_update
# Coordinates core helpers and extension internals.
# ============================================================================ #

# +++++++++++++++++++++++++++ MAIN SYNC FUNCTIONS ++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# _vscode_sync_update_usage
# -----------------------------------------------------------------------------
# Prints command usage for vscode_sync_update.
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
# _vscode_sync_load_cleaner_module
# -----------------------------------------------------------------------------
# Lazily loads the extension cleaner so the update flow can reuse its duplicate
# pruning logic without forcing the module into every shell session.
# -----------------------------------------------------------------------------
_vscode_sync_load_cleaner_module() {
  typeset -f _vscode_ext_clean_run >/dev/null 2>&1 && return 0

  local cleaner_module="${_VSCODE_MODULE_ROOT}/extension_cleaner.sh"
  if [[ ! -r "$cleaner_module" ]]; then
    _shared_log error "VS Code extension cleaner module not found: $cleaner_module"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$cleaner_module" || {
    _shared_log error "Failed to load VS Code extension cleaner module."
    return 1
  }
}

# -----------------------------------------------------------------------------
# _vscode_sync_update_shared_extensions
# -----------------------------------------------------------------------------
# Updates the canonical Stable-managed extension root using the real VS Code
# user-data state so profile-aware extension bookkeeping stays consistent.
# -----------------------------------------------------------------------------
_vscode_sync_update_shared_extensions() {
  _shared_log info "Updating shared extensions via Stable CLI."
  command code \
    --extensions-dir "$_VSCODE_EXTENSIONS_SRC" \
    --update-extensions
}

# -----------------------------------------------------------------------------
# _vscode_sync_update_native_excluded_extensions
# -----------------------------------------------------------------------------
# Updates only the Insiders-native excluded extensions. Shared extensions are
# intentionally left to the Stable-managed canonical root.
# -----------------------------------------------------------------------------
_vscode_sync_update_native_excluded_extensions() {
  local -a ext_ids=("$@")
  local ext_id
  local updated=0 failed=0

  if (( ${#ext_ids[@]} == 0 )); then
    _shared_log info "No Insiders-native excluded extensions detected."
    return 0
  fi

  for ext_id in "${ext_ids[@]}"; do
    _shared_log info "Updating Insiders-native extension: $ext_id"
    command code-insiders \
      --extensions-dir "$_VSCODE_EXTENSIONS_DST" \
      --install-extension "$ext_id" \
      --force || {
        _shared_log warn "Skipping failed Insiders-native extension update: $ext_id"
        ((failed++))
        continue
      }
    ((updated++))
  done

  if (( failed > 0 )); then
    _shared_log warn "Insiders-native extension updates completed with $failed failure(s); existing installed versions were left untouched."
  else
    _shared_log ok "Updated $updated Insiders-native excluded extension(s)."
  fi

  return 0
}

# -----------------------------------------------------------------------------
# _vscode_sync_cleanup_shared_extensions
# -----------------------------------------------------------------------------
# Quarantines duplicate versions from the canonical Stable root after updates.
# -----------------------------------------------------------------------------
_vscode_sync_cleanup_shared_extensions() {
  _vscode_sync_load_cleaner_module || return 1
  _shared_log info "Cleaning duplicate versions in the shared Stable root via quarantine."
  _vscode_ext_clean_run "$_VSCODE_EXTENSIONS_SRC" newest false false true true
}

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
#   1 - Platform check failed or one/more sync operations failed.
# -----------------------------------------------------------------------------
vscode_sync_setup() {
  setopt localoptions localtraps nullglob
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_acquire_lock || return 1
  trap '_vscode_sync_release_lock' EXIT

  printf "%s%s[+] VS Code Sync Setup (Stable -> Insiders)%s\n\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  if ! _vscode_sync_check_vscode_running; then
    _shared_log error "Refusing to run setup while VS Code is open."
    _shared_log error "Close VS Code Stable and Insiders, then retry."
    return 1
  fi

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
  for ext_path in "$_VSCODE_EXTENSIONS_SRC"/*(N/); do
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
  _shared_log warn "Extension sync mirrors Stable installed extensions into Insiders (except exclusions)."
  _shared_log info "Profile manifests are treated as read-only by the sync workflow."
  echo

  _shared_confirm "Proceed with setup?" || {
    _shared_log info "Aborted by user."
    return 0
  }
  echo

  _vscode_sync_backup_profile_state || {
    _shared_log error "Aborting: failed to snapshot profile state."
    return 1
  }

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

  local ext_phase_failed=0
  _vscode_sync_setup_extensions || ext_phase_failed=1
  if ((ext_phase_failed)); then
    ((failed++))
  fi

  echo
  printf "%sSummary: %d/%d items synced, %d skipped, %d failed.%s\n" \
    "$C_BOLD" "$synced" "$total" "$skipped" "$failed" "$C_RESET"
  (( failed == 0 ))
}

# -----------------------------------------------------------------------------
# vscode_sync_update
# -----------------------------------------------------------------------------
# Orchestrates extension updates with Stable as the canonical shared root and
# Insiders handling only the explicitly excluded/native extensions.
#
# Usage:
#   vscode_sync_update [--dry-run|-n] [--skip-clean]
#
# Returns:
#   0 - Update/repair completed successfully or dry-run finished.
#   1 - One or more update/repair steps failed.
#   2 - Invalid arguments.
# -----------------------------------------------------------------------------
vscode_sync_update() {
  setopt localoptions localtraps nullglob
  _shared_init_colors
  _vscode_sync_check_platform || return 1

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

  _shared_require_command code "VS Code Stable CLI not found: code" || return 1
  _shared_require_command code-insiders "VS Code Insiders CLI not found: code-insiders" || return 1

  printf "%s%s[~] VS Code Extension Update%s\n\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  local -a native_excluded_ids=() missing_links=() unmanaged_dirs=()
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && native_excluded_ids+=("$entry")
  done < <(_vscode_sync_list_native_excluded_extension_ids)
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && missing_links+=("$entry")
  done < <(_vscode_sync_list_missing_extension_links)
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && unmanaged_dirs+=("$entry")
  done < <(_vscode_sync_list_unmanaged_extension_dirs)

  printf "%sPlanned actions:%s\n" "$C_BOLD" "$C_RESET"
  printf "  %s[UPDATE]%s Shared extensions root via Stable CLI: %s\n" \
    "$C_BLUE" "$C_RESET" "$_VSCODE_EXTENSIONS_SRC"
  if [[ "$skip_clean" == "true" ]]; then
    printf "  %s[SKIP]%s   Shared duplicate cleanup disabled\n" "$C_YELLOW" "$C_RESET"
  else
    printf "  %s[CLEAN]%s  Shared duplicate cleanup enabled for: %s\n" \
      "$C_BLUE" "$C_RESET" "$_VSCODE_EXTENSIONS_SRC"
  fi
  if (( ${#native_excluded_ids[@]} > 0 )); then
    printf "  %s[UPDATE]%s %d Insiders-native excluded extension(s)\n" \
      "$C_BLUE" "$C_RESET" "${#native_excluded_ids[@]}"
    local ext_id
    for ext_id in "${native_excluded_ids[@]}"; do
      printf "             - %s\n" "$ext_id"
    done
  else
    printf "  %s[SKIP]%s   No Insiders-native excluded extensions detected\n" \
      "$C_GREEN" "$C_RESET"
  fi
  printf "  %s[REPAIR]%s Reconcile symlinks in: %s\n" \
    "$C_BLUE" "$C_RESET" "$_VSCODE_EXTENSIONS_DST"
  if (( ${#missing_links[@]} > 0 )); then
    printf "             Missing expected links: %d\n" "${#missing_links[@]}"
  fi
  if (( ${#unmanaged_dirs[@]} > 0 )); then
    printf "             Unmanaged real directories: %d\n" "${#unmanaged_dirs[@]}"
  fi
  echo

  if [[ "$dry_run" == "true" ]]; then
    _shared_log ok "Dry run complete. No changes were made."
    return 0
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

  _shared_confirm "Proceed with update and repair?" || {
    _shared_log info "Aborted by user."
    return 0
  }
  echo

  _vscode_sync_acquire_lock || return 1
  trap '_vscode_sync_release_lock' EXIT

  _vscode_sync_backup_profile_state || {
    _shared_log error "Aborting: failed to snapshot profile state."
    return 1
  }

  local completed=0 failed=0

  _vscode_sync_update_shared_extensions || {
    _shared_log error "Shared Stable extension update failed."
    return 1
  }
  ((completed++))

  if [[ "$skip_clean" != "true" ]]; then
    _vscode_sync_cleanup_shared_extensions || {
      _shared_log error "Shared Stable duplicate cleanup failed."
      return 1
    }
    ((completed++))
  fi

  if (( ${#native_excluded_ids[@]} > 0 )); then
    _vscode_sync_update_native_excluded_extensions "${native_excluded_ids[@]}" || {
      _shared_log error "Insiders-native excluded extension update failed."
      return 1
    }
    ((completed++))
  fi

  if _vscode_python_backend_available; then
    _shared_log info "Using Python backend for extension reconcile after update."
    _vscode_sync_extensions_run_python \
      setup-extensions \
      "$_VSCODE_EXTENSIONS_SRC" \
      "$_VSCODE_EXTENSIONS_DST" \
      --home "$HOME" || failed=1
  else
    _vscode_sync_setup_extensions || failed=1
  fi
  if (( failed == 0 )); then
    ((completed++))
  fi

  echo
  _vscode_sync_status_extensions
  echo
  printf "%sSummary: %d step(s) completed, %d failed.%s\n" \
    "$C_BOLD" "$completed" "$failed" "$C_RESET"
  (( failed == 0 ))
}

# -----------------------------------------------------------------------------
# vscode_update_extensions
# -----------------------------------------------------------------------------
# Convenience alias for the orchestrated update workflow.
# -----------------------------------------------------------------------------
vscode_update_extensions() {
  vscode_sync_update "$@"
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
    local backup_dirs
    backup_dirs=("$_VSCODE_SYNC_BACKUP_DIR"/*(N/))
    backup_count=${#backup_dirs[@]}
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
#   1 - Platform check failed or one/more remove operations failed.
# -----------------------------------------------------------------------------
vscode_sync_remove() {
  setopt localoptions localtraps nullglob
  _shared_init_colors
  _vscode_sync_check_platform || return 1
  _vscode_sync_acquire_lock || return 1
  trap '_vscode_sync_release_lock' EXIT

  printf "%s%s[-] VS Code Sync Remove (Restore Independence)%s\n\n" "$C_BOLD" "$C_CYAN" "$C_RESET"

  if ! _vscode_sync_check_vscode_running; then
    _shared_log error "Refusing to run remove while VS Code is open."
    _shared_log error "Close VS Code Stable and Insiders, then retry."
    return 1
  fi

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
    for link_path in "$_VSCODE_EXTENSIONS_DST"/*(N); do
      [[ -L "$link_path" ]] && ((ext_rm_count++))
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

  _vscode_sync_backup_profile_state || {
    _shared_log error "Aborting: failed to snapshot profile state."
    return 1
  }

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

  local ext_phase_failed=0
  _vscode_sync_remove_extensions || ext_phase_failed=1
  if ((ext_phase_failed)); then
    ((failed++))
  fi

  echo
  printf "%sSummary: %d restored, %d broken removed, %d skipped, %d failed.%s\n" \
    "$C_BOLD" "$restored" "$removed" "$skipped" "$failed" "$C_RESET"
  (( failed == 0 ))
}

# ============================================================================ #
# End of script.
