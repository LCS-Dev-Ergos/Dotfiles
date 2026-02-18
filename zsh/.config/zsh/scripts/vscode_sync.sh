#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# VS Code sync wrapper.
# Loads the dedicated VS Code sync module.
# ============================================================================ #

_vscode_sync_wrapper_path="${${(%):-%N}:A}"
_vscode_sync_wrapper_dir="${_vscode_sync_wrapper_path:h}"
_vscode_sync_module="${_vscode_sync_wrapper_dir}/vscode/sync.sh"

if [[ -r "$_vscode_sync_module" ]]; then
  # shellcheck disable=SC1090
  source "$_vscode_sync_module"
else
  printf "[ERROR] VS Code sync module not found: %s\n" "$_vscode_sync_module" >&2
  return 1 2>/dev/null || exit 1
fi

unset _vscode_sync_wrapper_path
unset _vscode_sync_wrapper_dir
unset _vscode_sync_module

# ============================================================================ #
# End of script.
