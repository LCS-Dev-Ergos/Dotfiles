#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ SECURITY MODULE COMMON ++++++++++++++++++++++++++ #
# ============================================================================ #
# Shared bootstrap for the security-scan module.
# Loads shared helpers and centralizes module bootstrap behavior.
#
# Author: Claude (Anthropic)
# License: MIT
# ============================================================================ #

_security_common_ready() {
  typeset -f _security_python_backend_available >/dev/null 2>&1 &&
    typeset -f _security_report_tool_status >/dev/null 2>&1
}

if [[ -n "${_SECURITY_MODULE_COMMON_LOADED:-}" ]] && _security_common_ready; then
  unfunction _security_common_ready 2>/dev/null
  return 0
fi
unset _SECURITY_MODULE_COMMON_LOADED

_security_module_common_path="${${(%):-%N}:A}"
_security_module_dir="${_security_module_common_path:h}"
_security_scripts_dir="${_security_module_dir:h}"
_security_shared_helpers="${_security_scripts_dir}/_shared-helpers.zsh"

# Expose the security module root so the wrapper can find the Python backend
# and the bundled YARA ruleset.
_SECURITY_MODULE_ROOT="${_security_module_dir}"

if [[ -r "$_security_shared_helpers" ]]; then
  # shellcheck disable=SC1090
  source "$_security_shared_helpers"
else
  printf "[ERROR] Shared helpers not found: %s\n" "$_security_shared_helpers" >&2
  return 1 2>/dev/null || exit 1
fi

_SECURITY_MODULE_COMMON_LOADED=1
unfunction _security_common_ready 2>/dev/null

# -----------------------------------------------------------------------------
# _security_python_backend_available
# @internal
# @description Checks whether python3 and the CLI backend module are present.
# @noargs
# -----------------------------------------------------------------------------
_security_python_backend_available() {
  command -v python3 >/dev/null 2>&1 && [[ -r "${_SECURITY_MODULE_ROOT}/python/cli.py" ]]
}

# -----------------------------------------------------------------------------
# _security_report_tool_status
# @internal
# @description Logs which optional scanners (ClamAV, YARA) are available.
# Purely informational; the Python backend re-detects and enforces this
# itself, this is just a friendly heads-up before the scan starts.
# @noargs
# -----------------------------------------------------------------------------
_security_report_tool_status() {
  if command -v clamscan >/dev/null 2>&1 || command -v clamdscan >/dev/null 2>&1; then
    _shared_log ok "ClamAV detected."
  else
    _shared_log warn "ClamAV not found. Install with: brew install clamav && freshclam"
  fi

  if command -v yara >/dev/null 2>&1; then
    _shared_log ok "YARA detected."
  else
    _shared_log warn "YARA not found. Install with: brew install yara"
  fi
}

unset _security_module_common_path
unset _security_module_dir
unset _security_scripts_dir
unset _security_shared_helpers

# ============================================================================ #
# End of security/_common.zsh
