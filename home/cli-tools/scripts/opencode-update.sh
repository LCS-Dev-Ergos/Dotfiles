#!/usr/bin/env bash
# shellcheck shell=bash
# Update the dedicated OpenCode nixpkgs input without applying a generation.
# OPENCODE_UPDATE_REPOSITORY_ROOT is supplied by the Nix wrapper.

set -euo pipefail

die() {
  printf 'opencode-update: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: opencode-update --check | --apply' \
    '  --check  Compare the locked package with nixpkgs-unstable.' \
    '  --apply  Update, validate, and fetch OpenCode without compiling or switching.'
}

if [[ -z "${OPENCODE_UPDATE_REPOSITORY_ROOT:-}" ]]; then
  die 'OPENCODE_UPDATE_REPOSITORY_ROOT is not set by the Nix wrapper'
fi

repository_root="$OPENCODE_UPDATE_REPOSITORY_ROOT"
flake_file="$repository_root/flake.nix"
lock_file="$repository_root/flake.lock"
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'

(( $# == 1 )) || {
  usage >&2
  exit 64
}

case "$1" in
  --check | --apply) operation="$1" ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

[[ -f "$flake_file" && -f "$lock_file" ]] || die "missing flake files in $repository_root"
is_worktree="$(git -C "$repository_root" rev-parse --is-inside-work-tree)" \
  || die "$repository_root is not a Git worktree"
[[ "$is_worktree" == "true" ]] || die "$repository_root is not a Git worktree"

system="$(nix eval --impure --raw --expr 'builtins.currentSystem')" \
  || die 'could not determine the current Nix system'
package_installable="$repository_root#packages.$system.opencode"
current_version="$(nix eval --raw "$package_installable.version")" \
  || die 'could not evaluate the locked OpenCode version'
latest_version="$(nix eval --refresh --raw \
  "github:NixOS/nixpkgs/nixpkgs-unstable#legacyPackages.$system.opencode.version")" \
  || die 'could not evaluate OpenCode from nixpkgs-unstable'
[[ "$current_version" =~ $version_pattern ]] \
  || die "the locked package has an unsupported version: $current_version"
[[ "$latest_version" =~ $version_pattern ]] \
  || die "nixpkgs-unstable returned an unsupported version: $latest_version"

if [[ "$current_version" == "$latest_version" ]]; then
  printf 'OpenCode is already current in nixpkgs at %s.\n' "$current_version"
  exit 0
fi
if [[ "$(printf '%s\n%s\n' "$current_version" "$latest_version" | sort -V | tail -n1)" != "$latest_version" ]]; then
  die "refusing a non-increasing OpenCode package: $current_version -> $latest_version"
fi

printf 'OpenCode package update available: %s -> %s\n' "$current_version" "$latest_version"
[[ "$operation" == "--apply" ]] || exit 0

git_directory="$(git -C "$repository_root" rev-parse --path-format=absolute --git-dir)"
lock_directory="$git_directory/opencode-update.lock"
if ! mkdir "$lock_directory" 2>/dev/null; then
  die 'another opencode-update --apply is already running'
fi

temporary_directory=''
rollback_required=0
cleanup() {
  local status=$?
  if (( rollback_required )); then
    cp -p "$temporary_directory/flake.lock" "$lock_file"
    printf '%s\n' 'opencode-update: restored flake.lock after a failed validation.' >&2
  fi
  [[ -z "$temporary_directory" ]] || rm -rf "$temporary_directory"
  rmdir "$lock_directory" 2>/dev/null || true
  trap - EXIT HUP INT TERM
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

if ! git -C "$repository_root" diff --quiet -- flake.nix flake.lock \
  || ! git -C "$repository_root" diff --cached --quiet -- flake.nix flake.lock; then
  die 'flake.nix or flake.lock has uncommitted changes; commit or stash them first'
fi
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/opencode-update.XXXXXX")"
cp -p "$lock_file" "$temporary_directory/flake.lock"

rollback_required=1
nix flake update opencode-nixpkgs --flake "$repository_root"

# Updating the dedicated input must not move any other lockfile node. Remove
# that node from both snapshots and require everything else to be identical.
jq -S '
  .nodes.root.inputs["opencode-nixpkgs"] as $node
  | del(.nodes[$node])
  | del(.nodes.root.inputs["opencode-nixpkgs"])
' "$temporary_directory/flake.lock" >"$temporary_directory/lock.before.json"
jq -S '
  .nodes.root.inputs["opencode-nixpkgs"] as $node
  | del(.nodes[$node])
  | del(.nodes.root.inputs["opencode-nixpkgs"])
' "$lock_file" >"$temporary_directory/lock.after.json"
cmp -s "$temporary_directory/lock.before.json" "$temporary_directory/lock.after.json" \
  || die 'updating OpenCode changed another flake input'

updated_version="$(nix eval --raw "$package_installable.version")" \
  || die 'could not evaluate the updated OpenCode version'
[[ "$updated_version" =~ $version_pattern ]] \
  || die "the updated package has an unsupported version: $updated_version"
if [[ "$(printf '%s\n%s\n' "$current_version" "$updated_version" | sort -V | tail -n1)" != "$updated_version" \
  || "$updated_version" == "$current_version" ]]; then
  die "the updated input did not increase OpenCode: $current_version -> $updated_version"
fi

nix flake check --all-systems --no-build "$repository_root"

# Disable both local and remote builders. This succeeds only when the complete
# package closure can be substituted from a configured binary cache.
nix build --no-link --max-jobs 0 --builders '' "$package_installable"
git -C "$repository_root" diff -- flake.lock

rollback_required=0
printf '%s\n' \
  "OpenCode $updated_version fetched from cache. Review the lockfile, then commit and switch when ready."
