#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ BOOTSTRAP CLI ALIASES TEST ++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies executable identity and one legacy-name plan in isolated empty roots.
# Runtime behavior and stage errors belong to the runtime/setup suites.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
typeset helpers="${DEV_BOOTSTRAP_TEST_HELPERS:-\
$test_root/../../shells/zsh/config/tests/helpers.zsh}"
source "$helpers" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir bootstrap-aliases)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

typeset bootstrap_package="${1:?Provide the built bootstrap package}"
typeset fixture_utilities="${DEV_BOOTSTRAP_TEST_UTILITIES:-/usr/bin:/bin}"
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/cache"
export XDG_CONFIG_HOME="$fixture_root/config"
export XDG_DATA_HOME="$fixture_root/data"
export XDG_STATE_HOME="$fixture_root/state"
export XDG_RUNTIME_DIR="$fixture_root/runtime"
export ZDOTDIR="$fixture_root/zdot"
export FNM_DIR="$fixture_root/fnm"
export PYENV_ROOT="$fixture_root/pyenv"
export OPAMROOT="$fixture_root/opam"
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
export PATH="$fixture_utilities"
unset OPAMSWITCH PYENV_VERSION FNM_MULTISHELL_PATH
command mkdir -p "$HOME"

[[ "$bootstrap_package/bin/devrestore" -ef
   "$bootstrap_package/bin/dev-bootstrap" ]] || {
  print -u2 'FAIL: compatibility CLI does not reach the same executable'
  return 1
}

# Executable identity proves dispatch equivalence. Exercise the compatibility
# entry once; repeating every command under both names adds no distinct risk.
"$bootstrap_package/bin/devrestore" plan --runtimes-only --json \
  > "$fixture_root/plan.json"
[[ -s "$fixture_root/plan.json" ]] || return 1

[[ ! -e "$FNM_DIR" && ! -e "$PYENV_ROOT" && ! -e "$OPAMROOT" &&
   ! -e "$XDG_STATE_HOME" ]] || {
  print -u2 'FAIL: blocked CLI operation created manager or state directories'
  return 1
}

print -r -- 'PASS: CLI alias identity and packaged plan smoke'

# ============================================================================ #
# End of tests/bootstrap/test-cli-aliases.zsh
