#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++ NATIVE ASSET CONSUMPTION QUALIFICATION ++++++++++++++++++ #
# ============================================================================ #
# Installs the packaged baseline into disposable roots with native FNM/pyenv.
# Builds CPython from Nix-fetched sources; no store-built prefix is copied and
# no live manager root, default or shell configuration is modified.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset recovery_package="${1:?Provide the recovery package path}"
typeset native_fnm="${2:?Provide a native FNM executable}"
typeset native_pyenv="${3:?Provide a native pyenv executable}"
[[ -x "$native_fnm" && "${native_fnm:A}" != /nix/store/* ]] || return 1
[[ -x "$native_pyenv" && "${native_pyenv:A}" != /nix/store/* ]] || return 1

typeset fixture_root
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/recovery-native-assets.XXXXXX")" || return 1
fixture_root="${fixture_root:A}"
[[ -d "$fixture_root" && "$fixture_root:t" == recovery-native-assets.* ]] || return 1
trap 'command rm -rf -- "$fixture_root"' EXIT
trap 'exit 130' INT TERM HUP

export HOME="$fixture_root/home"
export FNM_DIR="$fixture_root/fnm"
export PYENV_ROOT="$fixture_root/pyenv"
export OPAMROOT="$fixture_root/opam"
export XDG_CACHE_HOME="$fixture_root/cache"
export XDG_STATE_HOME="$fixture_root/state"
export XDG_DATA_HOME="$fixture_root/data"
export XDG_RUNTIME_DIR="$fixture_root/runtime"
export ZDOTDIR="$fixture_root/zdot"
export TMPDIR="$fixture_root/tmp"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1

command mkdir -p "$HOME" "$TMPDIR" "$fixture_root/bin"
command ln -s "$native_fnm" "$fixture_root/bin/fnm"
command ln -s "$native_pyenv" "$fixture_root/bin/pyenv"

export PATH="$fixture_root/bin:$PATH"

print -r -- "Native FNM: $("$native_fnm" --version)"
print -r -- "Native pyenv: $("$native_pyenv" --version)"
"$recovery_package/bin/dev-bootstrap" apply --runtimes-only --only node --json
[[ ! -e "$FNM_DIR/aliases/default" ]] || return 1
print -r -- 'PASS: real FNM consumed Nix archives over the private loopback mirror'

"$recovery_package/bin/dev-bootstrap" apply --runtimes-only --only python --json
[[ ! -e "$PYENV_ROOT/version" && -d "$PYENV_ROOT/shims" ]] || return 1
"$recovery_package/bin/dev-bootstrap" verify --runtimes-only --only node --only python --json
print -r -- 'PASS: native CPython build, required extensions, rehash and absent-default preservation'

# ============================================================================ #
# End of tests/qualification/native-assets.zsh
