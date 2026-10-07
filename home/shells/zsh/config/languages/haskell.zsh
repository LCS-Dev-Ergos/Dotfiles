#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++ HASKELL INTEGRATION ++++++++++++++++++++++++++++ #
# ============================================================================ #

[[ -f "${GHCUP_INSTALL_BASE_PREFIX:-$HOME}/.ghcup/env" ]] &&
  . "${GHCUP_INSTALL_BASE_PREFIX:-$HOME}/.ghcup/env"

# An unavailable optional integration is a successful no-op.
:
