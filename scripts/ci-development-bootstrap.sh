#!/bin/bash
# Focused CI entry; compatible with the system Bash 3.2 on macOS.
# Source tests use fixtures. Package builds run check/installCheck but never
# invoke the native foundation installer, runtime setup or system activation.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$root"

case "${1:-source}" in
  source)
    /bin/bash -n scripts/dev-bootstrap.sh
    python3 -B home/dev/bootstrap/tests/run.py source
    ;;
  package)
    nix --extra-experimental-features 'nix-command flakes' eval --json \
      --file scripts/tests/development-ownership.nix
    nix --extra-experimental-features 'nix-command flakes' build --impure \
      --file scripts/development-bootstrap.nix \
      --no-link --print-out-paths --print-build-logs
    ;;
  *)
    printf 'Usage: %s [source|package]\n' "$0" >&2
    exit 2
    ;;
esac
