#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++++ NIX PATH TEST +++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies that .zshenv exposes the active nix-darwin system profile to
# non-interactive shells without replacing the existing user-selected Nix CLI.
# The host-specific assertions are skipped when nix-darwin is not installed.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail

typeset test_root="${0:A:h:h}"
typeset darwin_rebuild="/run/current-system/sw/bin/darwin-rebuild"

if [[ "$OSTYPE" != darwin* || ! -x "$darwin_rebuild" ]]; then
  print -r -- "PASS: nix-darwin PATH policy is not applicable on this host"
  return 0
fi

typeset probe
probe="$(command env -i \
  HOME="$HOME" \
  USER="$USER" \
  TERM="${TERM:-dumb}" \
  PATH="/usr/bin:/bin" \
  ZSH_CONFIG_DIR="$test_root" \
  zsh -dfc '
    source "$ZSH_CONFIG_DIR/.zshenv" || exit 1
    typeset -a system_entries
    system_entries=("${(@M)path:#/run/current-system/sw/bin}")
    print -r -- "darwin=$(whence -p darwin-rebuild)"
    print -r -- "nix=$(whence -p nix)"
    print -r -- "count=${#system_entries[@]}"
  '
)" || {
  print -u2 "FAIL: non-interactive .zshenv probe failed"
  return 1
}

[[ "$probe" == *"darwin=$darwin_rebuild"* ]] || {
  print -u2 "FAIL: darwin-rebuild is unavailable after sourcing .zshenv"
  return 1
}
if [[ -x "$HOME/.nix-profile/bin/nix" ]]; then
  [[ "$probe" == *"nix=$HOME/.nix-profile/bin/nix"* ]] || {
    print -u2 \
      "FAIL: the system profile unexpectedly replaced the selected Nix CLI"
    return 1
  }
fi
[[ "$probe" == *'count=1'* ]] || {
  print -u2 "FAIL: the nix-darwin system profile is missing or duplicated"
  return 1
}

print -r -- "PASS: non-interactive nix-darwin PATH and CLI precedence"

# ============================================================================ #
# End of test-nix-path.zsh
