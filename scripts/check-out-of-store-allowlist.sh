#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# +++++++++++++++++++++++ OUT-OF-STORE ALLOWLIST CHECK +++++++++++++++++++++++ #
# ============================================================================ #
# Verifies that home/out-of-store-allowlist.tsv matches every
# config.lib.file.mkOutOfStoreSymlink use in the flake: same entries, no
# duplicates, nothing stale.
#
# Usage:
#   scripts/check-out-of-store-allowlist.sh
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
allowlist="$repo_root/home/out-of-store-allowlist.tsv"
for required_command in awk diff rg sed sort uniq wc; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'check-out-of-store-allowlist requires %s.\n' \
      "$required_command" >&2
    exit 2
  fi
done
if [[ ! -r "$allowlist" ]]; then
  printf 'Out-of-store allowlist is missing or unreadable: %s\n' \
    "$allowlist" >&2
  exit 2
fi

if ! tmp_root="$(
  mktemp -d "${TMPDIR:-/tmp}/out-of-store-check.XXXXXX" 2>/dev/null ||
    mktemp -d "$repo_root/.out-of-store-check.XXXXXX"
)"; then
  printf 'Unable to create a private out-of-store-check workspace.\n' >&2
  exit 2
fi
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

actual="$tmp_root/actual"
expected="$tmp_root/expected"
duplicates="$tmp_root/duplicates"

cd -- "$repo_root"

# +++++++++++++++++++++++++++++ ALLOWLIST SHAPE ++++++++++++++++++++++++++++++ #

awk -F '\t' '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 7 {
    printf "Malformed allowlist row %d: expected 7 tab-separated fields\n", NR > "/dev/stderr"
    invalid = 1
    next
  }
  {
    for (field = 1; field <= 7; field++) {
      if ($field == "") {
        printf "Malformed allowlist row %d: field %d is empty\n", NR, field > "/dev/stderr"
        invalid = 1
      }
    }
  }
  END { exit invalid }
' "$allowlist"

awk -F '\t' '!/^[[:space:]]*#/ && NF { print $1 }' "$allowlist" |
  LC_ALL=C sort >"$expected"
uniq -d "$expected" >"$duplicates"
if [[ -s "$duplicates" ]]; then
  echo "Duplicate out-of-store allowlist entries:" >&2
  sed 's/^/  /' "$duplicates" >&2
  exit 1
fi

# +++++++++++++++++++++++++++++++ CROSS-CHECK ++++++++++++++++++++++++++++++++ #

rg_status=0
rg --files-with-matches \
  --glob '*.nix' \
  'config\.lib\.file\.mkOutOfStoreSymlink' \
  flake.nix darwin home hosts >"$tmp_root/rg-actual" || rg_status=$?
if ((rg_status > 1)); then
  printf 'Unable to scan Nix modules for out-of-store links (ripgrep status %d).\n' \
    "$rg_status" >&2
  exit 2
fi
sort "$tmp_root/rg-actual" >"$actual"

if ! diff -u "$expected" "$actual"; then
  echo >&2
  echo "Out-of-store links and home/out-of-store-allowlist.tsv differ." >&2
  echo "Document every intentional exception and remove every stale entry." >&2
  exit 1
fi

printf 'Verified %d registered out-of-store module(s).\n' "$(wc -l <"$actual" | tr -d ' ')"

# ============================================================================ #
# End of check-out-of-store-allowlist.sh.
