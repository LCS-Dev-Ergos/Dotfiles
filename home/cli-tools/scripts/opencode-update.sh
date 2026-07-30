#!/usr/bin/env bash
# shellcheck shell=bash
# Update the release-tagged OpenCode flake input without applying a generation.
# OPENCODE_UPDATE_REPOSITORY_ROOT is supplied by the Nix wrapper.

set -euo pipefail

die() {
  printf 'opencode-update: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: opencode-update --check | --apply' \
    '  --check  Report the latest stable release without modifying the checkout.' \
    '  --apply  Update, validate, and build the OpenCode release without switching.'
}

if [[ -z "${OPENCODE_UPDATE_REPOSITORY_ROOT:-}" ]]; then
  die 'OPENCODE_UPDATE_REPOSITORY_ROOT is not set by the Nix wrapper'
fi

repository_root="$OPENCODE_UPDATE_REPOSITORY_ROOT"
flake_file="$repository_root/flake.nix"
lock_file="$repository_root/flake.lock"
tag_pattern='^v[0-9]+\.[0-9]+\.[0-9]+$'

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

mapfile -t configured_tags < <(
  sed -nE 's|^[[:space:]]*url = "github:anomalyco/opencode/(v[0-9]+\.[0-9]+\.[0-9]+)";$|\1|p' \
    "$flake_file"
)
(( ${#configured_tags[@]} == 1 )) \
  || die 'expected exactly one stable OpenCode release tag in flake.nix'
current_tag="${configured_tags[0]}"

release_json="$(curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --retry 2 \
  --retry-delay 1 \
  --user-agent 'opencode-update' \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  'https://api.github.com/repos/anomalyco/opencode/releases/latest')" \
  || die 'could not query the official OpenCode release API'
latest_tag="$(printf '%s' "$release_json" | jq -er '
  select(.draft == false and .prerelease == false) | .tag_name
')" || die 'the official release API returned an invalid stable release'
[[ "$latest_tag" =~ $tag_pattern ]] \
  || die "the official release API returned an unsupported tag: $latest_tag"

if [[ "$current_tag" == "$latest_tag" ]]; then
  printf 'OpenCode is already current at %s.\n' "$current_tag"
  exit 0
fi
if [[ "$(printf '%s\n%s\n' "$current_tag" "$latest_tag" | sort -V | tail -n1)" != "$latest_tag" ]]; then
  die "refusing a non-increasing OpenCode release: $current_tag -> $latest_tag"
fi

printf 'OpenCode update available: %s -> %s\n' "$current_tag" "$latest_tag"
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
    cp -p "$temporary_directory/flake.nix" "$flake_file"
    cp -p "$temporary_directory/flake.lock" "$lock_file"
    printf '%s\n' 'opencode-update: restored flake.nix and flake.lock after a failed validation.' >&2
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
command -v darwin-rebuild >/dev/null \
  || die 'darwin-rebuild is not available on PATH'

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/opencode-update.XXXXXX")"
cp -p "$flake_file" "$temporary_directory/flake.nix"
cp -p "$lock_file" "$temporary_directory/flake.lock"
cp -p "$flake_file" "$temporary_directory/flake.nix.candidate"
sed -i "s|github:anomalyco/opencode/$current_tag|github:anomalyco/opencode/$latest_tag|" \
  "$temporary_directory/flake.nix.candidate"
cmp -s "$flake_file" "$temporary_directory/flake.nix.candidate" \
  && die 'could not replace the configured OpenCode release tag'

rollback_required=1
mv -f "$temporary_directory/flake.nix.candidate" "$flake_file"
nix flake update opencode --flake "$repository_root"
nix flake check --all-systems --no-build "$repository_root"
darwin-rebuild build --flake "$repository_root#LCSMacBook-Pro"
git -C "$repository_root" diff -- flake.nix flake.lock

rollback_required=0
printf '%s\n' \
  'OpenCode release update validated. Review the diff, then commit and switch when ready.'
