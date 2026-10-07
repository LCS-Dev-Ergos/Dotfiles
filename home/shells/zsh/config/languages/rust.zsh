#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ RUST INTEGRATION +++++++++++++++++++++++++++++ #
# ============================================================================ #

# Rust: Parallel compilation and incremental builds.
export CARGO_BUILD_JOBS="${_ZSH_NCPUS:-4}" # Uses cached CPU count from 00-initialization.zsh.
export CARGO_INCREMENTAL=1

# An unavailable optional integration is a successful no-op.
:
