#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ ZSH VERIFICATION RUNNER ++++++++++++++++++++++++++ #
# ============================================================================ #
# Runs the repository's dependency, shell, documentation, catalog, and Python
# checks from one stable entry point. Quick mode covers the Zsh contract; full
# mode adds Python suites and an isolated fast-start smoke test.
# ============================================================================ #

emulate -L zsh
setopt localoptions no_aliases pipefail extendedglob
umask 077
zmodload -i zsh/datetime 2>/dev/null || true

typeset verify_mode="quick"
case "${1:-}" in
  ""|--quick)
    ;;
  --full)
    verify_mode="full"
    ;;
  -h|--help)
    print -r -- "Usage: tests/run-all.zsh [--quick|--full]"
    print -r -- ""
    print -r -- "  --quick  Check shell syntax, shdoc, catalog, and Zsh tests."
    print -r -- "  --full   Also run Python suites and a fast-start smoke test."
    exit 0
    ;;
  *)
    print -u2 "run-all: unknown option: $1"
    print -u2 "Usage: tests/run-all.zsh [--quick|--full]"
    exit 2
    ;;
esac
(( $# <= 1 )) || {
  print -u2 "Usage: tests/run-all.zsh [--quick|--full]"
  exit 2
}

typeset verify_config_dir="${0:A:h:h}"
typeset verify_zsh_root="${verify_config_dir:h}"
typeset verify_helpers="$verify_config_dir/scripts/_shared-helpers.zsh"
typeset verify_dependencies="$verify_config_dir/scripts/check-zsh-dependencies.zsh"
typeset verify_tmp_root=""
typeset verify_test_helpers="$verify_config_dir/tests/helpers.zsh"

[[ -r "$verify_helpers" ]] || {
  print -u2 "run-all: shared helpers not found: $verify_helpers"
  exit 1
}
source "$verify_helpers" || exit 1
source "$verify_test_helpers" || exit 1

typeset ZSH_UI_STYLE="${ZSH_UI_STYLE:-auto}"
typeset -gi verify_passed=0
typeset -gi verify_failed=0

verify_tmp_root="$(_zsh_test_temp_dir run-all)" || exit 1
export TMPDIR="$verify_tmp_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap '
  command rm -rf -- "$verify_tmp_root"
' EXIT
trap 'exit 130' INT TERM HUP

# -----------------------------------------------------------------------------
# _verify_dependencies
# @internal
# @description Checks required commands and generated dependency manifests.
# @noargs
# -----------------------------------------------------------------------------
_verify_dependencies() {
  [[ -x "$verify_dependencies" ]] || {
    print -u2 "Dependency checker not executable: $verify_dependencies"
    return 1
  }
  ZSH_UI_STYLE=plain "$verify_dependencies" \
    --required --check-manifests --quiet
}

# -----------------------------------------------------------------------------
# _verify_step
# @internal
# @description Runs one named verification step and records its result.
# @arg $1 string Human-readable step label.
# @arg $@ command Command or function and arguments to execute.
# -----------------------------------------------------------------------------
_verify_step() {
  emulate -L zsh
  local label="$1"
  shift
  local start="${EPOCHREALTIME:-0}"
  local elapsed=""

  _zsh_ui_section "$label"
  if "$@"; then
    if [[ "$start" != 0 ]]; then
      elapsed=$(( EPOCHREALTIME - start ))
      printf -v elapsed '%.2fs' "$elapsed"
    fi
    _zsh_ui_log ok "Passed${elapsed:+ in $elapsed}."
    (( verify_passed++ ))
    return 0
  fi

  _zsh_ui_log error "Failed."
  (( verify_failed++ ))
  return 0
}

# -----------------------------------------------------------------------------
# _verify_shell_syntax
# @internal
# @description Runs zsh -n on every maintained shell source file.
# @noargs
# -----------------------------------------------------------------------------
_verify_shell_syntax() {
  emulate -L zsh
  setopt extendedglob
  local -a files
  local file
  files=(
    "$verify_config_dir"/**/*.zsh(N.)
    "$verify_config_dir"/**/*.sh(N.)
    "$verify_config_dir"/completions/_*(N.)
    "$verify_config_dir"/others/*.zshrc(N.)
    "$verify_zsh_root"/zshrc(N.)
    "$verify_zsh_root"/zshenv-bootstrap(N.)
    "$verify_config_dir"/.zshenv(N.)
  )
  (( ${#files[@]} )) || return 1

  for file in "${(ou)files[@]}"; do
    command zsh -n -- "$file" || {
      print -u2 "Syntax check failed: $file"
      return 1
    }
  done
  print -r -- "Checked ${#files[@]} shell files."
}

# -----------------------------------------------------------------------------
# _verify_shdoc
# @internal
# @description Validates that shdoc can parse every catalog source file.
# @noargs
# -----------------------------------------------------------------------------
_verify_shdoc() {
  emulate -L zsh
  (( $+commands[shdoc] )) || {
    print -u2 "shdoc is required for documentation validation."
    return 1
  }

  local -a files
  local file
  files=(
    "$verify_config_dir"/functions/*.zsh(N.)
    "$verify_config_dir"/lib/*.zsh(N.)
    "$verify_config_dir"/scripts/**/*.sh(N.)
    "$verify_config_dir"/scripts/**/*.zsh(N.)
  )
  for file in "${(ou)files[@]}"; do
    command shdoc "$file" >/dev/null || {
      print -u2 "shdoc validation failed: $file"
      return 1
    }
  done
  print -r -- "Validated ${#files[@]} documentation sources."
}

# -----------------------------------------------------------------------------
# _verify_catalog
# @internal
# @description Rebuilds and validates the public function catalog in isolation.
# @noargs
# -----------------------------------------------------------------------------
_verify_catalog() {
  command env \
    ZSH_CONFIG_DIR="$verify_config_dir" \
    XDG_CACHE_HOME="$verify_tmp_root/cache" \
    ZFUNCS_STYLE=plain \
    zsh -fc \
    'source "$ZSH_CONFIG_DIR/runtime-helpers.zsh"
     source "$ZSH_CONFIG_DIR/functions/zfuncs.zsh"
     zfuncs --refresh >/dev/null && zfuncs --check'
}

# -----------------------------------------------------------------------------
# _verify_zsh_tests
# @internal
# @description Runs every test-*.zsh regression script.
# @noargs
# -----------------------------------------------------------------------------
_verify_zsh_tests() {
  emulate -L zsh
  local -a tests=("$verify_config_dir"/tests/test-*.zsh(N.))
  local test_file
  (( ${#tests[@]} )) || return 1
  for test_file in "${(o)tests[@]}"; do
    command zsh "$test_file" || return 1
  done
}

# -----------------------------------------------------------------------------
# _verify_python_tests
# @internal
# @description Runs every maintained Python unittest suite.
# @noargs
# -----------------------------------------------------------------------------
_verify_python_tests() {
  emulate -L zsh
  (( $+commands[python3] )) || {
    print -u2 "python3 is required for the full verification suite."
    return 1
  }

  local -a suites=(
    "$verify_config_dir/scripts/security/python/tests"
    "$verify_config_dir/scripts/python/tests"
    "$verify_config_dir/scripts/vscode/python/tests"
  )
  local suite
  for suite in "${suites[@]}"; do
    command env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
      -s "$suite" -p 'test_*.py' -q || return 1
  done
}

# -----------------------------------------------------------------------------
# _verify_fast_start
# @internal
# @description Sources the fast-start profile in an isolated interactive Zsh.
# @noargs
# -----------------------------------------------------------------------------
_verify_fast_start() {
  command env \
    ZSH_FAST_START=1 \
    ZSH_CONFIG_DIR="$verify_config_dir" \
    ZDOTDIR="$verify_config_dir" \
    DOTFILES_ZSH_ROOT="$verify_zsh_root" \
    zsh -dfi -c \
    'source "$DOTFILES_ZSH_ROOT/zshrc" || exit 1
     SAVEHIST=0
     HISTFILE="$TMPDIR/history"
     type h >/dev/null
     type zsh_rebuild_path >/dev/null
     if [[ -x /run/current-system/sw/bin/darwin-rebuild ]]; then
       type darwin-rebuild >/dev/null
     fi'
}

_zsh_ui_heading \
  "Zsh verification" \
  "${(U)verify_mode} suite · read-only repository checks"
print -r -- ""

_verify_step "Dependency contract" _verify_dependencies
_verify_step "Shell syntax" _verify_shell_syntax
_verify_step "Shdoc metadata" _verify_shdoc
_verify_step "Function catalog" _verify_catalog
_verify_step "Zsh regressions" _verify_zsh_tests

if [[ "$verify_mode" == full ]]; then
  _verify_step "Python regressions" _verify_python_tests
  _verify_step "Fast-start smoke test" _verify_fast_start
fi

print -r -- ""
_zsh_ui_rule "="
if (( verify_failed == 0 )); then
  _zsh_ui_log ok "$verify_passed verification step(s) passed."
  exit 0
fi
_zsh_ui_log error \
  "$verify_failed step(s) failed; $verify_passed passed."
exit 1

# ============================================================================ #
# End of tests/run-all.zsh
