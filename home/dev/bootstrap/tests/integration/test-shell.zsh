#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ BOOTSTRAP SHELL ADAPTERS TEST ++++++++++++++++++++++ #
# ============================================================================ #
# Uses production adapters with native-manager mocks. Runtime selection must
# work in a fresh startup context without changing defaults or local manifests.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
typeset helpers="${DEV_BOOTSTRAP_TEST_HELPERS:-\
$test_root/../../shells/zsh/config/tests/helpers.zsh}"
source "$helpers" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir bootstrap-shell)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

typeset shell_config="${DEV_BOOTSTRAP_SHELL_CONFIG:-\
$test_root/../../shells/zsh/config}"
typeset fixture_shell="$(whence -p sh)"
typeset fixture_zsh="${DEV_BOOTSTRAP_TEST_ZSH:-$(whence -p zsh)}"
typeset fixture_python="${DEVRESTORE_PYTHON:-$(whence -p python3)}"
typeset fixture_utilities="${DEV_BOOTSTRAP_TEST_UTILITIES:-/usr/bin:/bin}"
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/cache"
export XDG_DATA_HOME="$fixture_root/data"
export XDG_STATE_HOME="$fixture_root/state"
export XDG_RUNTIME_DIR="$fixture_root/runtime"
export FNM_DIR="$fixture_root/fnm"
export PYENV_ROOT="$fixture_root/pyenv"
export OPAMROOT="$fixture_root/opam"
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
export USER=bootstrap-tests
export ZSH_CONFIG_DIR="$shell_config"
export LCS_RUNTIME_MANAGER_BACKEND=native
export LCS_NATIVE_FNM_READY=1
export DEV_BOOTSTRAP_ONLY='node python ocaml'
export DEV_BOOTSTRAP_NATIVE_FNM="$fixture_root/bin/fnm"
export DEV_BOOTSTRAP_NATIVE_PYENV="$fixture_root/bin/pyenv"
export DEV_BOOTSTRAP_NATIVE_OPAM="$fixture_root/bin/opam"
export PATH="$fixture_root/bin:$fixture_utilities"
export BOOTSTRAP_DEFAULT_MARKER="$fixture_root/default-mutated"
unset OPAMSWITCH OPAM_SWITCH_PREFIX PYENV_VERSION FNM_MULTISHELL_PATH

command mkdir -p "$HOME" "$fixture_root/bin" "$XDG_RUNTIME_DIR" \
  "$FNM_DIR/aliases" "$FNM_DIR/node-versions/v26.10.0/installation/bin" \
  "$PYENV_ROOT/shims" "$PYENV_ROOT/versions/global/bin" \
  "$OPAMROOT/opam-init" "$OPAMROOT/selected/bin"
command ln -s "$FNM_DIR/node-versions/v26.10.0/installation" \
  "$FNM_DIR/aliases/default"
print -r -- global > "$PYENV_ROOT/version"
print -r -- 'switch: "selected"' > "$OPAMROOT/config"

# FNM emits a disposable multishell; any attempt to set a default is a failure.
print -r -- "#!$fixture_shell" > "$fixture_root/bin/fnm"
cat >> "$fixture_root/bin/fnm" <<'MOCK'
case "$1" in
  env)
    links="$XDG_RUNTIME_DIR/fnm_multishells"
    mkdir -p "$links"
    link="$links/$$_1"
    ln -s "$FNM_DIR/aliases/default" "$link"
    printf 'export FNM_MULTISHELL_PATH="%s"\n' "$link"
    printf 'export PATH="%s/bin:$PATH"\n' "$link"
    ;;
  default) touch "$BOOTSTRAP_DEFAULT_MARKER"; exit 7 ;;
esac
MOCK
command chmod 700 "$fixture_root/bin/fnm"
command ln -s "$fixture_root/bin/fnm" "$FNM_DIR/fnm"
print -rl -- "#!$fixture_shell" 'exit 7' > "$fixture_root/bin/pyenv"
command chmod 700 "$fixture_root/bin/pyenv"

# Runtime mocks emit identities and the effective Python interpreter path.
print -rl -- "#!$fixture_shell" 'echo v26.10.0' \
  > "$FNM_DIR/node-versions/v26.10.0/installation/bin/node"
print -rl -- "#!$fixture_shell" \
  'case "$*" in *sys.executable*)' \
  '  echo "$PYENV_ROOT/versions/global/bin/python" ;;' \
  '  *) echo "Python 3.14.7" ;; esac' \
  > "$PYENV_ROOT/versions/global/bin/python"
print -rl -- "#!$fixture_shell" 'echo 5.5.1' \
  > "$OPAMROOT/selected/bin/ocamlc"
command chmod 700 "$FNM_DIR/node-versions/v26.10.0/installation/bin/node" \
  "$PYENV_ROOT/versions/global/bin/python" "$OPAMROOT/selected/bin/ocamlc"
command ln -s "$PYENV_ROOT/versions/global/bin/python" \
  "$PYENV_ROOT/shims/python"

# The opam hook runs readonly env; no selected/global switch operation is valid.
print -rl -- "#!$fixture_shell" \
  'test "$1" = env || exit 7' \
  'case " $* " in *" --readonly "*) ;; *) exit 8 ;; esac' \
  'echo "export OPAM_SWITCH_PREFIX=\"$OPAMROOT/selected\""' \
  'echo "export PATH=\"$OPAMROOT/selected/bin:\$PATH\""' \
  > "$fixture_root/bin/opam"
command chmod 700 "$fixture_root/bin/opam"
# Production PATH places manager-checkout bins before host profiles. Expose
# the same fixture command there so no native host opam can replace this mock.
command mkdir -p "$PYENV_ROOT/bin"
command ln -s "$fixture_root/bin/opam" "$PYENV_ROOT/bin/opam"
print -rl -- 'if [[ -o interactive ]]; then' \
  '  _opam_env_hook() { :; }' \
  '  precmd_functions+=(_opam_env_hook)' \
  'fi' > "$OPAMROOT/opam-init/init.zsh"

cd "$HOME"
# The checkout directory keeps fixture commands ahead of the real host profile.
# Exercise both a link to the host mock and an independent checkout executable.
typeset manager_route
for manager_route in linked checkout; do
  if [[ "$manager_route" == checkout ]]; then
    command rm "$PYENV_ROOT/bin/pyenv"
    command cp "$fixture_root/bin/pyenv" "$PYENV_ROOT/bin/pyenv"
  else
    command ln -s "$fixture_root/bin/pyenv" "$PYENV_ROOT/bin/pyenv"
  fi
  export DEV_BOOTSTRAP_NATIVE_PYENV="$("$fixture_python" -B - "$test_root" "$fixture_root/bin" <<'PYTHON'
import sys
sys.path.insert(0, sys.argv[1])
from engine import Bootstrap
manifest = {"setup": {"managerDirectory": sys.argv[2], "managers": {"python": "pyenv"}}}
print(Bootstrap(manifest, ["python"]).manager("python").resolve())
PYTHON
)"
  typeset output=""
  output="$("$fixture_zsh" -fi "$test_root/probe-shell.zsh")" || {
    print -u2 'FAIL: fresh adapter qualification failed'
    return 1
  }
  [[ "$output" == *$'node\t'* && "$output" == *$'python\t'* &&
     "$output" == *$'ocaml\t'* && ! -e "$BOOTSTRAP_DEFAULT_MARKER" &&
     "$(cat "$PYENV_ROOT/version")" == global &&
     "$(cat "$OPAMROOT/config")" == 'switch: "selected"' ]] || {
    print -u2 "FAIL: adapter selection or preservation: ${(qqq)output}"
    return 1
  }

  # Resolve multishell/shim symlinks before comparing the selected fixture prefix.
  typeset bootstrap_row="" expected_runtime=""
  typeset -a fields
  for bootstrap_row in "${(@f)output}"; do
    fields=( "${(@ps:\t:)bootstrap_row}" )
    case "$fields[1]" in
      node) expected_runtime="$FNM_DIR/aliases/default/bin/node" ;;
      python) expected_runtime="$PYENV_ROOT/versions/global/bin/python" ;;
      ocaml) expected_runtime="$OPAMROOT/selected/bin/ocamlc" ;;
      *)
        print -u2 'FAIL: unexpected shell probe output'
        return 1
        ;;
    esac
    [[ "${fields[2]:A}" == "${expected_runtime:A}" ]] || {
      print -u2 "FAIL: $fields[1] selected an unexpected runtime"
      return 1
    }
  done

done

# A different PATH-selected manager must fail even with a usable compiler.
if DEV_BOOTSTRAP_NATIVE_OPAM="$fixture_root/unexpected-opam" \
  "$fixture_zsh" -fi "$test_root/probe-shell.zsh" > /dev/null 2>&1; then
  print -u2 'FAIL: shell accepted an unexpected opam manager'
  return 1
fi

print -r -- 'PASS: fresh adapters select native runtimes and preserve defaults'

# ============================================================================ #
# End of tests/integration/test-shell.zsh
