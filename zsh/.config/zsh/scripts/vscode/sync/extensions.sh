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

_vscode_sync_extensions_use_python() {
  _vscode_python_backend_enabled && _vscode_python_backend_available
}

_vscode_sync_extensions_run_python() {
  python3 "${_VSCODE_MODULE_ROOT}/py/cli.py" "$@"
}

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
# _vscode_sync_ext_folder_to_id <folder_name>
# -----------------------------------------------------------------------------
# Converts a versioned extension folder name into the Marketplace extension ID.
# Example:
#   github.copilot-chat-0.41.2026032001        -> github.copilot-chat
#   anthropic.claude-code-2.1.79-darwin-arm64  -> anthropic.claude-code
# -----------------------------------------------------------------------------
_vscode_sync_ext_folder_to_id() {
  local folder_name="$1"
  local ext_id="$folder_name"

  if [[ "$ext_id" =~ ^(.*)-([0-9][0-9A-Za-z._+-]*)$ ]]; then
    ext_id="${match[1]}"
  fi
  if [[ "$ext_id" =~ ^(.+)-(darwin|linux|win32|alpine)-(arm64|x64|ia32|armhf)$ ]]; then
    ext_id="${match[1]}"
  fi

  printf "%s\n" "$ext_id"
}

# -----------------------------------------------------------------------------
# _vscode_sync_list_missing_extension_links
# -----------------------------------------------------------------------------
# Prints missing or non-symlinked extension names that should currently be
# mirrored from Stable into the Insiders extension root.
# -----------------------------------------------------------------------------
_vscode_sync_list_missing_extension_links() {
  setopt localoptions nullglob
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"
  local ext_path name link

  for ext_path in "$src"/*(N/); do
    name="${ext_path:t}"
    _vscode_sync_ext_is_excluded "$name" && continue
    link="$dst/$name"
    [[ -L "$link" && -e "$link" ]] && continue
    print -r -- "$name"
  done
}

# -----------------------------------------------------------------------------
# _vscode_sync_list_unmanaged_extension_dirs
# -----------------------------------------------------------------------------
# Prints real Insiders extension directories that are not excluded and should
# therefore be replaced by symlinks or removed as leftovers.
# -----------------------------------------------------------------------------
_vscode_sync_list_unmanaged_extension_dirs() {
  setopt localoptions nullglob
  local dst="$_VSCODE_EXTENSIONS_DST"
  local entry_path name

  for entry_path in "$dst"/*(N); do
    [[ -d "$entry_path" ]] || continue
    [[ -L "$entry_path" ]] && continue
    name="${entry_path:t}"
    _vscode_sync_ext_is_excluded "$name" && continue
    print -r -- "$name"
  done
}

# -----------------------------------------------------------------------------
# _vscode_sync_list_native_excluded_extension_ids
# -----------------------------------------------------------------------------
# Prints unique extension IDs for excluded extensions that are currently stored
# as real directories in the Insiders extension root.
# -----------------------------------------------------------------------------
_vscode_sync_list_native_excluded_extension_ids() {
  setopt localoptions nullglob
  local dst="$_VSCODE_EXTENSIONS_DST"
  local entry_path name ext_id

  for entry_path in "$dst"/*(N); do
    [[ -d "$entry_path" ]] || continue
    [[ -L "$entry_path" ]] && continue
    name="${entry_path:t}"
    _vscode_sync_ext_is_excluded "$name" || continue
    ext_id=$(_vscode_sync_ext_folder_to_id "$name")
    [[ -n "$ext_id" ]] && print -r -- "$ext_id"
  done | LC_ALL=C sort -u
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

  if _vscode_sync_extensions_use_python; then
    _shared_log info "Extensions: using Python backend for setup."
    _vscode_sync_extensions_run_python \
      setup-extensions \
      "$src" \
      "$dst" \
      --home "$HOME"
    return $?
  fi

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
  local synced=0 already=0 excluded=0 excluded_unlinked=0 unmanaged_removed=0 failed=0
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

  # Remove unmanaged real directories left behind by Insiders updates.
  local unmanaged_dir unmanaged_name
  for unmanaged_dir in "$dst"/*(N); do
    [[ -d "$unmanaged_dir" ]] || continue
    [[ -L "$unmanaged_dir" ]] && continue
    unmanaged_name="${unmanaged_dir##*/}"

    if _vscode_sync_ext_is_excluded "$unmanaged_name"; then
      continue
    fi
    if ! _vscode_sync_path_is_within_home "$unmanaged_dir"; then
      _shared_log error "Extensions: unmanaged directory outside HOME, skipping: $unmanaged_dir"
      ((failed++))
      continue
    fi

    rm -rf "$unmanaged_dir" || {
      _shared_log error "Extensions: failed to remove unmanaged directory: $unmanaged_dir"
      ((failed++))
      continue
    }
    ((unmanaged_removed++))
  done

  # 4. Report.
  _shared_log ok "Extensions: $synced synced, $already already linked, $excluded excluded, $excluded_unlinked excluded-unlinked, $unmanaged_removed unmanaged-removed, $failed failed."
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

  if _vscode_sync_extensions_use_python; then
    _vscode_sync_extensions_run_python \
      extension-status \
      "$src" \
      "$dst" \
      --home "$HOME"
    return $?
  fi

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

  local total=0 symlinked=0 excluded=0 excluded_linked=0 broken=0 missing=0 unmanaged=0
  local excluded_list=() excluded_linked_list=() broken_list=() missing_list=() unmanaged_list=()
  local name ext_path link n

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
    else
      ((missing++))
      missing_list+=("$name")
    fi
  done

  local unmanaged_path
  for unmanaged_path in "$dst"/*(N); do
    [[ -d "$unmanaged_path" ]] || continue
    [[ -L "$unmanaged_path" ]] && continue
    name="${unmanaged_path:t}"
    if _vscode_sync_ext_is_excluded "$name"; then
      continue
    fi
    ((unmanaged++))
    unmanaged_list+=("$name")
  done

  local expected=$(( total - excluded ))
  local ext_label="SYNCED"
  local ext_color="$C_GREEN"
  if (( broken > 0 )); then
    ext_label="BROKEN"
    ext_color="$C_RED"
  elif (( missing > 0 || unmanaged > 0 || excluded_linked > 0 )); then
    ext_label="DRIFT"
    ext_color="$C_YELLOW"
  fi

  printf "  %s[%s]%s  Extensions  %d/%d symlinked, %d missing, %d excluded, %d broken, %d unmanaged\n" \
    "$ext_color" "$ext_label" "$C_RESET" "$symlinked" "$expected" "$missing" "$excluded" "$broken" "$unmanaged"

  if (( ${#excluded_list[@]} > 0 )); then
    printf "             %sExcluded:%s\n" "$C_BOLD" "$C_RESET"
    for n in "${excluded_list[@]}"; do
      printf "               - %s\n" "$n"
    done
  fi

  if (( ${#excluded_linked_list[@]} > 0 )); then
    printf "             %sExcluded but symlinked (run setup to fix):%s\n" "$C_BOLD" "$C_RESET"
    for n in "${excluded_linked_list[@]}"; do
      printf "               - %s\n" "$n"
    done
  fi

  if (( ${#missing_list[@]} > 0 )); then
    printf "             %sMissing expected symlinks:%s\n" "$C_BOLD" "$C_RESET"
    for n in "${missing_list[@]}"; do
      printf "               - %s\n" "$n"
    done
  fi

  if (( ${#broken_list[@]} > 0 )); then
    printf "             %sBroken symlinks:%s\n" "$C_BOLD" "$C_RESET"
    for n in "${broken_list[@]}"; do
      printf "               - %s\n" "$n"
    done
  fi

  if (( ${#unmanaged_list[@]} > 0 )); then
    printf "             %sUnmanaged real directories:%s\n" "$C_BOLD" "$C_RESET"
    for n in "${unmanaged_list[@]}"; do
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

  if _vscode_sync_extensions_use_python; then
    local counts_output issues_value warnings_value
    _vscode_sync_extensions_run_python \
      extension-check \
      "$src" \
      "$dst" \
      --home "$HOME"

    counts_output=$(
      _vscode_sync_extensions_run_python \
        extension-check \
        "$src" \
        "$dst" \
        --home "$HOME" \
        --counts-only 2>/dev/null
    ) || return 1

    issues_value=$(printf "%s\n" "$counts_output" | sed -n 's/^ISSUES=//p' | tail -n 1)
    warnings_value=$(printf "%s\n" "$counts_output" | sed -n 's/^WARNINGS=//p' | tail -n 1)
    [[ "$issues_value" =~ ^[0-9]+$ ]] || issues_value=0
    [[ "$warnings_value" =~ ^[0-9]+$ ]] || warnings_value=0
    _VSCODE_EXT_CHECK_ISSUES=$issues_value
    _VSCODE_EXT_CHECK_WARNINGS=$warnings_value
    return 0
  fi

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
  local broken_count=0 outside_count=0 excluded_linked_count=0 missing_count=0 unmanaged_count=0
  local broken_names=() outside_names=() excluded_linked_names=() missing_names=() unmanaged_names=()
  local link_path name link_dest n

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

  local missing_name unmanaged_name
  while IFS= read -r missing_name; do
    [[ -n "$missing_name" ]] || continue
    ((missing_count++))
    missing_names+=("$missing_name")
    ((_VSCODE_EXT_CHECK_WARNINGS++))
  done < <(_vscode_sync_list_missing_extension_links)

  while IFS= read -r unmanaged_name; do
    [[ -n "$unmanaged_name" ]] || continue
    ((unmanaged_count++))
    unmanaged_names+=("$unmanaged_name")
    ((_VSCODE_EXT_CHECK_WARNINGS++))
  done < <(_vscode_sync_list_unmanaged_extension_dirs)

  if ((_VSCODE_EXT_CHECK_ISSUES == 0 && _VSCODE_EXT_CHECK_WARNINGS == 0)); then
    _shared_log ok "    All extension symlinks valid."
  fi

  if ((broken_count > 0)); then
    _shared_log error "    $broken_count broken extension symlink(s):"
    for n in "${broken_names[@]}"; do
      printf "       - %s\n" "$n"
    done
  fi

  if ((outside_count > 0)); then
    _shared_log warn "    $outside_count symlink(s) point outside ${src}:"
    for n in "${outside_names[@]}"; do
      printf "       - %s\n" "$n"
    done
  fi

  if ((excluded_linked_count > 0)); then
    _shared_log warn "    $excluded_linked_count excluded extension(s) are still symlinked:"
    for n in "${excluded_linked_names[@]}"; do
      printf "       - %s\n" "$n"
    done
  fi

  if ((missing_count > 0)); then
    _shared_log warn "    $missing_count expected extension symlink(s) are missing:"
    for n in "${missing_names[@]}"; do
      printf "       - %s\n" "$n"
    done
  fi

  if ((unmanaged_count > 0)); then
    _shared_log warn "    $unmanaged_count unmanaged real extension directories found in Insiders:"
    for n in "${unmanaged_names[@]}"; do
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
