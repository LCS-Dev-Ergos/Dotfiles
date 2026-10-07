#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++++++ GO RUNTIME TEST ++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies that a working Go compiler remains healthy when GOPATH does not
# exist. The isolated devdoctor probe must preserve its JSON contract without
# creating manager workspace state.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir go-runtime)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

# Configure an isolated fixture environment with a non-existent GOPATH.
export HOME="$fixture_root/home"
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
export XDG_CACHE_HOME="$fixture_root/cache"
export GOPATH="$fixture_root/missing-workspace"
export ZSH_CONFIG_DIR="$test_root"
export DEVDOCTOR_REGISTRY="$test_root/../packages/runtime-managers.tsv"
export PATH="$fixture_root/bin:/usr/bin:/bin"
export ZSH_UI_STYLE=plain

command mkdir -p "$fixture_root/bin" "$HOME"

# Mock a working Go compiler that reports a valid version string without workspace.
print -rl -- '#!/bin/sh' 'echo "go version go1.27.1 linux/amd64"' > "$fixture_root/bin/go"
command chmod 700 "$fixture_root/bin/go"

source "$test_root/scripts/dev-doctor.zsh"

# Ensure the Go health probe succeeds and emits valid JSON when GOPATH is missing.
typeset result="$(devdoctor --only go --json)"
[[ "$result" == *'"id":"go","label":"Go","state":"ok"'* ]] || {
  print -u2 "FAIL: working Go with absent GOPATH: $result"
  return 1
}

# The probe must remain strictly read-only and avoid creating the workspace path.
[[ ! -e "$GOPATH" ]] || {
  print -u2 'FAIL: probe created GOPATH'
  return 1
}

print -r -- 'PASS: Go runtime health is independent of GOPATH'

# ============================================================================ #
# End of tests/languages/test-go-runtime.zsh
