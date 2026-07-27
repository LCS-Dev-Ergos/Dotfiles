#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ OCI RETRY WRAPPER +++++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Thin dispatch entry point for oci-retry.sh, a Bash automation script that
# provisions an OCI VM.Standard.A1.Flex instance with capacity/throttling
# retry logic. Kept separate because oci-retry.sh requires Bash (it refuses
# to run under Zsh) and must always execute as its own process, never be
# sourced into the interactive shell.
#
# Functions:
#   - oci-retry   Run the OCI provisioning retry loop.
#
# ============================================================================ #

# ++++++++++++++++++++++++++ SHARED HELPERS LOADER +++++++++++++++++++++++++++ #

typeset _oci_retry_helpers="${${(%):-%N}:A:h}/_shared-helpers.zsh"
if (( ! $+functions[_zsh_ui_log] )); then
  if [[ -r "$_oci_retry_helpers" ]]; then
    source "$_oci_retry_helpers"
  else
    print -u2 "[ERROR] Shared helpers not found: $_oci_retry_helpers"
    unset _oci_retry_helpers
    return 1 2>/dev/null || exit 1
  fi
fi
unset _oci_retry_helpers

# -----------------------------------------------------------------------------
# oci-retry
# @description Provisions an OCI VM.Standard.A1.Flex instance, retrying only
# on capacity or throttling errors. Run oci-retry --help for full usage,
# environment variables, and 1Password integration.
# @arg $@ string Forwarded verbatim to oci-retry.sh: --dry-run, --op-environment <id>, --op-no-masking, or --help.
# @exitcode 1 If Bash is unavailable or oci-retry.sh itself fails.
# -----------------------------------------------------------------------------
oci-retry() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail

  local script_dir="${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts"
  local script="$script_dir/oci/oci-retry.sh"

  if [[ ! -r "$script" ]]; then
    _zsh_ui_log error "oci-retry: script not found: $script"
    return 1
  fi

  _shared_require_command bash \
    "oci-retry: bash is required but not found in PATH." || return 1

  command bash "$script" "$@"
}

# ============================================================================ #
# End of oci-retry.zsh
