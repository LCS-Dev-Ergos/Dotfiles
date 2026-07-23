#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# ++++++++++++++++++++++++++++ LIVE CONFIG AUDIT +++++++++++++++++++++++++++++ #
# ============================================================================ #
# Walks every symlink under $XDG_CONFIG_HOME (or ~/.config) and the dotfiles
# directly below $HOME, and checks each one that resolves into this repository
# against home/out-of-store-allowlist.tsv. Flags broken links, repository
# links that aren't registered, and registered targets with uncommitted
# changes.
#
# Usage:
#   scripts/audit-live-config.sh
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
allowlist="$repo_root/home/out-of-store-allowlist.tsv"
home_dir="${HOME:-}"
if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
  printf 'audit-live-config requires HOME to name an existing directory.\n' >&2
  exit 2
fi
config_root="${XDG_CONFIG_HOME:-$home_dir/.config}"
allowed_prefixes=()
find_command=""
issues=0
repo_links=0

# ++++++++++++++++++++++++++++ FIND COMMAND SETUP ++++++++++++++++++++++++++++ #

for required_command in awk git readlink realpath; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'audit-live-config requires %s.\n' "$required_command" >&2
    exit 2
  fi
done

if [[ ! -r "$allowlist" ]]; then
  printf 'Out-of-store allowlist is missing or unreadable: %s\n' \
    "$allowlist" >&2
  exit 2
fi

# GNU find is standard on Linux and is installed as gfind by the declared
# Darwin findutils formula. Bounded traversal avoids walking large application
# databases that are unrelated to Home Manager's configuration links.
if command -v gfind >/dev/null 2>&1; then
  find_command="$(command -v gfind)"
elif command -v find >/dev/null 2>&1 &&
  find_command="$(command -v find)" &&
  ! "$find_command" . --version >/dev/null 2>&1; then
  echo 'audit-live-config requires GNU find (the Darwin flake declares findutils).' >&2
  exit 2
fi
if [[ -z "$find_command" ]]; then
  printf 'audit-live-config requires GNU find.\n' >&2
  exit 2
fi

while IFS= read -r module; do
  allowed_prefixes+=("${module%/*}")
done < <(awk -F '\t' '!/^#/ && NF { print $1 }' "$allowlist")

# +++++++++++++++++++++++++++++ HELPER FUNCTIONS +++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# is_registered_source
# @internal
# @description Checks whether a repo-relative path is covered by an entry in
# home/out-of-store-allowlist.tsv.
# @arg $1 path Repository-relative path to check.
# @exitcode 1 If no allowlist prefix matches.
# -----------------------------------------------------------------------------
is_registered_source() {
  local relative="$1"
  local prefix

  for prefix in "${allowed_prefixes[@]}"; do
    if [[ "$relative" == "$prefix" || "$relative" == "$prefix/"* ]]; then
      return 0
    fi
  done

  return 1
}

# -----------------------------------------------------------------------------
# inspect_link
# @internal
# @description Reports a symlink's status: broken, unregistered, or a
# registered target with uncommitted changes. Increments issues for anything
# that needs attention.
# @arg $1 path Symlink to inspect.
# @set issues int Incremented for every problem found.
# @set repo_links int Incremented for every link that resolves into the repo.
# -----------------------------------------------------------------------------
inspect_link() {
  local link="$1"
  local resolved relative status

  if [[ ! -e "$link" ]]; then
    printf 'BROKEN  %s -> %s\n' "$link" "$(readlink "$link")" >&2
    issues=$((issues + 1))
    return
  fi

  if ! resolved="$(realpath "$link" 2>/dev/null)"; then
    printf 'UNRESOLVED  %s\n' "$link" >&2
    issues=$((issues + 1))
    return
  fi
  if [[ "$resolved" != "$repo_root" && "$resolved" != "$repo_root/"* ]]; then
    return
  fi

  repo_links=$((repo_links + 1))
  relative="${resolved#"$repo_root"/}"

  if ! is_registered_source "$relative"; then
    printf 'UNREGISTERED  %s -> %s\n' "$link" "$resolved" >&2
    issues=$((issues + 1))
    return
  fi

  printf 'REGISTERED  %s -> %s\n' "$link" "$resolved"
  if ! status="$(git --literal-pathspecs -C "$repo_root" \
    -c core.fsmonitor=false status --short --untracked-files=all \
    -- "$relative")"; then
    printf 'GIT ERROR  Unable to inspect %s for %s\n' "$relative" "$link" >&2
    issues=$((issues + 1))
    return
  fi
  if [[ -n "$status" ]]; then
    printf 'DIRTY registered target for %s:\n%s\n' "$link" "$status" >&2
    issues=$((issues + 1))
  fi
}

# ++++++++++++++++++++++++++++++++ MAIN SCAN +++++++++++++++++++++++++++++++++ #

if [[ -d "$config_root" ]]; then
  while IFS= read -r -d '' link; do
    inspect_link "$link"
  done < <("$find_command" "$config_root" -maxdepth 4 -type l -print0)
fi

# Home Manager also owns a small number of dotfiles directly below HOME. Shell
# globs keep this portable to the BSD find shipped by macOS.
for link in "$home_dir"/.* "$home_dir"/*; do
  [[ -L "$link" ]] || continue
  inspect_link "$link"
done

# +++++++++++++++++++++++++++++++++ SUMMARY ++++++++++++++++++++++++++++++++++ #

if ((issues)); then
  printf 'Live configuration audit found %d issue(s) across %d repository-backed link(s).\n' \
    "$issues" "$repo_links" >&2
  exit 1
fi

printf 'Live configuration audit passed; %d registered repository-backed link(s) remain.\n' \
  "$repo_links"

# ============================================================================ #
# End of audit-live-config.sh.
