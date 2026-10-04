#!/usr/bin/env bash
# Checks the shipped markdownlint configuration and the mdlint command against fixtures.
# Expects markdownlint-cli2 on PATH and runs from the directory that holds config/, tests/ and
# mdlint.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
root=$PWD
export MDLINT_CONFIG_DIR="$root/config"
config=$MDLINT_CONFIG_DIR/config.jsonc
extended=$MDLINT_CONFIG_DIR/extended.jsonc
fixtures=$root/tests/fixtures

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

lint() { markdownlint-cli2 --config "$config" "$@"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== reduced rule set"

# A document in the preferred style is clean.
lint "$fixtures/clean.md"

# Padded tables are reported by both table rules, so the custom rule really loads.
if report=$(lint "$fixtures/padded.md" 2>&1); then
  fail "padded.md passed lint but contains padded tables"
fi
for rule in LCS001 MD060; do
  grep -q "$rule" <<<"$report" || fail "expected $rule in the report for padded.md: $report"
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

# The fixers that change content are not part of the reduced set: hazards.md must come back
# byte for byte, however many passes run.
cp "$fixtures/hazards.md" "$work/hazards.md"
lint --fix "$work/hazards.md" >/dev/null 2>&1 || true
lint --fix "$work/hazards.md" >/dev/null 2>&1 || true
cmp "$fixtures/hazards.md" "$work/hazards.md" || fail "the reduced set rewrote hazards.md"

echo "== extended rule set"

# The extended set reports exactly the things the reduced set must never rewrite.
report=$(markdownlint-cli2 --config "$extended" "$fixtures/hazards.md" 2>&1 || true)
for rule in MD004 MD007 MD009 MD018 MD026 MD029 MD034 MD037 MD049 MD050; do
  grep -q "$rule" <<<"$report" || fail "extended set did not report $rule on hazards.md"
done

# mdlint refuses to fix with the extended set and otherwise follows the chosen set.
status=0
bash "$root/mdlint.sh" --extended --fix "$work/hazards.md" >/dev/null 2>&1 || status=$?
[[ $status -eq 2 ]] || fail "mdlint --extended --fix exited with $status instead of 2"
bash "$root/mdlint.sh" "$fixtures/clean.md" >/dev/null
bash "$root/mdlint.sh" --extended "$fixtures/hazards.md" >/dev/null 2>&1 && fail "mdlint --extended passed hazards.md"

echo "markdownlint configuration checks passed"
