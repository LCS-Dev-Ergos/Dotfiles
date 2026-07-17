#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ SECURITY SCANNER +++++++++++++++++++++++++++++ #
# ============================================================================ #
# Reusable security scanner for files and folders. Thin shell wrapper around
# the Python backend in security/python/cli.py.
#
# Combines three independent layers, each skipped gracefully (with a clear
# warning) when its tool isn't installed:
#   1. Structural checks (always available) - signature/extension mismatch,
#      embedded PE/ELF executables, PDF auto-run vectors (/Launch,/JavaScript,
#      embedded files), dangerous file types inside EPUB/ZIP archives.
#   2. YARA (optional)   - pattern matching, bundled ruleset in
#      security/yara/document-threats.yar.
#   3. ClamAV (optional) - full signature-based antivirus scan.
#
# Usage:
#   security_scan <path> [<path> ...] [options]
#
# Options:
#   --no-recursive        Do not descend into subdirectories.
#   --no-structural       Disable the built-in structural checks.
#   --no-yara             Disable YARA even if installed.
#   --no-clamav           Disable ClamAV even if installed.
#   --yara-rules <path>   Use a custom YARA rules file.
#   --hash                Compute a SHA-256 hash for every scanned file.
#   --report <path>       Write a detailed JSON report to this path.
#   --verbose             Also print clean files, not just flagged ones.
#   --quiet               Only print the final summary box.
#   -h, --help            Show the Python backend's own help and exit.
#
# Exit codes:
#   0   scan completed, nothing suspicious found
#   1   scan completed, at least one finding was reported
#   2   the scan itself could not run (bad arguments, missing backend, ...)
#
# Optional dependencies (macOS / Homebrew):
#   brew install clamav && freshclam   # ClamAV + initial signature update
#   brew install yara
#   pip install pikepdf                # richer PDF structural checks
#
# Author: Claude (Anthropic)
# License: MIT
# ============================================================================ #

_security_scan_wrapper_dir="${${(%):-%N}:A:h}"
_security_scan_common="${_security_scan_wrapper_dir}/security/_common.zsh"

if [[ -r "$_security_scan_common" ]]; then
  # shellcheck disable=SC1090
  source "$_security_scan_common"
else
  printf "[ERROR] security module not found: %s\n" "$_security_scan_common" >&2
  return 1 2>/dev/null || exit 1
fi
unset _security_scan_wrapper_dir
unset _security_scan_common

# -----------------------------------------------------------------------------
# _security_scan_usage
# @internal
# @description Prints command usage and examples.
# @noargs
# -----------------------------------------------------------------------------
_security_scan_usage() {
  printf "%s\n" \
    "Usage:" \
    "  security_scan <path> [<path> ...] [options]" \
    "" \
    "Options:" \
    "  --no-recursive        Do not descend into subdirectories." \
    "  --no-structural       Disable the built-in structural checks." \
    "  --no-yara             Disable YARA even if installed." \
    "  --no-clamav           Disable ClamAV even if installed." \
    "  --yara-rules <path>   Use a custom YARA rules file." \
    "  --hash                Compute a SHA-256 hash for every scanned file." \
    "  --report <path>       Write a detailed JSON report to this path." \
    "  --verbose             Also print clean files, not just flagged ones." \
    "  --quiet               Only print the final summary box." \
    "  -h, --help            Show this help and exit." \
    "" \
    "Examples:" \
    "  security_scan ~/Downloads/some.pdf" \
    "  security_scan ~/Desktop/\"My Library\" --report ~/Desktop/scan-report.json" \
    "  security_scan . --no-clamav --verbose"
}

# -----------------------------------------------------------------------------
# security_scan
# @description Scans files with structural, YARA, and ClamAV checks.
# Delegates paths and options to the Python backend; --help is handled locally.
# @arg $@ path Paths and scan options forwarded to the backend.
# @exitcode 1 If findings are reported.
# @exitcode 2 If arguments, the backend, or scan setup are invalid.
# -----------------------------------------------------------------------------
security_scan() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail

  if [[ "$#" -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    _security_scan_usage
    [[ "$#" -eq 0 ]] && return 2
    return 0
  fi

  if ! _security_python_backend_available; then
    _shared_log error "Python backend unavailable (need python3 and security/python/cli.py)."
    return 2
  fi

  local quiet=0 argument
  for argument in "$@"; do
    [[ "$argument" == --quiet ]] && quiet=1
  done

  if (( ! quiet )); then
    _zsh_ui_heading \
      "Security scan" \
      "Structural checks with optional YARA and ClamAV analysis"
    _security_report_tool_status
  fi

  command python3 "${_SECURITY_MODULE_ROOT}/python/cli.py" scan "$@"
}

# -----------------------------------------------------------------------------
# secscan
# @description Short alias for security_scan.
# @arg $@ path Arguments forwarded to security_scan.
# @exitcode 1 If findings are reported.
# @exitcode 2 If the scan cannot run.
# -----------------------------------------------------------------------------
secscan() {
  security_scan "$@"
}

# ============================================================================ #
# End of security-scan.zsh
