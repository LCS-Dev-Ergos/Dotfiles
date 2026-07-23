#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# ++++++++++++++++++++++ PACKAGE OWNERSHIP POLICY CHECK ++++++++++++++++++++++ #
# ============================================================================ #
# Validates the shape of home/package-ownership-allowlist.tsv itself: every
# row has 4 tab-separated fields, the expected winner is "nix" or "homebrew",
# and there are no duplicate (package, command) entries.
#
# This does not check the policy against the live system -- see
# scripts/audit-package-ownership.sh for that.
#
# Usage:
#   scripts/check-package-ownership-policy.sh
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
policy_file="${PACKAGE_OWNERSHIP_POLICY_FILE:-$repo_root/home/package-ownership-allowlist.tsv}"

# ++++++++++++++++++++++++++++++++ VALIDATION ++++++++++++++++++++++++++++++++ #

if [[ ! -r "$policy_file" ]]; then
  printf 'Package ownership policy is missing: %s\n' "$policy_file" >&2
  exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
  printf 'check-package-ownership-policy requires awk.\n' >&2
  exit 2
fi

if ! awk -F '\t' '
    BEGIN {
        issues = 0
    }

    /^[[:space:]]*$/ || /^[[:space:]]*#/ {
        next
    }

    {
        key = $1 SUBSEP $2
        if (NF != 4 || $1 == "" || $2 == "" ||
            $4 ~ /^[[:space:]]*$/) {
            printf "Invalid package ownership policy at line %d.\n", NR > "/dev/stderr"
            issues++
            next
        } else if ($3 != "nix" && $3 != "homebrew") {
            printf "Invalid expected winner at line %d: %s.\n", NR, $3 > "/dev/stderr"
            issues++
        }

        if ($1 !~ /^[A-Za-z0-9@+._\/-]+$/ ||
            $2 !~ /^[A-Za-z0-9@+._-]+$/ ||
            $0 ~ /[\r]/) {
            printf "Unsafe package or command name at line %d.\n", NR > "/dev/stderr"
            issues++
        }

        if (seen[key]++) {
            printf "Duplicate package ownership policy at line %d.\n", NR > "/dev/stderr"
            issues++
        }
    }

    END {
        exit issues != 0
    }
' "$policy_file"; then
  exit 1
fi

printf 'Package ownership policy is valid.\n'

# ============================================================================ #
# End of check-package-ownership-policy.sh.
