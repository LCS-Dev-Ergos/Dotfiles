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
# Coordinates core helpers and extension internals.
# ============================================================================ #

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
#   1 - Platform check failed or one/more sync operations failed.
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
