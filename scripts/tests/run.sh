#!/usr/bin/env bash
# shellcheck shell=bash
# Focused regression tests for repository-level Bash policy checks.

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

for required_command in bash chmod cp env mkdir mktemp rm sed; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Script regression tests require %s.\n' "$required_command" >&2
    exit 2
  fi
done

if ! temp_root="$(
  mktemp -d "${TMPDIR:-/tmp}/dotfiles-script-tests.XXXXXX" 2>/dev/null ||
    mktemp -d "$repo_root/.dotfiles-script-tests.XXXXXX"
)"; then
  printf 'Unable to create a private script-test workspace.\n' >&2
  exit 2
fi
cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

expect_status() {
  local label="$1"
  local expected="$2"
  local actual
  shift 2

  set +e
  "$@" >"$temp_root/command.stdout" 2>"$temp_root/command.stderr"
  actual=$?
  set -e

  if ((actual != expected)); then
    printf 'FAIL: %s (expected status %d, received %d)\n' \
      "$label" "$expected" "$actual" >&2
    sed 's/^/  stdout: /' "$temp_root/command.stdout" >&2
    sed 's/^/  stderr: /' "$temp_root/command.stderr" >&2
    exit 1
  fi
}

printf 'Repository policy checks\n'
expect_status 'current package ownership policy' 0 \
  bash "$repo_root/scripts/check-package-ownership-policy.sh"
expect_status 'current out-of-store allowlist' 0 \
  bash "$repo_root/scripts/check-out-of-store-allowlist.sh"
expect_status 'current declared-secret scan' 0 \
  bash "$repo_root/scripts/check-declared-secrets.sh"

policy_fixture="$temp_root/package-policy.tsv"
printf '%s\n' \
  '  # leading-whitespace comments are valid' \
  $'ripgrep\trg\tnix\tNix owns the interactive command.' \
  >"$policy_fixture"
expect_status 'valid package policy fixture' 0 \
  env PACKAGE_OWNERSHIP_POLICY_FILE="$policy_fixture" \
  bash "$repo_root/scripts/check-package-ownership-policy.sh"

printf '%s\n' \
  $'ripgrep\trg\tnix\tFirst declaration.' \
  $'ripgrep\trg\tnix\tDuplicate declaration.' \
  >"$policy_fixture"
expect_status 'duplicate package policy fixture' 1 \
  env PACKAGE_OWNERSHIP_POLICY_FILE="$policy_fixture" \
  bash "$repo_root/scripts/check-package-ownership-policy.sh"

fixture_repo="$temp_root/secret-fixture"
mkdir -p "$fixture_repo/scripts"
cp "$repo_root/scripts/check-declared-secrets.sh" "$fixture_repo/scripts/"
printf '%s\n' '{ value = "ordinary configuration"; }' \
  >"$fixture_repo/flake.nix"
expect_status 'clean secret fixture' 0 \
  bash "$fixture_repo/scripts/check-declared-secrets.sh"

# Split the marker so this regression test does not trigger the repository scan.
printf '%s%s\n' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----' \
  >"$fixture_repo/private-key.txt"
expect_status 'private-key secret fixture' 1 \
  bash "$fixture_repo/scripts/check-declared-secrets.sh"

printf '%s\n' 'ordinary text' >"$fixture_repo/private-key.txt"
mock_bin="$temp_root/mock-bin"
mkdir -p "$mock_bin"
printf '%s\n' '#!/bin/sh' 'exit 2' >"$mock_bin/rg"
chmod 0700 "$mock_bin/rg"
expect_status 'secret scanner fails closed on ripgrep error' 2 \
  env PATH="$mock_bin:/usr/bin:/bin" \
  bash "$fixture_repo/scripts/check-declared-secrets.sh"

printf 'Script regression tests passed.\n'
