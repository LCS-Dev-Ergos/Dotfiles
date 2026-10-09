#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ DEVELOPMENT RECOVERY TESTS ++++++++++++++++++++++++ #
# ============================================================================ #
# Exercises the standalone recovery interface with isolated roots and native
# manager fixtures. Planning is read-only; apply preserves defaults and extra
# runtimes, refuses conflicts and rejects unqualified NixOS versions.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
typeset helpers="${DEV_BOOTSTRAP_TEST_HELPERS:-\
$test_root/../../shells/zsh/config/tests/helpers.zsh}"
source "$helpers" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir dev-bootstrap)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

typeset recovery="${DEV_BOOTSTRAP_TEST_SOURCE:-$test_root/bootstrap.py}"
typeset interpreter="${DEV_BOOTSTRAP_TEST_PYTHON:-$(whence -p python3)}"
typeset baseline_manifest="${DEV_BOOTSTRAP_TEST_MANIFEST:-${1:?Provide a manifest}}"
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/cache"
export XDG_CONFIG_HOME="$fixture_root/config"
export XDG_DATA_HOME="$fixture_root/data"
export XDG_STATE_HOME="$fixture_root/state"
export XDG_RUNTIME_DIR="$fixture_root/runtime"
export ZDOTDIR="$fixture_root/zdot"
export PYENV_ROOT="$HOME/.pyenv"
export FNM_DIR="$fixture_root/fnm"
export OPAMROOT="$fixture_root/opam"
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
unset OPAMSWITCH PYENV_VERSION FNM_MULTISHELL_PATH NODE_OPTIONS
command mkdir -p "$HOME" "$fixture_root/bin" "$fixture_root/tmp"
typeset fixture_shell="$(whence -p sh)"
export PATH="$fixture_root/bin:$PATH"

# Keep repeated CLI calls readable while retaining literal, explicit arguments.
_bootstrap_fixture() {
  "$interpreter" "$recovery" \
    --manifest "$fixture_root/baseline.json" "$@"
}

"$interpreter" - "$fixture_root" "$baseline_manifest" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = {
    "schema": 1,
    "platform": "aarch64-darwin",
    "backend": "native",
    "defaults": {"node": "24.21.0", "python": "3.14.7", "ocaml": "5.5.1"},
    "policy": json.loads(pathlib.Path(sys.argv[2]).read_text())["policy"],
    "node": {"versions": ["24.21.0"]},
    "python": {"version": "3.14.7"},
    "ocaml": {"versions": ["5.5.1"]},
}
(root / "baseline.json").write_text(json.dumps(manifest))
manifest["backend"] = "nixpkgs"
(root / "nixos.json").write_text(json.dumps(manifest))
PY

typeset output
output="$(PATH=/nonexistent _bootstrap_fixture plan --only node --json)"
[[ "$output" == *'"state": "blocked"'* &&
   ! -e "$FNM_DIR" && ! -e "$XDG_STATE_HOME" ]] || {
  print -u2 'FAIL: missing-manager plan must be blocked and read-only'
  return 1
}

# FNM downloads from the named upstream into a staging root and tags its first
# release as default there; the real root must retain its own selection.
command cat > "$fixture_root/bin/fnm" <<EOF
#!$fixture_shell
if [ "\$1" = --version ]; then echo "fnm 1.39.0"; exit; fi
test "\$1" = --fnm-dir || exit 9
root=\$2
test "\$3 \$4" = "--node-dist-mirror https://nodejs.org/dist" || exit 10
test "\$5 \$6" = "install 24.21.0" || exit 11
test -z "\${FNM_NODE_DIST_MIRROR:-}\${FNM_ARCH:-}" || exit 12
prefix="\$root/node-versions/v24.21.0/installation"
mkdir -p "\$prefix/bin" "\$root/aliases"
test ! -e "\$HOME/fail-node-download" || exit 13
printf '#!%s\\necho v24.21.0\\n' "$fixture_shell" > "\$prefix/bin/node"
chmod 700 "\$prefix/bin/node"
ln -s "\$prefix" "\$root/aliases/default"
EOF
command chmod 700 "$fixture_root/bin/fnm"
command cp "$fixture_root/bin/fnm" "$fixture_root/fnm-fixture"
command mkdir -p "$FNM_DIR/node-versions/v99.0.0/installation" \
  "$FNM_DIR/aliases"
command ln -s ../node-versions/v99.0.0/installation "$FNM_DIR/aliases/default"

_bootstrap_fixture apply --only node > /dev/null
[[ -x "$FNM_DIR/node-versions/v24.21.0/installation/bin/node" &&
   "$(readlink "$FNM_DIR/aliases/default")" ==
     ../node-versions/v99.0.0/installation &&
   -d "$FNM_DIR/node-versions/v99.0.0" ]] || {
  print -u2 'FAIL: apply must preserve existing default and extra versions'
  return 1
}
command rm "$fixture_root/bin/fnm"
_bootstrap_fixture apply --only node > /dev/null
_bootstrap_fixture verify --only node > /dev/null
command cp "$fixture_root/fnm-fixture" "$fixture_root/bin/fnm"
# Inherited mirror and architecture settings must not reach FNM.
FNM_NODE_DIST_MIRROR=http://127.0.0.1:9/dist FNM_ARCH=x64 \
  FNM_DIR="$fixture_root/fresh-fnm" \
  _bootstrap_fixture apply --only node > /dev/null
[[ ! -e "$fixture_root/fresh-fnm/aliases/default" ]] || {
  print -u2 'FAIL: a fresh FNM root acquired an implicit default'
  return 1
}

# A damaged installation is a conflict, never an invitation to overwrite it.
typeset node_executable="$FNM_DIR/node-versions/v24.21.0/installation/bin/node"
print -rl -- "#!$fixture_shell" 'echo v0.0.0' > "$node_executable"
if _bootstrap_fixture apply --only node > /dev/null 2>&1; then
  print -u2 'FAIL: apply accepted a conflicting runtime'
  return 1
fi
[[ "$("$node_executable")" == v0.0.0 ]] || {
  print -u2 'FAIL: conflicting Node installation was overwritten'
  return 1
}

if "$interpreter" "$recovery" --manifest "$fixture_root/nixos.json" \
  apply --only node > /dev/null 2>&1; then
  print -u2 'FAIL: NixOS recovery accepted an unqualified downloaded runtime'
  return 1
fi

# A failed download leaves neither a release nor its staging root behind.
command touch "$HOME/fail-node-download"
if FNM_DIR="$fixture_root/new-fnm" \
  _bootstrap_fixture apply --only node > /dev/null 2>&1; then
  print -u2 'FAIL: apply reported a failed download as success'
  return 1
fi
command rm "$HOME/fail-node-download"
[[ ! -e "$fixture_root/new-fnm/node-versions/v24.21.0" &&
   -z "$(print -l -- "$fixture_root"/new-fnm/.dev-bootstrap-*(N))" ]] || {
  print -u2 'FAIL: failed Node download left partial state in the root'
  return 1
}
command mkdir -p "$fixture_root/repository/.git"
if FNM_DIR="$fixture_root/repository/generated" \
  _bootstrap_fixture plan --only node > /dev/null 2>&1; then
  print -u2 'FAIL: runtime root inside a Git checkout was accepted'
  return 1
fi

# Python builds through the native pyenv, never with inherited prefix, install
# or checksum overrides, and only for a release its python-build knows.
command cat > "$fixture_root/bin/pyenv" <<EOF
#!$fixture_shell
case "\$1 \${2:-}" in
  'rehash '*) mkdir -p "\$PYENV_ROOT/shims"; exit ;;
  'install --list')
    echo 'Available versions:'
    test -e "\$HOME/no-python-definition" || echo '  3.14.7'
    exit ;;
  'install 3.14.7') ;;
  *) exit 8 ;;
esac
test -z "\${PYTHON_PREFIX_PATH:-}\${MAKE_INSTALL_OPTS:-}" || exit 9
test -z "\${MAKEFLAGS:-}\${MAKEOVERRIDES:-}\${MAKEOPTS:-}\${MAKE:-}" || exit 9
test -z "\${PYTHON_BUILD_BUILD_PATH:-}\${PYENV_VERSION:-}" || exit 9
test -z "\${HAS_CHECKSUM_SUPPORT_compute_sha2:-}" || exit 9
prefix="\$PYENV_ROOT/versions/3.14.7"
mkdir -p "\$prefix/bin"
test ! -e "\$HOME/abort-python-build" || exit 42
cat > "\$prefix/bin/python" <<'PYTHON'
#!$fixture_shell
case "\$*" in
  *platform.python_version*) echo 3.14.7 ;;
  *) exit "\${FIXTURE_PYTHON_FAIL:-0}" ;;
esac
PYTHON
chmod 700 "\$prefix/bin/python"
EOF
command chmod 700 "$fixture_root/bin/pyenv"
command mkdir -p "$PYENV_ROOT/versions/other"
print -r -- 'other' > "$PYENV_ROOT/version"
# The upstream SHA verifier must not fail open when utilities are missing.
print -rl -- "#!$fixture_shell" 'echo wrong-checksum' \
  > "$fixture_root/bin/shasum"
command chmod 700 "$fixture_root/bin/shasum"
if PATH="$fixture_root/bin" PYENV_ROOT="$fixture_root/checksum-python" \
  _bootstrap_fixture apply --only python > /dev/null 2>&1; then
  print -u2 'FAIL: Python proceeded without a working checksum verifier'
  return 1
fi
[[ ! -e "$fixture_root/checksum-python" ]] || {
  print -u2 'FAIL: checksum failure created a Python root'
  return 1
}
command rm "$fixture_root/bin/shasum"
command touch "$HOME/no-python-definition"
if output="$(PYENV_ROOT="$fixture_root/undefined-python" \
  _bootstrap_fixture apply --only python 2>&1 >/dev/null)"; then
  print -u2 'FAIL: Python proceeded without a native build definition'
  return 1
fi
command rm "$HOME/no-python-definition"
[[ "$output" == *'upgrade pyenv'* && ! -e "$fixture_root/undefined-python" ]] || {
  print -u2 'FAIL: a missing definition must stop before any Python root'
  return 1
}
PYTHON_PREFIX_PATH="$PYENV_ROOT/versions/other" MAKE_INSTALL_OPTS='unsafe' \
  MAKEFLAGS="prefix=$fixture_root/unrelated" MAKEOVERRIDES='prefix=unsafe' \
  MAKEOPTS='unsafe' MAKE='unsafe' PYENV_VERSION=other \
  PYTHON_BUILD_BUILD_PATH="$fixture_root/unrelated" \
  HAS_CHECKSUM_SUPPORT_compute_sha2=0 \
  _bootstrap_fixture apply --only python > /dev/null
[[ "$(cat "$PYENV_ROOT/version")" == other && -d "$PYENV_ROOT/shims" &&
   ! -e "$fixture_root/unrelated" &&
   ! -e "$PYENV_ROOT/versions/other/bin" ]] || {
  print -u2 'FAIL: Python recovery changed defaults or an unrelated prefix'
  return 1
}
command touch "$HOME/abort-python-build"
if PYENV_ROOT="$fixture_root/interrupted-python" \
  _bootstrap_fixture apply --only python > /dev/null 2>&1; then
  print -u2 'FAIL: interrupted Python build reported success'
  return 1
fi
command rm "$HOME/abort-python-build"
[[ -d "$fixture_root/interrupted-python/versions/3.14.7/bin" ]] || {
  print -u2 'FAIL: interrupted prefix was unexpectedly removed'
  return 1
}
# The failed build is journaled as ours: the next apply replaces it.
output="$(PYENV_ROOT="$fixture_root/interrupted-python" \
  _bootstrap_fixture plan --only python --json)"
[[ "$output" == *'"interrupted": true'* ]] || {
  print -u2 'FAIL: interrupted prefix was not reported for replacement'
  return 1
}
PYENV_ROOT="$fixture_root/interrupted-python" \
  _bootstrap_fixture apply --only python > /dev/null
[[ -x "$fixture_root/interrupted-python/versions/3.14.7/bin/python" ]] || {
  print -u2 'FAIL: retry did not replace the interrupted Python prefix'
  return 1
}
# An incomplete prefix bootstrap did not start stays for inspection.
command mkdir -p "$fixture_root/foreign-python/versions/3.14.7/bin"
output="$(PYENV_ROOT="$fixture_root/foreign-python" \
  _bootstrap_fixture plan --only python --json)"
[[ "$output" == *'"state": "conflict"'* ]] || {
  print -u2 'FAIL: a foreign incomplete prefix was not reported as a conflict'
  return 1
}
if PYENV_ROOT="$fixture_root/foreign-python" \
  _bootstrap_fixture apply --only python > /dev/null 2>&1; then
  print -u2 'FAIL: apply overwrote a foreign incomplete Python prefix'
  return 1
fi
[[ -d "$fixture_root/foreign-python/versions/3.14.7/bin" &&
   ! -e "$fixture_root/foreign-python/versions/3.14.7/bin/python" ]] || {
  print -u2 'FAIL: a foreign incomplete Python prefix was changed'
  return 1
}
_bootstrap_fixture apply --only python > /dev/null
command mkdir -p "$PYENV_ROOT/.git" "$PYENV_ROOT/bin"
print -rl -- '[remote "origin"]' 'url = https://github.com/pyenv/pyenv.git' \
  > "$PYENV_ROOT/.git/config"
command cp "$fixture_root/bin/pyenv" "$PYENV_ROOT/bin/pyenv"
_bootstrap_fixture plan --only python > /dev/null
if FIXTURE_PYTHON_FAIL=7 \
  _bootstrap_fixture verify --only python > /dev/null 2>&1; then
  print -u2 'FAIL: Python extension failure was accepted'
  return 1
fi

# Native argv fixtures: a bare root on opam's own upstream, then one switch.
# The bootstrap never registers, selects or lists repositories itself.
"$interpreter" - "$fixture_root/bin/opam" "$interpreter" "$fixture_shell" <<'PY'
import pathlib
import sys

script = r"""import json
import pathlib
import sys

args = sys.argv[1:]
root = pathlib.Path(args[args.index("--root") + 1])
record = root / "fixture-calls.json"
calls = json.loads(record.read_text()) if record.exists() else []
calls.append(args[:2])
assert not any(
    arg.startswith(("--repositories", "lcs-baseline-", "file:")) for arg in args
)
if args[0] == "init":
    assert all(
        flag in args
        for flag in (
            "--bare",
            "--no-setup",
            "--no-opamrc",
            "--enable-shell-hook",
            "--shell=zsh",
        )
    )
    root.mkdir(parents=True, exist_ok=True)
    (root / "config").touch()
elif args[:2] == ["switch", "remove"]:
    import shutil

    shutil.rmtree(root / args[2])
elif args[:2] == ["switch", "create"]:
    assert all(
        flag in args
        for flag in ("--no-switch", "--no-depexts", "--require-checksums")
    )
    assert "ocaml-base-compiler.5.5.1" in args
    target = root / args[2] / "bin"
    target.mkdir(parents=True)
    # Source builds start from an allowlisted environment; mark the root.
    if (root / "fail-create").exists():
        record.write_text(json.dumps(calls))
        sys.exit(31)
    (target / "ocamlc").write_text(
        "#!" + FIXTURE_SHELL + '\ncase "$1" in\n'
        "-version) echo 5.5.1;;\n"
        '-o) printf "recovery-ok\\n" > "$2";;\n'
        "*) exit 7;;\nesac\n"
    )
    (target / "ocamlrun").write_text(
        "#!" + FIXTURE_SHELL + '\ncat "$1"\n'
    )
    for path in target.iterdir():
        path.chmod(0o700)
else:
    raise AssertionError(args)
record.write_text(json.dumps(calls))
"""
pathlib.Path(sys.argv[1]).write_text(
    "#!" + sys.argv[2] + "\nFIXTURE_SHELL = " + repr(sys.argv[3]) + "\n" + script
)
PY
command chmod 700 "$fixture_root/bin/opam"

_opam_calls() {
  "$interpreter" -c 'import json, sys; print(json.load(open(sys.argv[1])))' \
    "$1/fixture-calls.json"
}

# An existing root keeps its global selection and other switches.
command mkdir -p "$OPAMROOT/extra"
print -r -- 'switch: "extra"' > "$OPAMROOT/config"
_bootstrap_fixture apply --only ocaml > /dev/null
_bootstrap_fixture apply --only ocaml > /dev/null
[[ "$(cat "$OPAMROOT/config")" == 'switch: "extra"' &&
   -d "$OPAMROOT/extra" &&
   "$(_opam_calls "$OPAMROOT")" == "[['switch', 'create']]" ]] || {
  print -u2 'FAIL: opam bootstrap changed existing selections or repeated work'
  return 1
}

# A fresh root is initialized bare, without an implicit global selection.
OPAMROOT="$fixture_root/fresh-opam" _bootstrap_fixture apply --only ocaml \
  > /dev/null
[[ -f "$fixture_root/fresh-opam/config" &&
   ! -s "$fixture_root/fresh-opam/config" &&
   "$(_opam_calls "$fixture_root/fresh-opam")" ==
     "[['init', '--bare'], ['switch', 'create']]" ]] || {
  print -u2 'FAIL: fresh opam root was not initialized bare'
  return 1
}

# A failed switch creation of ours is removed through opam and created again.
command mkdir -p "$fixture_root/broken-opam"
command touch "$fixture_root/broken-opam/fail-create"
if OPAMROOT="$fixture_root/broken-opam" \
  _bootstrap_fixture apply --only ocaml > /dev/null 2>&1; then
  print -u2 'FAIL: failed switch creation was reported as success'
  return 1
fi
command rm -f "$fixture_root/broken-opam/fail-create"
if OPAMROOT="$fixture_root/broken-opam" \
  _bootstrap_fixture verify --only ocaml > /dev/null 2>&1; then
  print -u2 'FAIL: verify accepted an incomplete opam switch'
  return 1
fi
OPAMROOT="$fixture_root/broken-opam" \
  _bootstrap_fixture apply --only ocaml > /dev/null
[[ -x "$fixture_root/broken-opam/lcs-ocaml-5.5.1/bin/ocamlc" &&
   "$(_opam_calls "$fixture_root/broken-opam")" ==
     "[['init', '--bare'], ['switch', 'create'], ['switch', 'remove'], ['switch', 'create']]" ]] || {
  print -u2 'FAIL: interrupted opam switch was not replaced through opam'
  return 1
}

# Lock contention must fail before any selected runtime root is created.
"$interpreter" - "$interpreter" "$recovery" "$fixture_root" <<'PY'
import fcntl
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[3])
with (root / "state/dev-bootstrap/apply.lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    env = dict(os.environ, PYENV_ROOT=str(root / "lock-python"))
    result = subprocess.run(
        [
            sys.argv[1],
            sys.argv[2],
            "--manifest",
            str(root / "baseline.json"),
            "apply",
            "--only",
            "python",
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    assert (
        result.returncode == 2 and "Another recovery process" in result.stderr
    )
    assert not (root / "lock-python").exists()
PY

print -r -- 'PASS: restoration, upstream, preservation and failure contracts'

# ============================================================================ #
# End of tests/bootstrap/test-recovery.zsh
