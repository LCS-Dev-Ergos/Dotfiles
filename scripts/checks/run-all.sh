#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# ++++++++++++++++++++++++++++ REPOSITORY CHECKS +++++++++++++++++++++++++++++ #
# ============================================================================ #
# Every check CI runs on a configuration change: Nix formatting and lint,
# workflow lint, Python lint and formatting, the state-boundary, package
# ownership and secret policies, the script regression tests and ShellCheck.
# The locked CI shell provides every tool.
#
# Usage:
#   nix develop --impure \
#     --expr 'import ./scripts/bootstrap/development-bootstrap.nix { target = "ci"; }' \
#     --command bash scripts/checks/run-all.sh
#
# ============================================================================ #

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."

python_sources=(
  home/dev/bootstrap
  scripts/updates
  scripts/tests/test_update_runtime_baseline.py
)

mapfile -t nix_files < <(find flake.nix darwin home hosts -type f -name '*.nix' | sort)
nixfmt --check "${nix_files[@]}" scripts/bootstrap/development-bootstrap.nix
actionlint .github/workflows/*.yml
ruff check --isolated --target-version py313 --select E4,E7,E9,F,B "${python_sources[@]}"
ruff format --isolated --target-version py313 --line-length 79 --check "${python_sources[@]}"
statix check .
deadnix --fail flake.nix darwin home hosts
bash scripts/checks/check-out-of-store-allowlist.sh
bash scripts/checks/check-package-ownership-policy.sh
bash scripts/checks/check-declared-secrets.sh
bash scripts/tests/run.sh
shellcheck scripts/*/*.sh home/cli/cli-tools/scripts/*.sh

# ============================================================================ #
# End of scripts/checks/run-all.sh.
