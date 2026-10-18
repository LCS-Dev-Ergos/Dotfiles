#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ SCRIPT PRESENTATION TEST +++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies that user-facing scripts delegate presentation to the shared UI
# helpers while preserving plain, capturable output and avoiding real external
# operations.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir script-presentation)" || return 1
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

command mkdir -p "$fixture_root/bin"

export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain
typeset original_path="$PATH"
export PATH="$fixture_root/bin:/usr/bin:/bin"
rehash

# Help remains machine-capturable; validation failures use the shared log.
typeset shdoc_help
shdoc_help="$(
  command env ZSH_UI_STYLE=plain \
    zsh "$test_root/scripts/install-shdoc.zsh" --help
)" || return 1
[[ "$shdoc_help" == "Usage:"* && "$shdoc_help" != *$'\e'* ]] || {
  print -u2 "FAIL: install-shdoc help is not plain and capturable"
  return 1
}
if command env ZSH_UI_STYLE=plain \
  zsh "$test_root/scripts/install-shdoc.zsh" \
  --prefix "$fixture_root/shdoc" --check \
  >| "$fixture_root/shdoc-check" 2>&1; then
  print -u2 "FAIL: install-shdoc accepted a missing pinned source"
  return 1
fi
command grep -Fq "[ERROR]" "$fixture_root/shdoc-check" || {
  print -u2 "FAIL: install-shdoc validation did not use shared logging"
  return 1
}

# The Zsh OCI entry point uses shared errors; its Bash backend stays isolated.
source "$test_root/scripts/oci-retry.zsh"
ZSH_CONFIG_DIR="$fixture_root/missing-config"
if oci-retry >| "$fixture_root/oci-output" 2>&1; then
  print -u2 "FAIL: OCI wrapper accepted a missing backend"
  return 1
fi
command grep -Fq "[ERROR]" "$fixture_root/oci-output" || {
  print -u2 "FAIL: OCI wrapper did not use shared logging"
  return 1
}
ZSH_CONFIG_DIR="$test_root"

# UTM help follows the same plain, capturable layout as zfuncs.
typeset utm_help
utm_help="$(
  command env \
    PATH="$fixture_root/bin:/usr/bin:/bin" \
    ZSH_CONFIG_DIR="$test_root" \
    ZSH_UI_STYLE=plain \
    zsh "$test_root/scripts/utm-ubuntu.zsh" --help
)" || return 1
[[ "$utm_help" == "UTM UBUNTU"* &&
   "$utm_help" == *$'\nOPTIONS\n'* &&
   "$utm_help" == *$'\nENVIRONMENT\n'* &&
   "$utm_help" == *$'--no-login  Mount the shared directory'* &&
   "$utm_help" == *"  ------------------------"* &&
   "$utm_help" != *$'\e'* ]] || {
  print -u2 "FAIL: UTM help does not match the zfuncs catalog layout"
  return 1
}

# Mock UTM and SSH so the happy path is exercised without touching a real VM.
{
  print -r -- '#!/bin/sh'
  print -r -- 'exit 0'
} >| "$fixture_root/bin/utmctl"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ "${1:-}" = "-G" ]; then'
  print -r -- "  printf '%s\\n' 'hostname 192.0.2.10' 'port 22' 'user tester'"
  print -r -- '  exit 0'
  print -r -- 'fi'
  print -r -- 'case " $* " in'
  print -r -- '  *" bash -s "*) cat >/dev/null; printf "%s\n" "Mount completed on the VM."; exit 0 ;;'
  print -r -- '  *" exit "*) exit 0 ;;'
  print -r -- 'esac'
  print -r -- 'exit 0'
} >| "$fixture_root/bin/ssh"
command chmod 700 "$fixture_root/bin/utmctl" "$fixture_root/bin/ssh"
rehash

command env \
  PATH="$fixture_root/bin:/usr/bin:/bin" \
  ZSH_CONFIG_DIR="$test_root" \
  ZSH_UI_STYLE=plain \
  UTMCTL_CMD=utmctl \
  zsh "$test_root/scripts/utm-ubuntu.zsh" --no-login \
  >| "$fixture_root/utm-output" 2>&1 || {
  print -u2 "FAIL: mocked UTM workflow did not complete"
  return 1
}
typeset utm_output="$(<"$fixture_root/utm-output")"
[[ "$utm_output" == *"UTM Ubuntu"* &&
   "$utm_output" == *"Shared directory"* &&
   "$utm_output" == *"[OK]"*"Operation completed."* &&
   "$utm_output" != *$'\e'* ]] || {
  print -u2 "FAIL: UTM workflow did not use the shared presentation"
  return 1
}

export PATH="$original_path"
rehash

print -r -- "PASS: scripts use shared, plain, side-effect-free presentation"

# ============================================================================ #
# End of tests/tools/test-script-presentation.zsh
