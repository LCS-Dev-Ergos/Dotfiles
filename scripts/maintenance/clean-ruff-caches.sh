#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# ++++++++++++++++++++++++++++ RUFF CACHE CLEANUP ++++++++++++++++++++++++++++ #
# ============================================================================ #
# Removes the .ruff_cache directories Ruff leaves below the repository. A
# directory is removed only when it is a real directory, not a symlink, is
# ignored by Git and holds no tracked file, and carries the CACHEDIR.TAG Ruff
# writes, with the signature of the Cache Directory Tagging Specification.
# Anything else with the same name is reported and left alone. Nested Git
# repositories are not entered. Ruff recreates a cache on its next run.
#
# Paths reach Git prefixed with ./ and, where Git allows it, as literal
# pathspecs, so a directory name can never act as pathspec magic or a glob.
# A failed Git query keeps the directory. The tag is deleted last, so an
# interrupted removal leaves a cache the next run still recognizes.
#
# Usage:
#   scripts/maintenance/clean-ruff-caches.sh [--dry-run]
#
# Exit status: 0 when every cache found was removed (or, with --dry-run,
# would be), 1 when a directory was left alone, 2 on a usage error.
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

readonly signature='Signature: 8a477f597d28d172789f06886806bc55'

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
}

dry_run=0
for argument in "$@"; do
  case "$argument" in
  -n | --dry-run) dry_run=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
done

if ! command -v git >/dev/null 2>&1; then
  printf 'clean-ruff-caches requires git.\n' >&2
  exit 2
fi
# GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and the like would make Git answer
# for another repository than the one being cleaned.
while IFS= read -r variable; do
  unset "$variable"
done < <(git rev-parse --local-env-vars)

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repo_root"
if [[ "$(git rev-parse --show-toplevel 2>/dev/null)" != "$repo_root" ]]; then
  printf 'clean-ruff-caches: %s is not the top of a Git work tree.\n' \
    "$repo_root" >&2
  exit 2
fi

# The reason a candidate must stay, or nothing when it is a Ruff cache.
refusal() {
  local directory="$1"
  local tag="$directory/CACHEDIR.TAG"
  local status=0 tracked
  if [[ -L "$directory" || ! -d "$directory" ]]; then
    printf 'not a real directory'
    return
  fi
  if [[ -L "$tag" || ! -f "$tag" ]]; then
    printf 'no CACHEDIR.TAG'
    return
  fi
  if [[ "$(head -c "${#signature}" -- "$tag" 2>/dev/null)" != "$signature" ]]; then
    printf 'CACHEDIR.TAG lacks the cache signature'
    return
  fi
  git check-ignore -q -- "./$directory" 2>/dev/null || status=$?
  if ((status == 1)); then
    printf 'not ignored by Git'
    return
  elif ((status != 0)); then
    printf 'git check-ignore failed'
    return
  fi
  if ! tracked="$(GIT_LITERAL_PATHSPECS=1 git ls-files -- "./$directory")"; then
    printf 'git ls-files failed'
  elif [[ -n "$tracked" ]]; then
    printf 'holds tracked files'
  fi
}

# Delete a cache's contents, then its tag, then the empty directory.
remove_cache() {
  local directory="$1"
  local tag="$directory/CACHEDIR.TAG"
  local entry
  local -a entries
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  shopt -u nullglob dotglob
  for entry in "${entries[@]}"; do
    if [[ "$entry" != "$tag" ]]; then
      rm -rf -- "$entry" || return 1
    fi
  done
  rm -f -- "$tag" || return 1
  rmdir -- "$directory"
}

candidates="$(mktemp "${TMPDIR:-/tmp}/clean-ruff-caches.XXXXXX")"
cleanup() {
  rm -f -- "$candidates"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! find . \
  \( -path ./.git -o \( ! -path . -type d -exec test -e '{}/.git' ';' \) \) \
  -prune -o -name .ruff_cache -prune -print0 >"$candidates"; then
  printf 'clean-ruff-caches: the search did not complete; nothing removed.\n' >&2
  exit 1
fi
sort -z -o "$candidates" -- "$candidates"

removed=0
kept=0
while IFS= read -r -d '' directory; do
  directory="${directory#./}"
  reason="$(refusal "$directory")"
  if [[ -n "$reason" ]]; then
    printf 'kept %s (%s)\n' "$directory" "$reason" >&2
    kept=$((kept + 1))
  elif ((dry_run)); then
    printf 'would remove %s\n' "$directory"
    removed=$((removed + 1))
  elif remove_cache "$directory"; then
    printf 'removed %s\n' "$directory"
    removed=$((removed + 1))
  else
    printf 'kept %s (could not remove all of it)\n' "$directory" >&2
    kept=$((kept + 1))
  fi
done <"$candidates"

verb='Removed'
((dry_run)) && verb='Would remove'
printf '%s %d Ruff cache(s); %d left alone.\n' "$verb" "$removed" "$kept"
((kept == 0))

# ============================================================================ #
# End of maintenance/clean-ruff-caches.sh.
