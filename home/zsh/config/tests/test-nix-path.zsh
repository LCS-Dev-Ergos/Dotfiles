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

typeset fixture_root=""
source "$test_root/tests/helpers.zsh" || return 1
fixture_root="$(_zsh_test_temp_dir nix-path)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'return 130' INT TERM HUP

command env -i \
  HOME="$HOME" \
  USER="$USER" \
  PATH="/opt/homebrew/bin:/usr/bin:/bin:/etc/profiles/per-user/$USER/bin" \
  PLATFORM=macOS \
  XDG_CACHE_HOME="$fixture_root/cache" \
  ZSH_CONFIG_DIR="$test_root" \
  zsh -dfc '
    source "$ZSH_CONFIG_DIR/lib/90-path.zsh" || exit 1
    typeset nix_bin="/etc/profiles/per-user/$USER/bin"
    typeset brew_bin="/opt/homebrew/bin"
    typeset -i nix_index=${path[(Ie)$nix_bin]}
    typeset -i brew_index=${path[(Ie)$brew_bin]}
    (( nix_index > 0 && brew_index > 0 && nix_index < brew_index ))
  ' || {
  print -u2 "FAIL: interactive PATH does not prefer Nix over Homebrew"
  return 1
}

print -r -- \
  "PASS: non-interactive Nix availability and interactive Nix precedence"

# ============================================================================ #
# End of test-nix-path.zsh
