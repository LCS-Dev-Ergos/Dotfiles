#!/usr/bin/env zsh
# shellcheck shell=zsh

# -----------------------------------------------------------------------------
# _zsh_test_temp_dir
# @internal
# @description Creates a private test root outside the deployed configuration.
# @arg $1 string Short fixture label used only in the generated directory name.
# @stdout Absolute fixture directory.
# -----------------------------------------------------------------------------
_zsh_test_temp_dir() {
  emulate -L zsh
  setopt localoptions no_aliases extendedglob

  local label="${1:-fixture}"
  local parent="${ZSH_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
  parent="${parent%/}"
  [[ -n "$parent" ]] || parent="/"
  [[ "$label" == [A-Za-z0-9_-]## ]] || return 2
  [[ -d "$parent" && -w "$parent" ]] || return 1

  local fixture_root
  fixture_root="$(mktemp -d "$parent/lcs-zsh-${label}.XXXXXX")" || return 1
  command chmod 700 "$fixture_root" 2>/dev/null || {
    command rm -rf -- "$fixture_root"
    return 1
  }
  command mkdir -m 700 "$fixture_root/tmp" || {
    command rm -rf -- "$fixture_root"
    return 1
  }
  print -r -- "$fixture_root"
}
