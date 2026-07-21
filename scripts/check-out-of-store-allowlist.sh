#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
allowlist="$repo_root/home/out-of-store-allowlist.tsv"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/out-of-store-check.XXXXXX" 2>/dev/null ||
  mktemp -d "$repo_root/.out-of-store-check.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

actual="$tmp_root/actual"
expected="$tmp_root/expected"
duplicates="$tmp_root/duplicates"

cd -- "$repo_root"

awk -F '\t' '
  /^#/ || NF == 0 { next }
  NF != 7 {
    printf "Malformed allowlist row %d: expected 7 tab-separated fields\n", NR > "/dev/stderr"
    invalid = 1
  }
  END { exit invalid }
' "$allowlist"

awk -F '\t' '!/^#/ && NF { print $1 }' "$allowlist" | LC_ALL=C sort >"$expected"
uniq -d "$expected" >"$duplicates"
if [[ -s "$duplicates" ]]; then
  echo "Duplicate out-of-store allowlist entries:" >&2
  sed 's/^/  /' "$duplicates" >&2
  exit 1
fi

rg --files-with-matches \
  --glob '*.nix' \
  'config\.lib\.file\.mkOutOfStoreSymlink' \
  flake.nix darwin home hosts | LC_ALL=C sort >"$actual"

if ! diff -u "$expected" "$actual"; then
  echo >&2
  echo "Out-of-store links and home/out-of-store-allowlist.tsv differ." >&2
  echo "Document every intentional exception and remove every stale entry." >&2
  exit 1
fi

printf 'Verified %d registered out-of-store module(s).\n' "$(wc -l <"$actual" | tr -d ' ')"
