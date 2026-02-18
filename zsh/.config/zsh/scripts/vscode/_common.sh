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

if [[ -r "$_vscode_shared_helpers" ]]; then
  # shellcheck disable=SC1090
  source "$_vscode_shared_helpers"
else
  printf "[ERROR] Shared helpers not found: %s\n" "$_vscode_shared_helpers" >&2
  return 1 2>/dev/null || exit 1
fi

_VSCODE_MODULE_COMMON_LOADED=1

unset _vscode_module_common_path
unset _vscode_module_dir
unset _vscode_scripts_dir
unset _vscode_shared_helpers

# ============================================================================ #
# End of script.
