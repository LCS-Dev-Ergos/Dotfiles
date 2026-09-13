#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ TOOLCHAIN SELECTION TEST +++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies preferred-installation precedence, absolute CC/CXX selection,
# concise status output, in-place PATH edits, and restoration to the baseline.
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
_make_compiler "$llvm_fixture_bin/clang" "Nix LLVM fake"
_make_compiler "$llvm_fixture_bin/clang++" "Nix LLVM++ fake"
_make_compiler "$gcc_fixture_bin/gcc-99" "GNU GCC fake"
_make_compiler "$gcc_fixture_bin/g++-99" "GNU G++ fake"

export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain
export PATH="$system_bin:/usr/bin:/bin"
unset CC CXX CPATH LDFLAGS CPPFLAGS PKG_CONFIG_PATH ORIGINAL_PATH
source "$test_root/runtime-helpers.zsh"
source "$test_root/scripts/toolchain-selection.zsh"
typeset original_gcc_selector="${functions[_toolchain_select_gcc_bin_dir]}"

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
typeset path_before_failure="$PATH"
if use_llvm >| "$fixture_root/failed-llvm-output" 2>/dev/null; then
  print -u2 "FAIL: use_llvm accepted a failed resolution validation"
  return 1
fi
functions[_toolchain_validate_resolution]="$original_validator"
[[ "$TOOLCHAIN_ACTIVE" == gnu &&
   "$PATH" == "$path_before_failure" &&
   "$CC" == "$gcc_fixture_bin/gcc-99" && "$CXX" == "$gcc_fixture_bin/g++-99" ]] || {
  print -u2 "FAIL: failed activation did not restore the prior toolchain"
  return 1
}

use_system >/dev/null || {
  print -u2 "FAIL: use_system could not restore the original environment"
  return 1
}
[[ "$TOOLCHAIN_ACTIVE" == system &&
   "$PATH" == "$system_bin:/usr/bin:/bin" ]] || {
  print -u2 "FAIL: use_system did not restore PATH or active state"
  return 1
}
[[ -z "${CC-}" && -z "${CXX-}" ]] || {
  print -u2 "FAIL: use_system did not restore unset CC/CXX variables"
  return 1
}

# A directory added to PATH after the switcher loaded must survive every
# switch, and nothing about the environment may leak into child shells.
typeset late_bin="$fixture_root/late/bin"
command mkdir -p "$late_bin"
export PATH="$late_bin:$PATH"
use_llvm >/dev/null || return 1
[[ ":$PATH:" == *":$late_bin:"* ]] || {
  print -u2 "FAIL: use_llvm dropped a PATH entry added after loading"
  return 1
}
use_system >/dev/null || return 1
[[ "$PATH" == "$late_bin:$system_bin:/usr/bin:/bin" ]] || {
  print -u2 "FAIL: use_system did not return to the current PATH: $PATH"
  return 1
}
[[ -z "${parameters[ORIGINAL_PATH]-}" &&
   "${parameters[TOOLCHAIN_ACTIVE]-}" != *export* &&
   "${parameters[TOOLCHAIN_BASELINE_CC]-}" != *export* ]] || {
  print -u2 "FAIL: the switcher exported state that child shells would inherit"
  return 1
}

# A directory already on PATH is not moved: moving it to the front would let
# unrelated tools inside it shadow the ones ahead of it.
export PATH="$system_bin:$llvm_fixture_bin:/usr/bin:/bin"
use_llvm >/dev/null || return 1
[[ "$PATH" == "$system_bin:$llvm_fixture_bin:/usr/bin:/bin" &&
   "$CC" == "$llvm_fixture_bin/clang" ]] || {
  print -u2 "FAIL: use_llvm reordered PATH instead of setting an absolute CC"
  return 1
}
use_system >/dev/null || return 1
export PATH="$system_bin:/usr/bin:/bin"

# GCC's own utilities end in a release number too; gcc-ar-120 is not gcc 120.
_make_compiler "$gcc_fixture_bin/gcc-ar-120" "GNU archiver fake"
[[ "$(_toolchain_find_best_binary gcc "$gcc_fixture_bin")" == "$gcc_fixture_bin/gcc-99" ]] || {
  print -u2 "FAIL: a gcc-<tool>-<number> utility was mistaken for a compiler"
  return 1
}

# On macOS the first real GNU gcc on PATH wins over Homebrew's keg; Apple's
# Clang answering to the gcc name does not count.
functions[_toolchain_select_gcc_bin_dir]="$original_gcc_selector"
typeset gnu_path_bin="$fixture_root/nix-profile/bin"
command mkdir -p "$gnu_path_bin"
_make_compiler "$system_bin/gcc" "Apple clang version fake"
_make_compiler "$gnu_path_bin/gcc" "gcc (GCC) fake Copyright Free Software Foundation"
_toolchain_get_homebrew_prefix() { print -r -- "$fixture_root/homebrew"; }
command mkdir -p "$fixture_root/homebrew/opt/gcc/bin"
# Only fixture directories: a Linux runner's /usr/bin/gcc is GNU as well.
export PATH="$system_bin:$gnu_path_bin"
[[ "$(_toolchain_select_gcc_bin_dir)" == "$gnu_path_bin" ]] || {
  print -u2 "FAIL: macOS GCC selection did not prefer the GNU gcc on PATH"
  return 1
}
export PATH="$system_bin"
[[ "$(_toolchain_select_gcc_bin_dir)" == "$fixture_root/homebrew/opt/gcc/bin" ]] || {
  print -u2 "FAIL: macOS GCC selection did not fall back to Homebrew's keg"
  return 1
}

export PATH="$system_bin:/usr/bin:/bin"
unfunction _make_compiler 2>/dev/null

print -r -- "PASS: preferred toolchains, concise output, and restoration"

# ============================================================================ #
# End of tests/test-toolchain-selection.zsh
