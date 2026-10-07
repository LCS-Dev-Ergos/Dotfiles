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

typeset recovery="${DEVRESTORE_SOURCE:-$test_root/bootstrap.py}"
typeset interpreter="${DEVRESTORE_PYTHON:-$(whence -p python3)}"
typeset baseline_manifest="${DEVRESTORE_MANIFEST:-${1:?Provide a manifest}}"
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/cache"
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

"$interpreter" - "$fixture_root" "$fixture_shell" "$recovery" \
  "$baseline_manifest" <<'PY'
import hashlib
import io
import json
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
node = ("#!" + sys.argv[2] + "\necho v24.21.0\n").encode()
archive = root / "node.tar.gz"
with tarfile.open(archive, "w:gz") as tar:
    info = tarfile.TarInfo("node-v24.21.0-darwin-arm64/bin/node")
    info.mode, info.size = 0o755, len(node)
    tar.addfile(info, io.BytesIO(node))
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
python_cache = root / "python-cache"
python_cache.mkdir()
(python_cache / "source.tar.gz").write_bytes(b"locked source")
python_digest = hashlib.sha256(b"locked source").hexdigest()
cache = root / "cache/devrestore/artifacts"
cache.mkdir(parents=True)
(cache / digest).write_bytes(archive.read_bytes())
manifest = {
    "schema": 1,
    "platform": "aarch64-darwin",
    "backend": "native",
    "defaults": {"node": "24.21.0", "python": "3.14.7", "ocaml": "5.5.1"},
    "policy": json.loads(pathlib.Path(sys.argv[4]).read_text())["policy"],
    "node": [
        {
            "version": "24.21.0",
            "hashes": {"aarch64-darwin": digest},
            "archive": str(archive),
            "filename": "node-v24.21.0-darwin-arm64.tar.gz",
        }
    ],
    "python": {
        "version": "3.14.7",
        "pythonBuildVersion": "2.8.8",
        "builder": str(root / "locked-python-build"),
        "definition": str(root / "definitions/3.14.7"),
        "sourceCache": str(python_cache),
        "sources": [{"name": "source.tar.gz", "sha256": python_digest}],
    },
    "ocaml": {
        "versions": ["5.5.1"],
        "repository": "https://github.com/ocaml/opam-repository.git",
        "revision": "197f8eb389658dab6a200a42e38ad37f3ae5e2c9",
        "source": str(root / "opam-source"),
    },
}
(root / "definitions").mkdir()
(root / "definitions/3.14.7").touch()
(root / "opam-source").mkdir()
(root / "opam-source/repo").write_text('opam-version: "2.0"\n')
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

# FNM changes its staging default; the real root must retain its own.
print -rl -- "#!$fixture_shell" \
  'if [ "$1" = --version ]; then echo "fnm 1.39.0"; exit; fi' \
  'test "$1" = --fnm-dir || exit 9' \
  'root=$2; prefix="$root/node-versions/v24.21.0/installation"' \
  'mkdir -p "$prefix" "$root/aliases"' \
  'tar -xzf "$FIXTURE_ARCHIVE" --strip-components=1 -C "$prefix"' \
  'ln -s "$root/node-versions/v24.21.0/installation" "$root/aliases/default"' \
  > "$fixture_root/bin/fnm"
command chmod 700 "$fixture_root/bin/fnm"
command cp "$fixture_root/bin/fnm" "$fixture_root/fnm-fixture"
export FIXTURE_ARCHIVE="$fixture_root/node.tar.gz"
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

# Missing runtimes must not bypass archive integrity checks or touch a Git tree.
command cp "$fixture_root/fnm-fixture" "$fixture_root/bin/fnm"
"$interpreter" - "$fixture_root/node.tar.gz" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(b"corrupt archive")
PY
if FNM_DIR="$fixture_root/new-fnm" \
  _bootstrap_fixture apply --only node > /dev/null 2>&1; then
  print -u2 'FAIL: apply accepted a damaged archive'
  return 1
fi
[[ ! -e "$fixture_root/new-fnm" ]] || {
  print -u2 'FAIL: damaged Node archive created a runtime root'
  return 1
}
command mkdir -p "$fixture_root/repository/.git"
if FNM_DIR="$fixture_root/repository/generated" \
  _bootstrap_fixture plan --only node > /dev/null 2>&1; then
  print -u2 'FAIL: runtime root inside a Git checkout was accepted'
  return 1
fi

# Python uses the locked build definition, never inherited prefix/install flags.
print -rl -- "#!$fixture_shell" \
  'test "$1" = rehash || exit 8' \
  'mkdir -p "$PYENV_ROOT/shims"' > "$fixture_root/bin/pyenv"
print -rl -- "#!$fixture_shell" \
  'if [ "$1" = --version ]; then echo "python-build 2.8.8"; exit; fi' \
  'test -z "${PYTHON_PREFIX_PATH:-}${MAKE_INSTALL_OPTS:-}" || exit 9' \
  'test -z "${MAKEFLAGS:-}${MAKEOVERRIDES:-}${MAKEOPTS:-}${MAKE:-}" || exit 9' \
  'test -z "${PYTHON_BUILD_BUILD_PATH:-}" || exit 9' \
  'test -z "${HAS_CHECKSUM_SUPPORT_compute_sha2:-}" || exit 9' \
  'test "${1##*/}" = 3.14.7 || exit 10' \
  'mkdir -p "$2/bin"' \
  'test ! -e "$HOME/abort-python-build" || exit 42' \
  "printf '#!%s\\n' '$fixture_shell' > \"\$2/bin/python\"" \
  'printf '\''case "$*" in\n'\'' >> "$2/bin/python"' \
  'printf '\''*platform.python_version*) echo 3.14.7;;\n'\'' \
    >> "$2/bin/python"' \
  'printf '\''*) exit "${FIXTURE_PYTHON_FAIL:-0}";;\nesac\n'\'' \
    >> "$2/bin/python"' \
  'chmod 700 "$2/bin/python"' > "$fixture_root/locked-python-build"
command chmod 700 "$fixture_root/bin/pyenv" "$fixture_root/locked-python-build"
# An independently updated native builder must never be consulted by bootstrap.
print -rl -- "#!$fixture_shell" \
  'touch "$HOME/native-builder-called"; echo "python-build 99.0.0"; exit 9' \
  > "$fixture_root/bin/python-build"
command chmod 700 "$fixture_root/bin/python-build"
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
PYTHON_PREFIX_PATH="$PYENV_ROOT/versions/other" MAKE_INSTALL_OPTS='unsafe' \
  MAKEFLAGS="prefix=$fixture_root/unrelated" MAKEOVERRIDES='prefix=unsafe' \
  MAKEOPTS='unsafe' MAKE='unsafe' \
  PYTHON_BUILD_BUILD_PATH="$fixture_root/unrelated" \
  HAS_CHECKSUM_SUPPORT_compute_sha2=0 \
  _bootstrap_fixture apply --only python > /dev/null
[[ "$(cat "$PYENV_ROOT/version")" == other && -d "$PYENV_ROOT/shims" &&
   ! -e "$fixture_root/unrelated" &&
   ! -e "$PYENV_ROOT/versions/other/bin" ]] || {
  print -u2 'FAIL: Python recovery changed defaults or an unrelated prefix'
  return 1
}
[[ ! -e "$HOME/native-builder-called" ]] || {
  print -u2 'FAIL: native Python builder was executed'
  return 1
}
print -r -- 'corrupt' > "$fixture_root/python-cache/source.tar.gz"
if PYENV_ROOT="$fixture_root/corrupt-python" \
  _bootstrap_fixture apply --only python > /dev/null 2>&1; then
  print -u2 'FAIL: Python accepted a damaged source cache'
  return 1
fi
[[ ! -e "$fixture_root/corrupt-python" ]] || {
  print -u2 'FAIL: damaged source cache created a Python root'
  return 1
}
print -rn -- 'locked source' > "$fixture_root/python-cache/source.tar.gz"
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
output="$(PYENV_ROOT="$fixture_root/interrupted-python" \
  _bootstrap_fixture plan --only python --json)"
[[ "$output" == *'"state": "conflict"'* ]] || {
  print -u2 'FAIL: interrupted prefix was not reported as a conflict'
  return 1
}
if PYENV_ROOT="$fixture_root/interrupted-python" \
  _bootstrap_fixture apply --only python > /dev/null 2>&1; then
  print -u2 'FAIL: retry overwrote an incomplete Python prefix'
  return 1
fi
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

# Native argv fixtures reject the previously invalid common-option prefix.
"$interpreter" - "$fixture_root/bin/opam" "$interpreter" "$fixture_shell" <<'PY'
import pathlib
import sys

script = r"""import json
import os
import pathlib
import sys

args = sys.argv[1:]
assert args[0] in ("init", "switch", "repository"), args
root = pathlib.Path(args[args.index("--root") + 1])
record = root / "fixture-repos.json"
data = (
    json.loads(record.read_text())
    if record.exists()
    else {"default": ["legacy"], "switches": {}, "urls": {}}
)
if args[0] == "init":
    name = next(arg for arg in args if arg.startswith("lcs-baseline-"))
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
    data["default"] = [name]
    data["urls"][name] = args[args.index(name) + 1]
elif args[:2] == ["switch", "create"]:
    assert all(
        flag in args
        for flag in ("--no-switch", "--no-depexts", "--require-checksums")
    )
    target = root / args[2] / "bin"
    target.mkdir(parents=True)
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
    name = next(
        arg.split("=", 1)[1]
        for arg in args
        if arg.startswith("--repositories=")
    )
    data["switches"][args[2]] = [name]
elif args[:2] == ["repository", "add"]:
    assert "--dont-select" in args
    assert data["urls"].get(args[2], args[3]) == args[3]
    if args[2] == "lcs-upstream" and os.environ.get("FIXTURE_OPAM_OFFLINE"):
        sys.exit(40)
    data["urls"][args[2]] = args[3]
elif args[:2] == ["repository", "set-repos"]:
    scope = next((x for x in args if x.startswith("--on-switches=")), None)
    if scope:
        data["switches"][scope.split("=", 1)[1]] = [args[2]]
    else:
        assert "--set-default" in args
        data["default"] = [args[2]]
elif args[:2] == ["repository", "list"]:
    if "--all" in args:
        for repo, url in data["urls"].items():
            refs = (["<default>"] if repo in data["default"] else []) + [
                switch
                for switch, repos in data["switches"].items()
                if repo in repos
            ]
            print(" ".join([repo, url, *refs]))
    elif "--set-default" in args:
        print("\n".join(data["default"]))
    else:
        scope = next(x for x in args if x.startswith("--switch="))
        print("\n".join(data["switches"][scope.split("=", 1)[1]]))
elif args[:2] == ["repository", "remove"]:
    assert "--all-switches" in args
    del data["urls"][args[2]]
else:
    raise AssertionError(args)
record.write_text(json.dumps(data))
"""
pathlib.Path(sys.argv[1]).write_text(
    "#!" + sys.argv[2] + "\nFIXTURE_SHELL = " + repr(sys.argv[3]) + "\n" + script
)
PY
command chmod 700 "$fixture_root/bin/opam"
command mkdir -p "$OPAMROOT/extra"
print -r -- 'switch: "extra"' > "$OPAMROOT/config"
_bootstrap_fixture apply --only ocaml > /dev/null
[[ "$(cat "$OPAMROOT/config")" == 'switch: "extra"' &&
   -d "$OPAMROOT/extra" ]] || {
  print -u2 'FAIL: opam recovery changed global or additional switches'
  return 1
}
_bootstrap_fixture apply --only ocaml > /dev/null
if OPAMROOT="$fixture_root/fresh-opam" FIXTURE_OPAM_OFFLINE=1 \
  _bootstrap_fixture apply --only ocaml > /dev/null 2>&1; then
  print -u2 'FAIL: unavailable upstream must leave a pending handover'
  return 1
fi
[[ -f "$fixture_root/fresh-opam/config" &&
   ! -s "$fixture_root/fresh-opam/config" ]] || {
  print -u2 'FAIL: fresh opam acquired an implicit global selection'
  return 1
}
if OPAMROOT="$fixture_root/fresh-opam" \
  _bootstrap_fixture verify --only ocaml > /dev/null 2>&1; then
  print -u2 'FAIL: verification accepted an unfinished repository handover'
  return 1
fi
command cp "$fixture_root/fresh-opam/fixture-repos.json" \
  "$fixture_root/pending-repos.json"
"$interpreter" - "$fixture_root/fresh-opam/fixture-repos.json" <<'PY'
import json
import pathlib
import sys

file = pathlib.Path(sys.argv[1])
data = json.loads(file.read_text())
for name in data["urls"]:
    if name.startswith("lcs-baseline-"):
        data["urls"][name] = "https://example.invalid/changed"
file.write_text(json.dumps(data))
PY
if OPAMROOT="$fixture_root/fresh-opam" \
  _bootstrap_fixture apply --only ocaml > /dev/null 2>&1; then
  print -u2 'FAIL: pending handover overwrote a changed repository registration'
  return 1
fi
[[ "$(cat "$fixture_root/fresh-opam/fixture-repos.json")" ==
   *https://example.invalid/changed* ]] || {
  print -u2 'FAIL: pending handover changed an unexpected repository'
  return 1
}
command cp "$fixture_root/pending-repos.json" \
  "$fixture_root/fresh-opam/fixture-repos.json"
OPAMROOT="$fixture_root/fresh-opam" \
  _bootstrap_fixture apply --only ocaml > /dev/null
"$interpreter" - "$fixture_root" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name in ("opam", "fresh-opam"):
    data = json.loads((root / name / "fixture-repos.json").read_text())
    assert data["switches"]["lcs-ocaml-5.5.1"] == ["lcs-upstream"]
    assert data["default"] == (
        ["legacy"] if name == "opam" else ["lcs-upstream"]
    )
    assert all(not repo.startswith("lcs-baseline-") for repo in data["default"])
    assert all(
        not repo.startswith("lcs-baseline-")
        for repos in data["switches"].values()
        for repo in repos
    )
assert not list((root / "state/devrestore").glob("opam-*.json"))
PY

# Lock contention must fail before any selected runtime root is created.
"$interpreter" - "$interpreter" "$recovery" "$fixture_root" <<'PY'
import fcntl
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[3])
with (root / "state/devrestore/apply.lock").open("a") as lock:
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

print -r -- 'PASS: restoration, integrity, preservation and failure contracts'

# ============================================================================ #
# End of tests/bootstrap/test-recovery.zsh
