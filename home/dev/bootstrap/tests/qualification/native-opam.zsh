#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++ NATIVE OPAM SETUP QUALIFICATION ++++++++++++++++++++++ #
# ============================================================================ #
# Exercises production opam setup with real opam and empty switches. Compiler
# creation and canaries are replaced only in this qualification. This
# establishes argv and preservation contracts, not compiler-build or clean-host
# acceptance.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
typeset fixture_root
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-native-opam.XXXXXX")" || return 1
fixture_root="${fixture_root:A}"
[[ -d "$fixture_root" && "$fixture_root:t" == bootstrap-native-opam.* ]] || return 1
trap 'command rm -rf -- "$fixture_root"' EXIT
trap 'exit 130' INT TERM HUP

typeset interpreter="${DEV_BOOTSTRAP_TEST_PYTHON:-$(whence -p python3)}"
typeset native_opam="${DEV_BOOTSTRAP_TEST_OPAM:-/opt/homebrew/bin/opam}"
typeset manifest="${1:?Provide the packaged baseline manifest}"
[[ -x "$native_opam" && "${native_opam:A}" != /nix/store/* ]] || return 1
export DEV_BOOTSTRAP_TEST_OPAM="$native_opam"
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/cache"
export XDG_STATE_HOME="$fixture_root/state"
export XDG_DATA_HOME="$fixture_root/data"
export XDG_RUNTIME_DIR="$fixture_root/runtime"
export ZDOTDIR="$fixture_root/zdot"
export FNM_DIR="$fixture_root/fnm"
export PYENV_ROOT="$fixture_root/pyenv"
export OPAMROOT="$fixture_root/opam"
export TMPDIR="$fixture_root/tmp"
command mkdir -p "$HOME" "$TMPDIR"

"$interpreter" -B - "$test_root/bootstrap.py" "$manifest" "$fixture_root" <<'PY'
import os, pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
from core import process
from core.engine import Bootstrap
from core.manifest import load_manifest
from core.paths import writable_directory
from core.setup import BootstrapSetup
manifest = load_manifest(pathlib.Path(sys.argv[2]))
# Qualify the explicitly selected executable, never the caller's PATH.
executable = pathlib.Path(os.environ['DEV_BOOTSTRAP_TEST_OPAM'])
recipe = manifest.setdefault('setup', {})
recipe['managerDirectory'] = str(executable.parent)
recipe['managers'] = {**recipe.get('managers', {}), 'ocaml': executable.name}
root = pathlib.Path(sys.argv[3])
original_run = process.run
commands = []
def native_run(args, **kwargs):
    if args[0] == str(executable):
        commands.append(args[1:3])
        if args[1:3] == ['switch', 'create']:
            # Empty switches stand in for compiler builds in this qualification.
            args = [x for x in args if not x.startswith('ocaml-base-compiler.')]
            if '--empty' not in args:
                args.insert(4, '--empty')
    return original_run(args, **kwargs)
process.run = native_run
context = Bootstrap(manifest, ['ocaml'])
opam = context.adapter('ocaml')
writable_directory(context.state)
def row(release):
    return {'language': 'ocaml', 'version': release,
            'path': str(opam.root / f'lcs-ocaml-{release}/bin/ocamlc')}
def repositories(scope):
    return opam.run('repository', 'list', '--short', scope).splitlines()
first, second = manifest['ocaml']['versions'][:2]
opam.install(row(first))
assert commands == [['init', '--bare'], ['switch', 'create']], commands
assert (opam.root / 'opam-init/env_hook.zsh').is_file()
assert not (root / 'home/.zshrc').exists()
assert opam.selection() is None
assert repositories('--set-default') == ['default']
assert repositories(f'--switch=lcs-ocaml-{first}') == ['default']
manifest['defaults']['ocaml'] = first
opam.initialize_default()
assert opam.run('switch', 'show') == f'lcs-ocaml-{first}'
print('PASS: bare root on the default upstream, fresh hooks, switch and default')

# Preserve existing global and project-local selections.
local = root / 'local'
local.mkdir()
(local / 'repo').write_text('opam-version: "2.0"\n')
opam.run('repository', 'add', 'local', local.as_uri(), '--dont-select')
opam.run('switch', 'create', 'existing', '--empty', '--no-switch', '--repositories=local')
opam.run('switch', 'set', 'existing')
project = root / 'project'
opam.run('switch', 'create', str(project), '--empty', '--no-switch', '--repositories=local')
commands.clear()
opam.install(row(second))
assert commands == [['switch', 'create']], commands
assert opam.run('switch', 'show') == 'existing'
assert repositories('--set-default') == ['default']
assert repositories('--switch=existing') == ['local']
assert repositories(f'--switch={project}') == ['local']
assert repositories(f'--switch=lcs-ocaml-{second}') == ['default']
hook_source = pathlib.Path(sys.argv[1]).parents[2] / 'shells/zsh/config/languages/ocaml.zsh'
original_run(['zsh', '-dfi', '-c', """
typeset -ga precmd_functions
source "$1"
[[ ${precmd_functions[(Ie)_zsh_opam_env_hook]} -gt 0 ]] || exit 1
_zsh_opam_env_hook || exit 1
[[ "$OPAM_SWITCH_PREFIX" == "$OPAMROOT/existing" ]] || exit 1
cd "$2" || exit 1
_zsh_opam_env_hook || exit 1
[[ "$OPAM_SWITCH_PREFIX" == "$2/_opam" ]] || exit 1
""", 'native-hook-test', str(hook_source), str(project)],
    env={'OPAMROOT': str(opam.root),
         'PATH': str(executable.parent) + ':' + os.environ['PATH']})
print('PASS: existing global and project selections are preserved')

# Regenerate a missing hook without changing established global/repository state.
before_config = (opam.root / 'config').read_bytes()
(opam.root / 'opam-init/env_hook.zsh').unlink()
BootstrapSetup(context).hooks()
assert (opam.root / 'opam-init/env_hook.zsh').is_file()
after_config = (opam.root / 'config').read_bytes()
if after_config != before_config:
    import difflib
    print(''.join(difflib.unified_diff(
        before_config.decode().splitlines(True),
        after_config.decode().splitlines(True))), flush=True)
assert opam.run('switch', 'show') == 'existing'
assert repositories(f'--switch={project}') == ['local']
print('PASS: native missing-hook repair preserves global/repository selections')

opam.run('update', 'default', timeout=1800)
print('PASS: ordinary upstream update')
PY

print -r -- 'PASS: native opam setup contracts; empty switches only'

# ============================================================================ #
# End of tests/qualification/native-opam.zsh
