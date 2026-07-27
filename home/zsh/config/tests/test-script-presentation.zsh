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

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir script-presentation)" || return 1
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

command mkdir -p "$fixture_root/bin" "$fixture_root/logs"

# Keep the toolchain report deterministic and independent from host compilers.
typeset compiler
for compiler in cc c++ gcc g++ clang clang++; do
  {
    print -r -- '#!/bin/sh'
    print -r -- "printf '%s\\n' 'Test compiler 1.0'"
  } >| "$fixture_root/bin/$compiler"
  command chmod 700 "$fixture_root/bin/$compiler"
done

export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain
typeset original_path="$PATH"
export PATH="$fixture_root/bin:/usr/bin:/bin"
rehash

source "$test_root/scripts/toolchain-information.zsh"
_toolchain_detect_platform() { print -r -- "TestOS"; }
_toolchain_resolve_real_compiler() { print -r -- "$1"; }
_toolchain_compiler_details() {
  print -r -- "Clang|Test vendor|Test compiler 1.0"
}
unset CC CXX
typeset toolchain_output
toolchain_output="$(get_toolchain_info 2>&1)" || return 1
[[ "$toolchain_output" == *"C/C++ toolchain"* &&
   "$toolchain_output" == *"Compilers in PATH"* &&
   ( "$toolchain_output" == *"[OK]"* ||
     "$toolchain_output" == *"[WARN]"* ) ]] || {
  print -u2 "FAIL: toolchain report did not use the shared presentation"
  return 1
}
[[ "$toolchain_output" != *$'\e'* &&
   "$toolchain_output" != *"real_cpath="* ]] || {
  print -u2 "FAIL: toolchain report leaked ANSI or internal assignments"
  return 1
}

# Exercise the lazy blog entry point, shared help/status tables, and logging.
export BLOG_LOG_DIR="$fixture_root/logs"
source "$test_root/scripts/blog-auto-updates.zsh"
blog_help >| "$fixture_root/blog-help" || return 1
typeset blog_help_output="$(<"$fixture_root/blog-help")"
[[ "$blog_help_output" == "BLOG AUTOMATION"* &&
   "$blog_help_output" == *$'\nUSAGE\n'* &&
   "$blog_help_output" == *$'\nCOMMANDS\n'* &&
   "$blog_help_output" == *$'\nENVIRONMENT\n'* &&
   "$blog_help_output" == *$'blog_run_all             Run the complete'* &&
   "$blog_help_output" == *"  ------------------------"* &&
   "$blog_help_output" != *$'\e'* ]] || {
  print -u2 "FAIL: blog help does not match the zfuncs catalog layout"
  return 1
}

ALLOWED_BLOG_ROOT="$fixture_root/missing-blog"
BLOG_CONFIG_FILE="$ALLOWED_BLOG_ROOT/blog_config.conf"
unset BLOG_DIR BLOG_SOURCE_PATH BLOG_IMAGES_PATH BLOG_DEST_PATH
unset BLOG_SCRIPTS_DIR BLOG_IMAGES_SCRIPT BLOG_HASH_GENERATOR
unset BLOG_FRONTMATTER_SCRIPT BLOG_BACKUP_DIR
typeset blog_status_output
blog_status_output="$(blog_status 2>&1)" || return 1
[[ "$blog_status_output" == *"Blog automation status"* &&
   "$blog_status_output" == *"Dependencies"* &&
   "$blog_status_output" == *"Workflow files"* &&
   "$blog_status_output" == *"Missing"* ]] || {
  print -u2 "FAIL: blog status did not use the shared report layout"
  return 1
}

BLOG_LOG_FILE=""
blog_success "presentation test" 2>| "$fixture_root/blog-stderr"
typeset blog_terminal_output="$(<"$fixture_root/blog-stderr")"
[[ "$blog_terminal_output" == *"[OK]"*"presentation test"* ]] || {
  print -u2 "FAIL: blog logging did not use the shared log renderer"
  return 1
}
command grep -Fq "[INFO] presentation test" "$BLOG_LOG_FILE" || {
  print -u2 "FAIL: shared blog presentation changed the persistent log format"
  return 1
}

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

# The VS Code shell layer should format its environment and final health state.
export PATH="$original_path"
rehash
source "$test_root/scripts/vscode/sync/commands.zsh"
_vscode_sync_check_platform() { return 0; }
_vscode_sync_extensions_require_python() { return 0; }
_vscode_sync_check_vscode_running() { return 0; }
_vscode_sync_run_python_command() {
  print -rl -- "Extension state: healthy" "ISSUES=0" "WARNINGS=0"
}
_VSCODE_SYNC_BACKUP_DIR="$fixture_root/backups"
typeset vscode_output
vscode_output="$(vscode_sync_check)" || return 1
[[ "$vscode_output" == *"VS Code Sync Health Check"* &&
   "$vscode_output" == *"Environment"* &&
   "$vscode_output" == *"VS Code processes"* &&
   "$vscode_output" == *"[OK]"*"Health: HEALTHY"* ]] || {
  print -u2 "FAIL: VS Code health check did not use shared presentation"
  return 1
}

print -r -- "PASS: scripts use shared, plain, side-effect-free presentation"

# ============================================================================ #
# End of tests/test-script-presentation.zsh
