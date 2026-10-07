#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ DEPENDENCY CONTRACT TEST +++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies scripts/check-zsh-dependencies.zsh against a fixture registry:
# required vs. optional vs. --all scope, Brewfile/Arch manifest drift
# detection and --sync-manifests repair, owner-specific install hints, the
# seven-column row format, and rejection of conflicting scope options with
# exit status 2.
# ============================================================================ #

emulate -L zsh
setopt errexit nounset pipefail
umask 077

typeset tests_dir="${0:A:h:h}"
typeset config_dir="${tests_dir:h}"
typeset checker="$config_dir/scripts/check-zsh-dependencies.zsh"
typeset fixture_root=""

source "$tests_dir/helpers.zsh" || return 1
fixture_root="$(_zsh_test_temp_dir dependencies)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

typeset registry="$fixture_root/dependencies.tsv"
typeset brewfile="$fixture_root/Brewfile"
typeset archfile="$fixture_root/arch-zsh.txt"
typeset optional_row=$'optional\ttest\tcommand-that-cannot-exist'
optional_row+=$'\tmissing-brew\tmissing-arch\tmissing-nix\tMissing optional command.'

print -rl -- $'# level\tfeature\tcommands\thomebrew\tarch\tnix\tdescription' \
  $'required\tcore\tzsh\tzsh\tzsh\t-\tAvailable required command.' \
  "$optional_row" \
  >| "$registry"

typeset -a fixture_env=(
  "ZSH_DEPENDENCY_REGISTRY=$registry"
  "ZSH_DEPENDENCY_BREWFILE=$brewfile"
  "ZSH_DEPENDENCY_ARCHFILE=$archfile"
  "ZSH_DEPENDENCY_TMPDIR=$fixture_root/tmp"
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

# Install hints follow the owner: the nix column on a flake-managed host,
# the platform package manager elsewhere.
typeset owner owner_output expected_hint
for owner expected_hint in \
    nix "Home Manager package missing-nix" \
    homebrew "brew missing-brew" \
    arch "pacman missing-arch"; do
  owner_output="$(
    command env "${fixture_env[@]}" ZSH_DEPENDENCY_OWNER="$owner" \
      "$checker" --all --quiet 2>&1
  )" && {
    print -u2 "FAIL: strict mode accepted a missing optional command"
    exit 1
  }
  [[ "$owner_output" == *"install: $expected_hint"* ]] || {
    print -u2 "FAIL: $owner owner did not hint '$expected_hint'"
    exit 1
  }
done

# A native-ready manager must not direct the next missing-install repair back
# to Nix. Keep the diagnostic fixture independent of the actual FNM binary.
typeset fnm_registry="$fixture_root/fnm.tsv"
print -r -- $'required\tlanguages\tfnm\tfnm\t-\tfnm\tNode manager.' > "$fnm_registry"
typeset native_bin="$fixture_root/no-fnm"
typeset utility
command mkdir -p "$native_bin"
for utility in zsh mktemp rm uname; do
  command ln -s "$(whence -p "$utility")" "$native_bin/$utility"
done
typeset native_hint
native_hint="$(command env "${fixture_env[@]}" PATH="$native_bin" \
  HOME="$fixture_root" ZDOTDIR="$fixture_root" \
  ZSH_DEPENDENCY_REGISTRY="$fnm_registry" ZSH_DEPENDENCY_OWNER=nix \
  LCS_RUNTIME_MANAGER_BACKEND=native LCS_NATIVE_FNM_READY=1 \
  "$checker" --all --quiet 2>&1)" && {
  print -u2 'FAIL: missing native FNM passed strict dependency checking'
  exit 1
}

[[ "$native_hint" != *'Home Manager package fnm'* &&
   ( "$native_hint" == *'brew fnm'* || "$native_hint" == *'pacman fnm'* ) ]] || {
  print -u2 "FAIL: native FNM ownership hint: $native_hint"
  exit 1
}

typeset malformed_registry="$fixture_root/malformed.tsv"
print -r -- $'required\tcore\tzsh\tzsh\tzsh\tSix fields only.' \
  >| "$malformed_registry"
if command env "${fixture_env[@]}" \
    ZSH_DEPENDENCY_REGISTRY="$malformed_registry" \
    "$checker" --quiet >/dev/null 2>&1; then
  print -u2 "FAIL: a registry row without the nix column was accepted"
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
# End of tests/tools/test-dependency-contract.zsh
