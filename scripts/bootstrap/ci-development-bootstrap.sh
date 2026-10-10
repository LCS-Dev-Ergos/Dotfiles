#!/bin/bash
# shellcheck shell=bash
# ============================================================================ #
# +++++++++++++++++++++++++ DEVELOPMENT BOOTSTRAP CI +++++++++++++++++++++++++ #
# ============================================================================ #
# Focused CI entry, compatible with the system Bash 3.2 on macOS. Source
# tests use fixtures. Package builds run check and installCheck but never
# invoke the native foundation installer, runtime setup or system
# activation.
#
# Usage:
#   scripts/bootstrap/ci-development-bootstrap.sh [source|package]
#
# ============================================================================ #

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd -- "$root"

case "${1:-source}" in
  source)
    /bin/bash -n scripts/bootstrap/dev-bootstrap.sh
    python3 -B home/dev/bootstrap/tests/run.py source
    ;;
  package)
    nix --extra-experimental-features 'nix-command flakes' eval --json \
      --file scripts/tests/development-ownership.nix
    nix --extra-experimental-features 'nix-command flakes' build --impure \
      --file scripts/bootstrap/development-bootstrap.nix \
      --no-link --print-out-paths --print-build-logs
    ;;
  *)
    printf 'Usage: %s [source|package]\n' "$0" >&2
    exit 2
    ;;
esac

# ============================================================================ #
# End of scripts/bootstrap/ci-development-bootstrap.sh.
