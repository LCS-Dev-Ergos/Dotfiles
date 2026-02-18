#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ VS CODE SYNC MODULE LOADER ++++++++++++++++++++++++ #
# ============================================================================ #
# Loads VS Code sync submodules (core, extensions, commands) and initializes
# platform-aware configuration once for the current shell session.
# Exposes public commands:
#  - vscode_sync_setup
#  - vscode_sync_status
#  - vscode_sync_check
#  - vscode_sync_remove
# ============================================================================ #

[[ -n "${_VSCODE_SYNC_MODULE_LOADED:-}" ]] && return 0

_vscode_sync_module_root="${${(%):-%N}:A:h}"
_vscode_sync_common="${_vscode_sync_module_root}/_common.sh"
_vscode_sync_core="${_vscode_sync_module_root}/sync/_core.sh"
_vscode_sync_ext="${_vscode_sync_module_root}/sync/extensions.sh"
_vscode_sync_cmd="${_vscode_sync_module_root}/sync/commands.sh"

if [[ -r "$_vscode_sync_common" ]]; then
  # shellcheck disable=SC1090
  source "$_vscode_sync_common"
else
  printf "[ERROR] vscode common module not found: %s\n" "$_vscode_sync_common" >&2
  return 1 2>/dev/null || exit 1
fi

for _vscode_sync_part in "$_vscode_sync_core" "$_vscode_sync_ext" "$_vscode_sync_cmd"; do
  if [[ -r "$_vscode_sync_part" ]]; then
    # shellcheck disable=SC1090
    source "$_vscode_sync_part"
  else
    printf "[ERROR] vscode sync module part not found: %s\n" "$_vscode_sync_part" >&2
    return 1 2>/dev/null || exit 1
  fi
done

_vscode_sync_init_config
_VSCODE_SYNC_MODULE_LOADED=1

unset _vscode_sync_module_root
unset _vscode_sync_common
unset _vscode_sync_core
unset _vscode_sync_ext
unset _vscode_sync_cmd
unset _vscode_sync_part

# ============================================================================ #
# End of script.
