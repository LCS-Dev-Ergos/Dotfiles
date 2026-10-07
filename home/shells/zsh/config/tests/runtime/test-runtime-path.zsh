#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ RUNTIME PATH TEST +++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies optional-root handling and language-runtime precedence with isolated
# homes and cold/warm PATH caches. Account, HOME, XDG data and opam switch
# changes must invalidate cached selection; native FNM must remain discoverable.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir runtime-path)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

# Isolated environment fixtures for runtime path resolution.
export HOME="$fixture_root/one"
export XDG_CACHE_HOME="$fixture_root/cache"
export XDG_DATA_HOME="$fixture_root/data-one"
export PLATFORM=Linux
export USER=fixture-one

unset PYENV_ROOT GOPATH ANDROID_HOME SDKMAN_DIR FNM_DIR FNM_MULTISHELL_PATH
unset OPAM_SWITCH_PREFIX NPM_CONFIG_PREFIX
unset RBENV_ROOT CARGO_HOME ELAN_HOME GHCUP_INSTALL_BASE_PREFIX JULIAUP_HOME
unset LCS_RUNTIME_MANAGER_BACKEND LCS_NATIVE_FNM_READY

command mkdir -p \
  "$HOME/.nix-profile/bin" \
  "$HOME/.opam/default/bin" \
  "$fixture_root/two/.nix-profile/bin" \
  "$XDG_DATA_HOME/npm-global/bin" \
  "$fixture_root/data-two/npm-global/bin" \
  "$fixture_root/project/_opam/bin"

typeset base_path="/usr/bin:/bin"
export PATH="$base_path"

source "$test_root/runtime-helpers.zsh"
PLATFORM=Linux
source "$test_root/lib/90-path.zsh"

# Verify that $first appears before $second in the active path array.
_assert_order() {
  local first="$1" second="$2"
  (( ${path[(Ie)$first]} > 0 && ${path[(Ie)$first]} < ${path[(Ie)$second]} )) || {
    print -u2 "FAIL: $first must precede $second: $PATH"
    return 1
  }
}

# Verify Nix profile precedence over system bin during cold init and cache rebuild.
_assert_order "$HOME/.nix-profile/bin" /bin

PATH="$base_path"
zsh_rebuild_path
_assert_order "$HOME/.nix-profile/bin" /bin

# Line 2 of path.cache holds the cache signature; changing USER must invalidate it.
typeset old_signature="$(sed -n '2p' "$XDG_CACHE_HOME/zsh/path.cache")"
export USER=fixture-two
PATH="$base_path"
zsh_rebuild_path
[[ "$(sed -n '2p' "$XDG_CACHE_HOME/zsh/path.cache")" != "$old_signature" ]] || {
  print -u2 'FAIL: cache ignores account identity'
  return 1
}

# Switching HOME and XDG data roots must rebuild paths without stale cache leaks.
export HOME="$fixture_root/two"
export XDG_DATA_HOME="$fixture_root/data-two"
PATH="$base_path"
zsh_rebuild_path
_assert_order "$HOME/.nix-profile/bin" /bin
[[ "$PATH" != *"$fixture_root/one/"* && "$PATH" != *"$fixture_root/data-one/"* ]] || {
  print -u2 'FAIL: cache reused another home or data directory'
  return 1
}

# Active project opam switch must take precedence over user default opam switch.
export HOME="$fixture_root/one"
export OPAM_SWITCH_PREFIX="$fixture_root/project/_opam"
PATH="$OPAM_SWITCH_PREFIX/bin:$base_path"
zsh_rebuild_path
_assert_order "$OPAM_SWITCH_PREFIX/bin" "$HOME/.opam/default/bin"

# Precedence must remain stable across repeated cache rebuilds.
PATH="$OPAM_SWITCH_PREFIX/bin:$base_path"
zsh_rebuild_path
_assert_order "$OPAM_SWITCH_PREFIX/bin" "$HOME/.opam/default/bin"

# Mock a native FNM binary.
command mkdir -p "$fixture_root/fnm"
print -rl -- '#!/bin/sh' 'echo "native fnm"' > "$fixture_root/fnm/fnm"
command chmod 700 "$fixture_root/fnm/fnm"

# Native FNM runtime root must precede the Nix profile in both cold and rebuilt paths.
export FNM_DIR="$fixture_root/fnm"
export LCS_RUNTIME_MANAGER_BACKEND=native
export LCS_NATIVE_FNM_READY=1
PATH="$base_path"
zsh_rebuild_path
_assert_order "$FNM_DIR" "$HOME/.nix-profile/bin"

PATH="$base_path"
zsh_rebuild_path
_assert_order "$FNM_DIR" "$HOME/.nix-profile/bin"

# A changed native root must invalidate a warm cache on both platforms. Each
# manager directory must also beat a fallback supplied by a Nix profile.
typeset host_kind root_variable root_suffix iteration root_dir
for host_kind in Linux macOS; do
  PLATFORM="$host_kind"
  for root_variable root_suffix in \
      RBENV_ROOT shims CARGO_HOME bin ELAN_HOME bin \
      GHCUP_INSTALL_BASE_PREFIX .ghcup/bin JULIAUP_HOME bin \
      SDKMAN_DIR candidates/java/current/bin; do
    for iteration in one two; do
      root_dir="$fixture_root/$root_variable-$iteration"
      export "$root_variable=$root_dir"
      command mkdir -p "$root_dir/$root_suffix"
      PATH="$base_path"
      zsh_rebuild_path
      _assert_order "$root_dir/$root_suffix" "$HOME/.nix-profile/bin"
      PATH="$base_path"
      zsh_rebuild_path
      _assert_order "$root_dir/$root_suffix" "$HOME/.nix-profile/bin"
      if [[ "$iteration" == two && "$PATH" == *"$fixture_root/$root_variable-one/"* ]]; then
        print -u2 "FAIL: $host_kind cache ignores $root_variable"
        return 1
      fi
    done
    unset "$root_variable"
  done
done

print -r -- 'PASS: native runtime roots, cache identity and active opam precedence'

# ============================================================================ #
# End of tests/runtime/test-runtime-path.zsh
