#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ VS CODE MODULE COMMON +++++++++++++++++++++++++++ #
# ============================================================================ #
# Shared bootstrap for VS Code modules.
# Loads shared helpers and centralizes module bootstrap behavior.
# ============================================================================ #

[[ -n "${_VSCODE_MODULE_COMMON_LOADED:-}" ]] && return 0

_vscode_module_common_path="${${(%):-%N}:A}"
_vscode_module_dir="${_vscode_module_common_path:h}"
_vscode_scripts_dir="${_vscode_module_dir:h}"
_vscode_shared_helpers="${_vscode_scripts_dir}/_shared_helpers.sh"

# Expose the VS Code module root so sibling modules can be loaded lazily.
_VSCODE_MODULE_ROOT="${_vscode_module_dir}"

if [[ -r "$_vscode_shared_helpers" ]]; then
  # shellcheck disable=SC1090
  source "$_vscode_shared_helpers"
else
  printf "[ERROR] Shared helpers not found: %s\n" "$_vscode_shared_helpers" >&2
  return 1 2>/dev/null || exit 1
fi

_VSCODE_MODULE_COMMON_LOADED=1

_vscode_python_backend_available() {
  command -v python3 >/dev/null 2>&1 && [[ -r "${_VSCODE_MODULE_ROOT}/py/cli.py" ]]
}

_vscode_python_backend_enabled() {
  case "${VSCODE_SYNC_USE_PYTHON:-auto}" in
    0|false|FALSE|no|NO|off|OFF|legacy|LEGACY) return 1 ;;
    *) return 0 ;;
  esac
}

unset _vscode_module_common_path
unset _vscode_module_dir
unset _vscode_scripts_dir
unset _vscode_shared_helpers

# ============================================================================ #
# End of script.
