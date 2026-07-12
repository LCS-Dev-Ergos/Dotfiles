#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ DEPENDENCY CONTRACT TEST +++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies scripts/check-zsh-dependencies.zsh against a fixture registry:
# required vs. optional vs. --all scope, Brewfile/Arch manifest drift
# detection and --sync-manifests repair, and rejection of conflicting scope
# options with exit status 2.
# ============================================================================ #

emulate -L zsh
setopt errexit nounset pipefail
umask 077

typeset test_dir="${0:A:h}"
typeset config_dir="${test_dir:h}"
typeset checker="$config_dir/scripts/check-zsh-dependencies.zsh"
typeset fixture_parent="$test_dir/.tmp"
typeset fixture_root=""

mkdir -p "$fixture_parent"
fixture_root="$(mktemp -d "$fixture_parent/dependencies.XXXXXX")" ||
  return 1
trap '
  command rm -rf -- "$fixture_root"
  command rmdir -- "$fixture_parent" 2>/dev/null
' EXIT
trap 'exit 130' INT TERM HUP

typeset registry="$fixture_root/dependencies.tsv"
typeset brewfile="$fixture_root/Brewfile"
typeset archfile="$fixture_root/arch-zsh.txt"
typeset optional_row=$'optional\ttest\tcommand-that-cannot-exist'
optional_row+=$'\tmissing-brew\tmissing-arch\tMissing optional command.'

print -rl -- $'# level\tfeature\tcommands\thomebrew\tarch\tdescription' \
  $'required\tcore\tzsh\tzsh\tzsh\tAvailable required command.' \
  "$optional_row" \
  >| "$registry"

typeset -a fixture_env=(
  "ZSH_DEPENDENCY_REGISTRY=$registry"
  "ZSH_DEPENDENCY_BREWFILE=$brewfile"
  "ZSH_DEPENDENCY_ARCHFILE=$archfile"
  "ZSH_UI_STYLE=plain"
)

command env "${fixture_env[@]}" "$checker" \
  --sync-manifests --quiet >/dev/null
command env "${fixture_env[@]}" "$checker" \
  --check-manifests --quiet >/dev/null

print -r -- 'brew "unexpected"' >> "$brewfile"
if command env "${fixture_env[@]}" "$checker" \
    --check-manifests --quiet >/dev/null 2>&1; then
  print -u2 "FAIL: manifest drift was accepted"
  exit 1
fi

command env "${fixture_env[@]}" "$checker" \
  --sync-manifests --check-manifests --quiet >/dev/null

command env "${fixture_env[@]}" "$checker" --quiet >/dev/null
if command env "${fixture_env[@]}" "$checker" --all --quiet \
    >/dev/null 2>&1; then
  print -u2 "FAIL: strict mode accepted a missing optional command"
  exit 1
fi

if command env "${fixture_env[@]}" "$checker" \
    --required --all --quiet >/dev/null 2>&1; then
  print -u2 "FAIL: conflicting scope options were accepted"
  exit 1
else
  (( $? == 2 )) || {
    print -u2 "FAIL: conflicting scope options did not return status 2"
    exit 1
  }
fi

print -r -- "PASS: dependency scopes, drift detection, and manifest sync"

# ============================================================================ #
# End of tests/test-dependency-contract.zsh
