#!/usr/bin/env bash
# Checks the shipped markdownlint configuration against fixtures. Expects markdownlint-cli2 on
# PATH and runs from the directory that holds config/ and tests/.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
config=config/config.jsonc
fixtures=tests/fixtures

lint() { markdownlint-cli2 --config "$config" "$@"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A document in the preferred style is clean.
lint "$fixtures/clean.md"

# Padded tables are reported by both table rules, so the custom rule really loads.
if report=$(lint "$fixtures/padded.md" 2>&1); then
  echo "padded.md passed lint but contains padded tables" >&2
  exit 1
fi
for rule in LCS001 MD060; do
  grep -q "$rule" <<<"$report" || {
    echo "expected $rule in the report for padded.md:" >&2
    echo "$report" >&2
    exit 1
  }
done

# --fix produces the canonical form and leaves tables inside code fences alone.
cp "$fixtures/padded.md" "$work/padded.md"
lint --fix "$work/padded.md" >/dev/null 2>&1 || true
diff -u "$fixtures/padded.fixed.md" "$work/padded.md"

# The fixed file is stable: it lints clean and a second pass changes nothing.
lint "$work/padded.md"
cp "$work/padded.md" "$work/second.md"
lint --fix "$work/second.md" >/dev/null 2>&1
diff -u "$work/padded.md" "$work/second.md"

echo "markdownlint configuration checks passed"
