#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
allowlist="$repo_root/home/out-of-store-allowlist.tsv"
config_root="${XDG_CONFIG_HOME:-$HOME/.config}"
allowed_prefixes=()
find_command="find"
issues=0
repo_links=0

# GNU find is standard on Linux and is installed as gfind by the declared
# Darwin findutils formula. Bounded traversal avoids walking large application
# databases that are unrelated to Home Manager's configuration links.
if command -v gfind >/dev/null 2>&1; then
  find_command="$(command -v gfind)"
elif ! find . --version >/dev/null 2>&1; then
  echo 'audit-live-config requires GNU find (the Darwin flake declares findutils).' >&2
  exit 2
fi

while IFS= read -r module; do
  allowed_prefixes+=("${module%/*}")
done < <(awk -F '\t' '!/^#/ && NF { print $1 }' "$allowlist")

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

inspect_link() {
  local link="$1"
  local resolved relative status

  if [[ ! -e "$link" ]]; then
    printf 'BROKEN  %s -> %s\n' "$link" "$(readlink "$link")" >&2
    issues=$((issues + 1))
    return
  fi

  resolved="$(realpath "$link")"
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
  status="$(git -C "$repo_root" -c core.fsmonitor=false status \
    --short --untracked-files=all -- "$relative")"
  if [[ -n "$status" ]]; then
    printf 'DIRTY registered target for %s:\n%s\n' "$link" "$status" >&2
    issues=$((issues + 1))
  fi
}

if [[ -d "$config_root" ]]; then
  while IFS= read -r -d '' link; do
    inspect_link "$link"
  done < <("$find_command" "$config_root" -maxdepth 4 -type l -print0)
fi

# Home Manager also owns a small number of dotfiles directly below HOME. Shell
# globs keep this portable to the BSD find shipped by macOS.
for link in "$HOME"/.* "$HOME"/*; do
  [[ -L "$link" ]] || continue
  inspect_link "$link"
done

if ((issues)); then
  printf 'Live configuration audit found %d issue(s) across %d repository-backed link(s).\n' \
    "$issues" "$repo_links" >&2
  exit 1
fi

printf 'Live configuration audit passed; %d registered repository-backed link(s) remain.\n' \
  "$repo_links"
