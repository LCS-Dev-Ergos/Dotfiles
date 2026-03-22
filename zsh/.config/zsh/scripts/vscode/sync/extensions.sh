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
# Only the Python bridge and extension-only preflight helper remain here.
# ============================================================================ #

# ++++++++++++++++++++++++++ EXTENSION SYNC HELPERS ++++++++++++++++++++++++++ #

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
