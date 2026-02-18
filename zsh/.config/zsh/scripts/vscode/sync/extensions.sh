#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++ VS CODE SYNC EXTENSIONS LAYER +++++++++++++++++++++++ #
# ============================================================================ #
# Internal extension synchronization logic:
#  - exclusion matching
#  - per-extension symlink setup/status/check/remove
#  - drift and broken-link reconciliation
# Used by top-level vscode_sync_* commands.
# ============================================================================ #

# ++++++++++++++++++++++++++ EXTENSION SYNC HELPERS ++++++++++++++++++++++++++ #

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
#   0 - Setup completed successfully.
#   1 - One or more extension operations failed.
# -----------------------------------------------------------------------------
_vscode_sync_setup_extensions() {
  setopt localoptions nullglob
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  _vscode_sync_validate_extensions_paths || return 1

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
  local synced=0 already=0 excluded=0 excluded_unlinked=0 failed=0
  local name link link_dest ext_path
  for ext_path in "$src"/*(N/); do
    name="${ext_path%/}"
    name="${name##*/}"
    link="$dst/$name"

    if _vscode_sync_ext_is_excluded "$name"; then
      if [[ -L "$link" ]]; then
        rm -f "$link" || {
          _shared_log error "Extensions: failed to remove excluded symlink: $link"
          ((failed++))
          continue
        }
        ((excluded_unlinked++))
      fi
      ((excluded++))
      continue
    fi

    if ! _vscode_sync_path_is_within_home "$link"; then
      _shared_log error "Extensions: link path outside HOME, skipping: $link"
      ((failed++))
      continue
    fi

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

  # Remove stale sync-managed links that no longer map to current source state.
  local stale_link stale_name
  for stale_link in "$dst"/*(N); do
    [[ -L "$stale_link" ]] || continue
    stale_name="${stale_link##*/}"
    link_dest=$(readlink "$stale_link" 2>/dev/null)
    if [[ "$link_dest" == "$src/"* ]]; then
      if [[ ! -d "$src/$stale_name" ]] || _vscode_sync_ext_is_excluded "$stale_name"; then
        rm -f "$stale_link" || {
          _shared_log error "Extensions: failed to remove stale symlink: $stale_link"
          ((failed++))
          continue
        }
      fi
    fi
  done

  # 4. Report.
  _shared_log ok "Extensions: $synced synced, $already already linked, $excluded excluded, $excluded_unlinked excluded-unlinked, $failed failed."
  (( failed == 0 ))
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

  local total=0 symlinked=0 excluded=0 excluded_linked=0 broken=0
  local excluded_list=() excluded_linked_list=() broken_list=()
  local name ext_path link

  for ext_path in "$src"/*(N/); do
    name="${ext_path%/}"
    name="${name##*/}"
    ((total++))
    link="$dst/$name"

    if _vscode_sync_ext_is_excluded "$name"; then
      ((excluded++))
      if [[ -L "$link" ]]; then
        ((excluded_linked++))
        excluded_linked_list+=("$name")
      else
        excluded_list+=("$name")
      fi
      continue
    fi

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

  if (( ${#excluded_linked_list[@]} > 0 )); then
    printf "             %sExcluded but symlinked (run setup to fix):%s\n" "$C_BOLD" "$C_RESET"
    local n
    for n in "${excluded_linked_list[@]}"; do
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
# Returns:
#   0 - Extension remove completed successfully.
#   1 - One or more extension operations failed.
# -----------------------------------------------------------------------------
_vscode_sync_remove_extensions() {
  setopt localoptions nullglob
  local dst="$_VSCODE_EXTENSIONS_DST"

  _vscode_sync_validate_extensions_paths || return 1

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
  for link_path in "$dst"/*(N); do
    name="${link_path##*/}"
    if [[ -L "$link_path" ]]; then
      if ! _vscode_sync_path_is_within_home "$link_path"; then
        _shared_log error "Extensions: path outside HOME, skipping: $link_path"
        ((failed++))
        continue
      fi
      rm -f "$link_path" || {
        _shared_log error "Extensions: failed to remove symlink: $link_path"
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
  (( failed == 0 ))
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
  local broken_count=0 outside_count=0 excluded_linked_count=0
  local broken_names=() outside_names=() excluded_linked_names=()
  local link_path name link_dest

  for link_path in "$dst"/*(N); do
    [[ -L "$link_path" ]] || continue
    name="${link_path##*/}"
    link_dest=$(readlink "$link_path" 2>/dev/null)
    if [[ ! -e "$link_path" ]]; then
      ((broken_count++))
      broken_names+=("$name")
      ((_VSCODE_EXT_CHECK_ISSUES++))
    elif [[ "$link_dest" != "$src/"* ]]; then
      ((outside_count++))
      outside_names+=("$name")
      ((_VSCODE_EXT_CHECK_WARNINGS++))
    fi
  done

  # Count excluded extensions (info only).
  local excluded_count=0 ext_path ext_name
  for ext_path in "$src"/*(N/); do
    ext_name="${ext_path%/}"
    ext_name="${ext_name##*/}"
    if _vscode_sync_ext_is_excluded "$ext_name"; then
      ((excluded_count++))
      if [[ -L "$dst/$ext_name" ]]; then
        ((excluded_linked_count++))
        excluded_linked_names+=("$ext_name")
        ((_VSCODE_EXT_CHECK_WARNINGS++))
      fi
    fi
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

  if ((excluded_linked_count > 0)); then
    _shared_log warn "    $excluded_linked_count excluded extension(s) are still symlinked:"
    local n
    for n in "${excluded_linked_names[@]}"; do
      printf "       - %s\n" "$n"
    done
  fi

  local exclude_patterns="" pat
  for pat in "${_VSCODE_EXTENSIONS_EXCLUDE[@]}"; do
    exclude_patterns+="${exclude_patterns:+, }${pat}"
  done
  _shared_log info "    Excluded: $excluded_count extension(s) matching: $exclude_patterns"
}

# ============================================================================ #
# End of script.
