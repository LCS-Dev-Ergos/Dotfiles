#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ TOOLCHAIN SELECTION TEST +++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies preferred-installation precedence, exact CC/CXX resolution,
# concise status output, and restoration of the original shell environment.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir toolchain)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

typeset system_bin="$fixture_root/system/bin"
typeset llvm_fixture_bin="$fixture_root/llvm/bin"
typeset gcc_fixture_bin="$fixture_root/gcc/bin"
command mkdir -p "$system_bin" "$llvm_fixture_bin" "$gcc_fixture_bin"

_make_compiler() {
  local output_path="$1" version="$2"
  {
    print -r -- '#!/bin/sh'
    print -r -- "printf '%s\\n' '$version'"
  } >| "$output_path"
  command chmod 700 "$output_path"
}

_make_compiler "$system_bin/clang" "Apple clang fake"
_make_compiler "$system_bin/clang++" "Apple clang++ fake"
_make_compiler "$system_bin/cc" "System C fake"
_make_compiler "$system_bin/c++" "System C++ fake"
_make_compiler "$llvm_fixture_bin/clang" "Homebrew LLVM fake"
_make_compiler "$llvm_fixture_bin/clang++" "Homebrew LLVM++ fake"
_make_compiler "$gcc_fixture_bin/gcc-99" "GNU GCC fake"
_make_compiler "$gcc_fixture_bin/g++-99" "GNU G++ fake"

export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain
export PATH="$system_bin:/usr/bin:/bin"
unset CC CXX CPATH LDFLAGS CPPFLAGS PKG_CONFIG_PATH
source "$test_root/runtime-helpers.zsh"
source "$test_root/scripts/toolchain-selection.zsh"

[[ "$(_toolchain_find_best_binary cc)" == "$system_bin/cc" ]] || {
  print -u2 "FAIL: PATH-only compiler discovery does not split Zsh path"
  return 1
}

TOOLCHAIN_OS="macOS"
_toolchain_select_llvm_bin_dir() { print -r -- "$llvm_fixture_bin"; }
_toolchain_select_gcc_bin_dir() { print -r -- "$gcc_fixture_bin"; }

typeset llvm_output_file="$fixture_root/llvm-output"
use_llvm >| "$llvm_output_file" || {
  print -u2 "FAIL: use_llvm rejected a valid preferred LLVM toolchain"
  return 1
}
typeset llvm_output="$(<"$llvm_output_file")"
[[ "$TOOLCHAIN_ACTIVE" == llvm ]] || {
  print -u2 "FAIL: use_llvm did not record the active toolchain"
  return 1
}
[[ "$(command -v "$CC")" == "$llvm_fixture_bin/clang" &&
   "$(command -v "$CXX")" == "$llvm_fixture_bin/clang++" ]] || {
  print -u2 "FAIL: use_llvm did not prioritize the selected LLVM directory"
  return 1
}
[[ "$llvm_output" != *'PATH='* && "$llvm_output" != *"$fixture_root"* ]] || {
  print -u2 "FAIL: use_llvm exposed verbose filesystem paths"
  return 1
}

typeset gnu_output_file="$fixture_root/gnu-output"
use_gnu >| "$gnu_output_file" || {
  print -u2 "FAIL: use_gnu rejected a valid preferred GNU toolchain"
  return 1
}
typeset gnu_output="$(<"$gnu_output_file")"
[[ "$TOOLCHAIN_ACTIVE" == gnu ]] || {
  print -u2 "FAIL: use_gnu did not record the active toolchain"
  return 1
}
[[ "$(command -v "$CC")" == "$gcc_fixture_bin/gcc-99" &&
   "$(command -v "$CXX")" == "$gcc_fixture_bin/g++-99" ]] || {
  print -u2 "FAIL: use_gnu did not select the highest versioned compilers"
  return 1
}
[[ "$gnu_output" != *'PATH='* && "$gnu_output" != *"$fixture_root"* ]] || {
  print -u2 "FAIL: use_gnu exposed verbose filesystem paths"
  return 1
}

typeset original_validator="${functions[_toolchain_validate_resolution]}"
_toolchain_validate_resolution() { return 1; }
if use_llvm >| "$fixture_root/failed-llvm-output" 2>/dev/null; then
  print -u2 "FAIL: use_llvm accepted a failed resolution validation"
  return 1
fi
functions[_toolchain_validate_resolution]="$original_validator"
[[ "$TOOLCHAIN_ACTIVE" == gnu &&
   "$PATH" == "$gcc_fixture_bin:$TOOLCHAIN_ORIGINAL_PATH" &&
   "$CC" == gcc-99 && "$CXX" == g++-99 ]] || {
  print -u2 "FAIL: failed activation did not restore the prior toolchain"
  return 1
}

use_system >/dev/null || {
  print -u2 "FAIL: use_system could not restore the original environment"
  return 1
}
[[ "$TOOLCHAIN_ACTIVE" == system &&
   "$PATH" == "$TOOLCHAIN_ORIGINAL_PATH" ]] || {
  print -u2 "FAIL: use_system did not restore PATH or active state"
  return 1
}
[[ -z "${CC-}" && -z "${CXX-}" ]] || {
  print -u2 "FAIL: use_system did not restore unset CC/CXX variables"
  return 1
}

unfunction _make_compiler 2>/dev/null
print -r -- "PASS: preferred toolchains, concise output, and restoration"

# ============================================================================ #
# End of tests/test-toolchain-selection.zsh
