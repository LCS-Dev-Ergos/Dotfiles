#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++ VS CODE SYNC EXTENSIONS LAYER +++++++++++++++++++++++ #
# ============================================================================ #
# Thin shell wrappers around the Python extension-sync backend.
#
# The Python backend is the source of truth for:
#  - setup
#  - status
#  - health checks
#  - remove
#
# The remaining shell helpers below are only used for lightweight preview data
# in the top-level command wrappers.
# ============================================================================ #

# ++++++++++++++++++++++++++ EXTENSION SYNC HELPERS ++++++++++++++++++++++++++ #

_vscode_sync_extensions_use_python() {
  _vscode_python_backend_enabled && _vscode_python_backend_available
}

_vscode_sync_extensions_require_python() {
  if ! _vscode_python_backend_enabled; then
    _shared_log error "Extensions: Python backend explicitly disabled, but the shell backend has been retired."
    return 1
  fi
  if ! _vscode_python_backend_available; then
    _shared_log error "Extensions: Python backend unavailable."
    return 1
  fi
  return 0
}

_vscode_sync_extensions_run_python() {
  python3 "${_VSCODE_MODULE_ROOT}/py/cli.py" "$@"
}

# -----------------------------------------------------------------------------
# _vscode_sync_ext_is_excluded <name>
# -----------------------------------------------------------------------------
# Returns 0 if the extension name matches any pattern in
# _VSCODE_EXTENSIONS_EXCLUDE.
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
# therefore be replaced by symlinks or migrated.
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
# Applies extension sync setup via the Python backend.
# -----------------------------------------------------------------------------
_vscode_sync_setup_extensions() {
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  _vscode_sync_validate_extensions_paths || return 1
  _vscode_sync_extensions_require_python || return 1

  _shared_log info "Extensions: using Python backend for setup."
  _vscode_sync_extensions_run_python \
    setup-extensions \
    "$src" \
    "$dst" \
    --home "$HOME"
}

# -----------------------------------------------------------------------------
# _vscode_sync_status_extensions
# -----------------------------------------------------------------------------
# Displays extension sync status via the Python backend.
# -----------------------------------------------------------------------------
_vscode_sync_status_extensions() {
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  _vscode_sync_extensions_require_python || return 1

  _vscode_sync_extensions_run_python \
    extension-status \
    "$src" \
    "$dst" \
    --home "$HOME"
}

# -----------------------------------------------------------------------------
# _vscode_sync_remove_extensions
# -----------------------------------------------------------------------------
# Removes sync-managed extension symlinks via the Python backend.
# -----------------------------------------------------------------------------
_vscode_sync_remove_extensions() {
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"

  _vscode_sync_validate_extensions_paths || return 1
  _vscode_sync_extensions_require_python || return 1

  _shared_log info "Extensions: using Python backend for remove."
  _vscode_sync_extensions_run_python \
    remove-extensions \
    "$src" \
    "$dst" \
    --home "$HOME"
}

# -----------------------------------------------------------------------------
# _vscode_sync_check_extensions
# -----------------------------------------------------------------------------
# Validates extension sync health and stores counts in global vars:
#   _VSCODE_EXT_CHECK_ISSUES
#   _VSCODE_EXT_CHECK_WARNINGS
# -----------------------------------------------------------------------------
_vscode_sync_check_extensions() {
  local src="$_VSCODE_EXTENSIONS_SRC"
  local dst="$_VSCODE_EXTENSIONS_DST"
  local check_output check_status issues_value warnings_value

  _VSCODE_EXT_CHECK_ISSUES=0
  _VSCODE_EXT_CHECK_WARNINGS=0

  _vscode_sync_extensions_require_python || return 1

  check_output="$(
    _vscode_sync_extensions_run_python \
      extension-check \
      "$src" \
      "$dst" \
      --home "$HOME" 2>&1
  )"
  check_status=$?

  [[ -n "$check_output" ]] && printf "%s\n" "$check_output"

  issues_value=$(printf "%s\n" "$check_output" | sed -n 's/^ISSUES=//p' | tail -n 1)
  warnings_value=$(printf "%s\n" "$check_output" | sed -n 's/^WARNINGS=//p' | tail -n 1)
  [[ "$issues_value" =~ ^[0-9]+$ ]] || return 1
  [[ "$warnings_value" =~ ^[0-9]+$ ]] || return 1

  _VSCODE_EXT_CHECK_ISSUES=$issues_value
  _VSCODE_EXT_CHECK_WARNINGS=$warnings_value

  (( check_status == 0 || _VSCODE_EXT_CHECK_ISSUES > 0 )) || return 1
  return 0
}

# ============================================================================ #
# End of script.
