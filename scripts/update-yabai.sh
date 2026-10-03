#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# +++++++++++++++++++++++++++++++ YABAI UPDATER ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Reports or applies the newest signed release of the yabai fork
# (LCS-Dev-Ergos/yabai) in darwin/yabai-package.nix.
#
# Usage:
#   scripts/update-yabai.sh --check
#   scripts/update-yabai.sh --apply
#
# Releases are tags named v<major>.<minor>.<patch>, compared by Semantic
# Versioning precedence. Release candidates (-rc.<n>) are never selected. The
# tags before 8.0.0, v<version>-lcs.<n>, are pre-releases of <version> and rank
# below it.
# --apply prefetches the release tarball into the store, then rewrites version
# and hash together. It never builds, stages, commits, or switches. The switch
# restarts yabai, whose yabairc reloads the scripting addition into Dock.
#
# Exit status: 0 up to date or applied, 1 update available (--check),
# 2 usage, environment, or resolution error.
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

repository='https://github.com/LCS-Dev-Ergos/yabai'

# +++++++++++++++++++++++++ USAGE & ARGUMENT PARSING +++++++++++++++++++++++++ #

usage='usage: update-yabai.sh --check|--apply'
die() {
  printf 'update-yabai: %s\n' "$1" >&2
  exit 2
}

(($# == 1)) || die "$usage"
case "$1" in
--check | --apply) operation="$1" ;;
-h | --help)
  printf '%s\n' "$usage"
  exit 0
  ;;
*) die "unknown option: $1 ($usage)" ;;
esac

# +++++++++++++++++++++++++++ PREREQUISITE CHECKS ++++++++++++++++++++++++++++ #

for required_command in git grep nix sed sort; do
  command -v "$required_command" >/dev/null 2>&1 ||
    die "requires $required_command"
done

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
package_file="$repo_root/darwin/yabai-package.nix"
[[ -f "$package_file" ]] || die "missing $package_file"

current="$(sed -nE 's/^  version = "([^"]+)";$/\1/p' "$package_file")"
[[ -n "$current" ]] || die "no version in $package_file"

# +++++++++++++++++++++++++++++ RELEASE LOOKUP +++++++++++++++++++++++++++++++ #

if ! tags="$(git ls-remote --tags --refs "$repository" 'v*')"; then
  die "cannot list tags of $repository"
fi

# Each release as "<major> <minor> <patch> <rank> <n> <version>": a release
# ranks 1 and an -lcs.<n> pre-release 0, so a sort on the numeric fields puts
# the newest last. Other tags, release candidates among them, are skipped.
latest="$(printf '%s\n' "$tags" |
  sed -nE \
    -e 's|^[0-9a-f]+[[:space:]]+refs/tags/v(([0-9]+)\.([0-9]+)\.([0-9]+))$|\2 \3 \4 1 0 \1|p' \
    -e 's|^[0-9a-f]+[[:space:]]+refs/tags/v(([0-9]+)\.([0-9]+)\.([0-9]+)-lcs\.([0-9]+))$|\2 \3 \4 0 \5 \1|p' |
  sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n | sed -nE '$s/^([0-9]+ ){5}//p')"
[[ -n "$latest" ]] || die "no release tag in $repository"

if [[ "$latest" == "$current" ]]; then
  printf 'yabai %s is the newest release\n' "$current"
  exit 0
fi

printf 'yabai %s -> %s\n  %s/releases/tag/v%s\n' "$current" "$latest" "$repository" "$latest"
[[ "$operation" == --apply ]] || exit 1

# ++++++++++++++++++++++++++++++++++ APPLY +++++++++++++++++++++++++++++++++++ #

if ! git -C "$repo_root" diff --quiet HEAD -- darwin/yabai-package.nix; then
  die 'darwin/yabai-package.nix has uncommitted changes; commit or stash them first'
fi

url="$repository/releases/download/v$latest/yabai-v$latest.tar.gz"
if ! prefetch="$(nix store prefetch-file --json --hash-type sha256 "$url")"; then
  die "cannot fetch $url"
fi
hash="$(printf '%s\n' "$prefetch" | sed -nE 's/.*"hash": *"(sha256-[A-Za-z0-9+/=]+)".*/\1/p')"
[[ -n "$hash" ]] || die "no hash in the prefetch result for $url"

sed -i.orig -E \
  -e "s|^  version = \"[^\"]+\";$|  version = \"$latest\";|" \
  -e "s|^    hash = \"sha256-[A-Za-z0-9+/=]+\";$|    hash = \"$hash\";|" \
  "$package_file"
rm -f "$package_file.orig"

if ! grep -qF "version = \"$latest\";" "$package_file" || ! grep -qF "hash = \"$hash\";" "$package_file"; then
  git -C "$repo_root" checkout -- darwin/yabai-package.nix
  die "could not rewrite $package_file; left it unchanged"
fi

printf 'updated %s\n  hash %s\n' "${package_file#"$repo_root"/}" "$hash"
