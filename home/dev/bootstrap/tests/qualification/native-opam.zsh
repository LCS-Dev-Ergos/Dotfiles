#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++ NATIVE OPAM SETUP QUALIFICATION ++++++++++++++++++++++ #
# ============================================================================ #
# Exercises production setup and retry logic with real opam and empty switches.
# Compiler creation and canaries are replaced only in this qualification. This
# establishes setup contracts, not compiler-build or clean-host acceptance.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
typeset fixture_root
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/recovery-native-opam.XXXXXX")" || return 1
fixture_root="${fixture_root:A}"
[[ -d "$fixture_root" && "$fixture_root:t" == recovery-native-opam.* ]] || return 1
trap 'command rm -rf -- "$fixture_root"' EXIT
trap 'exit 130' INT TERM HUP

typeset interpreter="${DEVRESTORE_PYTHON:-$(whence -p python3)}"
typeset native_opam="${DEVRESTORE_NATIVE_OPAM:-/opt/homebrew/bin/opam}"
typeset manifest="${1:?Provide the packaged baseline manifest}"
typeset repository="${2:?Provide the immutable opam repository path}"
[[ -x "$native_opam" && "${native_opam:A}" != /nix/store/* ]] || return 1
export DEVRESTORE_NATIVE_OPAM="$native_opam"
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

"$interpreter" -B - "$test_root/bootstrap.py" "$manifest" "$fixture_root" "$repository" <<'PY'
import os, pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
import engine as module
import ocaml
import support
from manifest import load_manifest
manifest = load_manifest(pathlib.Path(sys.argv[2]))
# Qualify the explicitly selected executable with both setup-aware and legacy
# manifests. Production resolution no longer depends on the caller's PATH.
if manifest.get('setup'):
    executable = pathlib.Path(os.environ['DEVRESTORE_NATIVE_OPAM'])
    manifest['setup']['managerDirectory'] = str(executable.parent)
    manifest['setup']['managers']['ocaml'] = executable.name
root = pathlib.Path(sys.argv[3])
repository = pathlib.Path(sys.argv[4])
assert repository.is_absolute() and (repository / 'repo').is_file()
original_run = support.run
failure = None
commands = []
def native_run(args, **kwargs):
    global failure
    if args[0] == os.environ['DEVRESTORE_NATIVE_OPAM']:
        commands.append(args[1:])
        if args[1:3] == ['switch', 'create']:
            args = [x for x in args if not x.startswith('ocaml-base-compiler.')]
            if '--empty' not in args:
                args.insert(4, '--empty')
        if failure and args[1:3] == ['repository', 'add'] and args[3] == 'lcs-upstream':
            failure = None
            raise support.BootstrapError('simulated interruption before upstream registration')
    return original_run(args, **kwargs)
module.run = native_run
ocaml.run = native_run
module.native_command = lambda name: os.environ['DEVRESTORE_NATIVE_OPAM'] if name == 'opam' else name
recovery = module.Bootstrap(manifest, ['ocaml'])
recovery.verify_runtime = lambda row: None
support.writable_directory(recovery.state)
support.writable_directory(recovery.opam)
release = manifest['ocaml']['versions'][0]
row = {'language': 'ocaml', 'version': release,
       'path': str(recovery.opam / f'lcs-ocaml-{release}/bin/ocamlc')}
failure = True
try:
    recovery.ocaml.create(row, repository)
except support.BootstrapError as error:
    assert 'simulated interruption' in str(error), error
else:
    raise AssertionError('handover interruption did not fail')
assert recovery.ocaml.read_pending(row)['stage'] == 'handover'
assert (recovery.opam / 'opam-init/env_hook.zsh').is_file()
assert not (root / 'home/.zshrc').exists()
recovery.ocaml.create(row, repository)
assert recovery.ocaml.read_pending(row) is None
assert recovery.ocaml.repositories('--set-default') == ['lcs-upstream']
assert recovery.ocaml.repositories(f'--switch=lcs-ocaml-{release}') == ['lcs-upstream']
assert all(not name.startswith('lcs-baseline-') for name in recovery.ocaml.repositories('--set-default'))
assert sum(args[:2] == ['switch', 'create'] for args in commands) == 1
print('PASS: native parsing, fresh hooks, interrupted handover and retry')

# Preserve existing global, root-default and project-local selections.
legacy = root / 'legacy'
legacy.mkdir()
(legacy / 'repo').write_text('opam-version: "2.0"\n')
recovery.ocaml.run('repository', 'add', 'legacy', legacy.as_uri(), '--dont-select')
recovery.ocaml.run('switch', 'create', 'existing', '--empty', '--no-switch', '--repositories=legacy')
recovery.ocaml.run('switch', 'set', 'existing')
recovery.ocaml.run('repository', 'set-repos', 'legacy', '--set-default')
project = root / 'project'
recovery.ocaml.run('switch', 'create', str(project), '--empty', '--no-switch', '--repositories=legacy')
row['version'] = manifest['ocaml']['versions'][1]
row['path'] = str(recovery.opam / f"lcs-ocaml-{row['version']}/bin/ocamlc")
recovery.ocaml.create(row, repository)
assert recovery.ocaml.run('switch', 'show') == 'existing'
assert recovery.ocaml.repositories('--set-default') == ['legacy']
assert recovery.ocaml.repositories('--switch=existing') == ['legacy']
assert recovery.ocaml.repositories(f'--switch={project}') == ['legacy']
assert recovery.ocaml.repositories(f"--switch=lcs-ocaml-{row['version']}") == ['lcs-upstream']
hook_source = pathlib.Path(sys.argv[1]).parents[2] / 'shells/zsh/config/languages/ocaml.zsh'
original_run(['zsh', '-dfi', '-c', '''
typeset -ga precmd_functions
source "$1"
[[ ${precmd_functions[(Ie)_zsh_opam_env_hook]} -gt 0 ]] || exit 1
_zsh_opam_env_hook || exit 1
[[ "$OPAM_SWITCH_PREFIX" == "$OPAMROOT/existing" ]] || exit 1
cd "$2" || exit 1
_zsh_opam_env_hook || exit 1
[[ "$OPAM_SWITCH_PREFIX" == "$2/_opam" ]] || exit 1
''', 'native-hook-test', str(hook_source), str(project)],
    env={'OPAMROOT': str(recovery.opam),
         'PATH': str(pathlib.Path(os.environ['DEVRESTORE_NATIVE_OPAM']).parent) + ':' + os.environ['PATH']})
# Regenerate a missing hook without changing established global/repository state.
from setup import BootstrapSetup
before_config = (recovery.opam / 'config').read_bytes()
(recovery.opam / 'opam-init/env_hook.zsh').unlink()
setup = BootstrapSetup(recovery)
setup.hooks()
assert (recovery.opam / 'opam-init/env_hook.zsh').is_file()
after_config = (recovery.opam / 'config').read_bytes()
if after_config != before_config:
    import difflib
    print(''.join(difflib.unified_diff(
        before_config.decode().splitlines(True),
        after_config.decode().splitlines(True))), flush=True)
assert recovery.ocaml.run('switch', 'show') == 'existing'
assert recovery.ocaml.repositories('--set-default') == ['legacy']
assert recovery.ocaml.repositories(f'--switch={project}') == ['legacy']
print('PASS: native missing-hook repair preserves global/repository selections')

recovery.ocaml.run('update', 'lcs-upstream', timeout=1800)
print('PASS: existing/global/default/local selections and ordinary upstream update')

# Completed work is never replayed on subsequent apply; a conflicting URL fails.
recovery.ocaml.run('repository', 'set-url', 'lcs-upstream', legacy.as_uri())
row['version'] = release
row['path'] = str(recovery.opam / f'lcs-ocaml-{release}/bin/ocamlc')
pending = {'root': str(recovery.opam), 'version': release,
           'revision': manifest['ocaml']['revision'], 'fresh': False, 'stage': 'handover'}
recovery.ocaml.save_pending(recovery.ocaml.pending_path(row), pending)
try:
    recovery.ocaml.create(row, repository)
except support.BootstrapError:
    assert recovery.ocaml.read_pending(row) is not None
else:
    raise AssertionError('conflicting upstream registration was accepted')
print('PASS: conflicting registration fails without rewriting its URL')
PY

print -r -- 'PASS: native opam setup contracts; empty switches only'

# ============================================================================ #
# End of tests/qualification/native-opam.zsh
