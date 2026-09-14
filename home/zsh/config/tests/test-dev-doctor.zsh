#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++ DEV DOCTOR TEST SUITE +++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies scripts/dev-doctor.zsh against a synthetic manager registry and a
# synthetic PATH: state classification (ok, unused, shadowed, broken, absent,
# outdated), origin attribution, PATH conflict detection, exit codes, option
# handling, and the plain-output presentation contract. No real package
# manager, network call, or user cache is touched.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir dev-doctor)" || return 1
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP

# -----------------------------------------------------------------------------
# _dd_fail
# @internal
# @description Reports a failed expectation and aborts the suite.
# @arg $1 string Failure message.
# -----------------------------------------------------------------------------
_dd_fail() {
  print -u2 "FAIL: $1"
  exit 1
}

# -----------------------------------------------------------------------------
# _dd_stub
# @internal
# @description Writes an executable stub script.
# @arg $1 path Destination file.
# @arg $2 string Shell body evaluated with the stub's arguments.
# -----------------------------------------------------------------------------
_dd_stub() {
  local target="$1"
  local body="$2"
  {
    print -r -- '#!/bin/sh'
    print -r -- "$body"
  } >| "$target"
  command chmod 700 "$target"
}

# +++++++++++++++++++++++++++++++++ FIXTURES +++++++++++++++++++++++++++++++++ #

typeset bin_dir="$fixture_root/bin"
typeset alt_dir="$fixture_root/alt"
typeset ok_root="$fixture_root/roots/ok"
typeset unused_root="$fixture_root/roots/unused"
typeset shadow_root="$fixture_root/roots/shadow"
typeset session_root="$fixture_root/roots/session"
typeset missing_root="$fixture_root/roots/gone"
typeset absent_path="$fixture_root/roots/never-created"

command mkdir -p "$bin_dir" "$alt_dir" "$ok_root/bin" "$unused_root" \
  "$shadow_root/versions" "$session_root" "$fixture_root/cache"

# A manager that owns its language binary: the binary lives under its root.
_dd_stub "$bin_dir/okmgr" '
case "$1" in
  --version) echo "okmgr version 1.2.3" ;;
  list) echo "1.0.0"; echo "2.0.0" ;;
esac
'
_dd_stub "$ok_root/bin/oklang" 'echo "oklang 1.0.0"'
_dd_stub "$alt_dir/oklang" 'echo "package fallback 0.9.0"'

# A manager that manages nothing, so its language comes from somewhere else.
_dd_stub "$bin_dir/unusedmgr" '
case "$1" in
  --version) echo "unusedmgr 0.9" ;;
  list) : ;;
esac
'
_dd_stub "$bin_dir/unusedlang" 'echo "system unusedlang"'

# A manager with installed versions that still loses the PATH race.
_dd_stub "$bin_dir/shadowmgr" '
case "$1" in
  --version) echo "shadowmgr 3.1" ;;
  list) echo "3.1.0" ;;
esac
'
_dd_stub "$bin_dir/shadowlang" 'echo "shadowlang from bin"'
_dd_stub "$alt_dir/shadowlang" 'echo "shadowlang from alt"'

# npm reports whichever prefix the fixture asks for.
_dd_stub "$bin_dir/npm" '
if [ "$1" = config ]; then printf "%s\n" "${DD_NPM_PREFIX:-/nowhere}"; fi
'

# A manager that has to be activated per shell and has not been here.
_dd_stub "$bin_dir/sessionmgr" '
case "$1" in
  --version) echo "sessionmgr 7.7" ;;
  list) echo "7.7.0" ;;
esac
'
_dd_stub "$bin_dir/sessionlang" 'echo "sessionlang from bin"'

# A manager that put an empty shims directory on PATH, the rbenv symptom.
command mkdir -p "$fixture_root/empty/shims"

# A manager whose declared root has vanished.
_dd_stub "$bin_dir/brokenmgr" 'echo "brokenmgr 1.0"'

# A manager provided by Homebrew, for the batched update signal.
_dd_stub "$bin_dir/brewlang" 'echo "brewlang 2.0.0"'
_dd_stub "$bin_dir/brew" '
if [ "$1" = "outdated" ]; then
  echo "brewformula"
  echo "some/tap/other"
fi
if [ "$1" = "--version" ]; then echo "Homebrew 9.9.9"; fi
'

typeset registry="$fixture_root/runtime-managers.tsv"
{
  print -- "# id\tlabel\tplatform\troot_var\troot_default\tprobe\tversion_cmd\tlanguage_bin\tmanaged_list\tformula\tupdate_hint\tactivation"
  print -- "ok_mgr\tOK Manager\tany\tDD_OK_ROOT\t-\tokmgr\tokmgr --version\toklang\tokmgr list\t-\tokmgr update\talways"
  print -- "unused_mgr\tUnused Manager\tany\tDD_UNUSED_ROOT\t-\tunusedmgr\tunusedmgr --version\tunusedlang\tunusedmgr list\t-\t-\talways"
  print -- "shadow_mgr\tShadow Manager\tany\tDD_SHADOW_ROOT\t-\tshadowmgr\tshadowmgr --version\tshadowlang\tshadowmgr list\t-\t-\talways"
  print -- "broken_mgr\tBroken Manager\tany\tDD_MISSING_ROOT\t-\tbrokenmgr\t-\t-\t-\t-\t-\talways"
  print -- "absent_mgr\tAbsent Manager\tany\t-\t-\tdd-no-such-command\t-\t-\t-\t-\t-\talways"
  print -- "session_mgr\tSession Manager\tany\tDD_SESSION_ROOT\t-\tsessionmgr\tsessionmgr --version\tsessionlang\tsessionmgr list\t-\t-\tsession"
  print -- "brew_mgr\tBrew Manager\tany\t-\t-\tbrewlang\tbrewlang --version\t-\t-\tbrewformula\tbrew upgrade brewformula\talways"
  print -- "elsewhere_mgr\tElsewhere Manager\tLinux\t-\t-\tokmgr\t-\t-\t-\t-\t-\talways"
} >| "$registry"

export DD_OK_ROOT="$ok_root"
export DD_UNUSED_ROOT="$unused_root"
export DD_SHADOW_ROOT="$shadow_root"
export DD_SESSION_ROOT="$session_root"
export DD_MISSING_ROOT="$missing_root"

export ZSH_CONFIG_DIR="$test_root"
export DEVDOCTOR_REGISTRY="$registry"
export XDG_CACHE_HOME="$fixture_root/cache"
export ZSH_UI_STYLE=plain
export DEVDOCTOR_JOBS=2
unset NPM_CONFIG_PREFIX
export DEVDOCTOR_TIMEOUT=5

# The probes prefer coreutils timeout; expose it inside the fixture PATH so the
# suite exercises the primary path and stays fast. The polling fallback gets a
# dedicated check further down.
typeset real_timeout=""
real_timeout="$(whence -p timeout 2>/dev/null)" ||
  real_timeout="$(whence -p gtimeout 2>/dev/null)" || real_timeout=""
[[ -n "$real_timeout" ]] &&
  command ln -s "$real_timeout" "$bin_dir/timeout" 2>/dev/null

typeset original_path="$PATH"
export PATH="$bin_dir:$ok_root/bin:$alt_dir:$fixture_root/empty/shims:$absent_path:/usr/bin:/bin"
rehash

source "$test_root/scripts/dev-doctor.zsh" || _dd_fail "dev-doctor.zsh did not load"

# A responding manager is insufficient when its generated runtime launcher
# points to a missing extracted executable (not a jar). Include a space in the
# path, as Coursier's real macOS cache does.
typeset runtime_registry="$fixture_root/runtime-probes.tsv"
_dd_stub "$bin_dir/cs" 'echo "2.1.25"'
_dd_stub "$bin_dir/scala" 'exec "/missing cache/scala/bin/scala" "$@"'
_dd_stub "$bin_dir/erl" 'printf "29\n"'
{
  print -- "coursier\tScala\tany\t-\t-\tcs\tcs version\tscala\t-\t-\t-\talways\tscala version --offline"
  print -- "erlang\tErlang\tany\t-\t-\terl\thook\terl\t-\t-\t-\talways\tversion"
} >| "$runtime_registry"
rehash
typeset runtime_output
runtime_output="$(DEVDOCTOR_REGISTRY="$runtime_registry" devdoctor --json)" || true
[[ "$runtime_output" == *'"label":"Scala","state":"broken"'* ]] ||
  _dd_fail "a healthy manager hid a broken native runtime launcher"
[[ "$runtime_output" == *'"label":"Erlang","state":"ok","active":"29"'* ]] ||
  _dd_fail "Erlang's running VM must supply its OTP release"

_dd_stub "$bin_dir/scala" 'echo "3.9.0"'
runtime_output="$(DEVDOCTOR_REGISTRY="$runtime_registry" devdoctor --json)" || true
[[ "$runtime_output" == *'"label":"Scala","state":"ok","active":"3.9.0"'* ]] ||
  _dd_fail "a working runtime must report its own version"
_dd_stub "$bin_dir/scala" 'sleep 10'
runtime_output="$(DEVDOCTOR_TIMEOUT=1 DEVDOCTOR_REGISTRY="$runtime_registry" devdoctor --json)" || true
[[ "$runtime_output" == *'"label":"Scala","state":"unknown"'*'timed out'* ]] ||
  _dd_fail "a runtime timeout must remain inconclusive, not healthy or broken"
command rm -f "$bin_dir/scala"
runtime_output="$(DEVDOCTOR_REGISTRY="$runtime_registry" devdoctor --json)" || true
[[ "$runtime_output" == *'"label":"Scala","state":"broken"'* ]] ||
  _dd_fail "a missing managed executable must not be healthy"

# Compiler overrides are commands, not shell programs to eval. Their origin
# must follow CC/CXX rather than whichever cc happens to precede them on PATH.
typeset compiler_registry="$fixture_root/compilers.tsv"
typeset compiler_path="$ok_root/bin/compiler with spaces"
_dd_stub "$compiler_path" 'echo "clang version 22.1.8"'
{
  print -- "cc\tC compiler\tany\t-\t-\thook\thook\tcc\t-\t-\t-\talways\tversion"
  print -- "cxx\tC++ compiler\tany\t-\t-\thook\thook\tc++\t-\t-\t-\talways\tversion"
} >| "$compiler_registry"
runtime_output="$(CC="$compiler_path" CXX="\"$compiler_path\" -stdlib=libc++" \
  DEVDOCTOR_REGISTRY="$compiler_registry" devdoctor --json)" || true
[[ "$runtime_output" == *'"label":"C compiler","state":"ok","active":"22.1.8","origin":"other"'* &&
   "$runtime_output" == *'"label":"C++ compiler","state":"ok","active":"22.1.8"'* ]] ||
  _dd_fail "CC/CXX overrides with spaces or arguments were not honoured"
runtime_output="$(CC='/missing/compiler' DEVDOCTOR_REGISTRY="$compiler_registry" devdoctor --json)" || true
[[ "$runtime_output" == *'"label":"C compiler","state":"broken"'* ]] ||
  _dd_fail "an invalid explicit CC was hidden by PATH fallback"
runtime_output="$(CC='$(touch '$fixture_root'/evaluated)' DEVDOCTOR_REGISTRY="$compiler_registry" devdoctor --json)" || true
[[ ! -e "$fixture_root/evaluated" ]] || _dd_fail "CC was evaluated as shell code"
_dd_stub "$bin_dir/cc" 'echo "clang version 22.1.8"'
rehash
runtime_output="$(_devdoctor_path_conflicts - cc)"
[[ "$runtime_output" != *$'shadowed binary\tcc\t'* ]] ||
  _dd_fail "the system compiler fallback was treated as a competing toolchain"
command rm -f "$bin_dir/cc"
rehash

# No managed runtime: a version shim must not be invoked (some download a
# toolchain on first use). This holds independently of PATH precedence.
typeset empty_registry="$fixture_root/empty-runtime.tsv"
_dd_stub "$bin_dir/empty-runtime" 'touch "$DD_PROBE_MARKER"; echo "1.0"'
export DD_PROBE_MARKER="$fixture_root/unwanted-start"
print -- "empty\tEmpty\tany\t-\t-\tunusedmgr\tempty-runtime --version\tempty-runtime\tunusedmgr list\t-\t-\talways\tversion" >| "$empty_registry"
rehash
runtime_output="$(DEVDOCTOR_REGISTRY="$empty_registry" devdoctor --json)" || true
[[ ! -e "$DD_PROBE_MARKER" && "$runtime_output" == *'"state":"unused"'* ]] ||
  _dd_fail "an empty manager started its runtime shim"
command rm -f "$bin_dir/scala" "$bin_dir/cs" "$bin_dir/erl"
rehash

# +++++++++++++++++++++++++++++ LOCAL TIER TESTS +++++++++++++++++++++++++++++ #

typeset json_output
typeset -i status_code=0
json_output="$(devdoctor --all --json)" || status_code=$?

(( status_code == 2 )) ||
  _dd_fail "a broken manager must drive the exit code to 2, got $status_code"

[[ "$json_output" == *'"id":"ok_mgr","label":"OK Manager","state":"ok"'* ]] ||
  _dd_fail "ok_mgr was not reported as ok"
[[ "$json_output" == *'"state":"ok","active":"1.2.3","origin":"manager","detail":"2 managed"'* ]] ||
  _dd_fail "ok_mgr origin, version, or managed count is wrong"
[[ "$json_output" != *'"kind":"shadowed binary","subject":"oklang"'* ]] ||
  _dd_fail "a package fallback behind the selected manager was treated as a conflict"

[[ "$json_output" == *'"id":"unused_mgr","label":"Unused Manager","state":"unused"'* ]] ||
  _dd_fail "unused_mgr was not reported as unused"

[[ "$json_output" == *'"id":"shadow_mgr","label":"Shadow Manager","state":"shadowed"'* ]] ||
  _dd_fail "shadow_mgr was not reported as shadowed"

[[ "$json_output" == *'"id":"session_mgr","label":"Session Manager","state":"dormant"'* ]] ||
  _dd_fail "an unactivated per-shell manager must be dormant, not shadowed"
[[ "$json_output" == *'not activated here; sessionlang comes from'* ]] ||
  _dd_fail "the dormant manager did not explain itself"

[[ "$json_output" == *'"kind":"empty shims"'*"empty/shims"* ]] ||
  _dd_fail "an empty shims directory on PATH was not reported"

[[ "$json_output" == *'"id":"broken_mgr","label":"Broken Manager","state":"broken"'* ]] ||
  _dd_fail "broken_mgr was not reported as broken"
[[ "$json_output" == *'root missing'* ]] ||
  _dd_fail "broken_mgr did not explain the missing root"

[[ "$json_output" == *'"id":"absent_mgr"'* ]] ||
  _dd_fail "--all must include managers that are not installed"

[[ "$json_output" != *'elsewhere_mgr'* ]] ||
  _dd_fail "a Linux-only row must be skipped on this platform"

# A stale PATH entry and a duplicated binary are both reported as conflicts.
[[ "$json_output" == *'"kind":"stale entry"'*"never-created"* ]] ||
  _dd_fail "the nonexistent PATH entry was not reported"
[[ "$json_output" == *'"kind":"shadowed binary","subject":"shadowlang"'* ]] ||
  _dd_fail "the duplicated shadowlang binary was not reported"

# Without --all, managers that are not installed stay out of the report.
typeset filtered
filtered="$(devdoctor --json)" || true
[[ "$filtered" != *'"id":"absent_mgr"'* ]] ||
  _dd_fail "absent managers must be hidden without --all"

# +++++++++++++++++++++++++++++ REMOTE TIER TEST +++++++++++++++++++++++++++++ #

typeset updates_output
updates_output="$(devdoctor --updates --refresh --only brew_mgr --json 2>/dev/null)" || true
[[ "$updates_output" == *'"id":"brew_mgr","label":"Brew Manager","state":"outdated"'* ]] ||
  _dd_fail "a Homebrew-outdated formula did not mark its manager outdated"
[[ "$updates_output" == *'brew upgrade brewformula'* ]] ||
  _dd_fail "the outdated manager did not carry its update hint"

# The signals are cached, so a second pass must not consult Homebrew again.
typeset update_cache="$XDG_CACHE_HOME/zsh/devdoctor-updates.cache"
[[ -f "$update_cache" ]] || _dd_fail "update signals were not cached"
[[ "$(command cat -- "$update_cache")" == *"brew:brewformula"* ]] ||
  _dd_fail "the cached signal does not name the outdated formula"

command mv -f "$bin_dir/brew" "$fixture_root/brew.hidden"
rehash
typeset cached_output
cached_output="$(devdoctor --updates --only brew_mgr --json 2>/dev/null)" || true
[[ "$cached_output" == *'"state":"outdated"'* ]] ||
  _dd_fail "the cached update signal was not reused"
command mv -f "$fixture_root/brew.hidden" "$bin_dir/brew"
rehash

# ++++++++++++++++++++++++++ PRESENTATION CONTRACT +++++++++++++++++++++++++++ #

typeset report
report="$(devdoctor --all 2>&1)" || true
[[ "$report" == *"Development Environment"* ]] ||
  _dd_fail "the report is missing its banner"
[[ "$report" == *"PATH conflicts"* ]] ||
  _dd_fail "the report is missing the PATH conflicts section"
[[ "$report" == *"SHADOWED"* && "$report" == *"BROKEN"* ]] ||
  _dd_fail "the table does not surface the manager states"
[[ "$report" != *$'\e'* ]] ||
  _dd_fail "plain style must not emit ANSI escapes"

# +++++++++++++++++++++++++++++ OPTION HANDLING ++++++++++++++++++++++++++++++ #

devdoctor --help >/dev/null || _dd_fail "--help must succeed"

typeset -i only_status=0
devdoctor --only dd-not-a-manager >/dev/null 2>&1 || only_status=$?
(( only_status == 2 )) || _dd_fail "an unknown --only id must fail with 2"

typeset -i opt_status=0
devdoctor --nope >/dev/null 2>&1 || opt_status=$?
(( opt_status == 2 )) || _dd_fail "an unknown option must fail with 2"

typeset -i missing_status=0
DEVDOCTOR_REGISTRY="$fixture_root/no-registry.tsv" \
  devdoctor >/dev/null 2>&1 || missing_status=$?
(( missing_status == 2 )) || _dd_fail "a missing registry must fail with 2"

# ++++++++++++++++++++++++++++ UNIT-LEVEL CHECKS +++++++++++++++++++++++++++++ #

_devdoctor_version_token "go version go1.27.1 darwin/arm64"
[[ "$REPLY" == "1.27.1" ]] ||
  _dd_fail "a prefixed version token was not reduced, got '$REPLY'"
_devdoctor_version_token "rustc 1.98.1 (48a229cea 2026-09-01)"
[[ "$REPLY" == "1.98.1" ]] ||
  _dd_fail "a plain version banner was not reduced, got '$REPLY'"
_devdoctor_version_token "system"
[[ "$REPLY" == "system" ]] ||
  _dd_fail "a non-numeric version must be preserved, got '$REPLY'"

_devdoctor_resolve_root DD_OK_ROOT '~/.one,~/.two'
[[ "$REPLY" == "$ok_root" && "${#reply}" -eq 2 && "${reply[2]}" == "$HOME/.two" ]] ||
  _dd_fail "root resolution did not honour the env var plus the extra root"

_devdoctor_origin "/nix/store/abc/bin/tool"
[[ "$REPLY" == "nix" ]] || _dd_fail "a Nix path was not attributed to nix"
_devdoctor_origin "$ok_root/bin/oklang" "$ok_root"
[[ "$REPLY" == "manager" ]] || _dd_fail "a manager-owned path was misattributed"

typeset -i timed_out=0
_devdoctor_run_timeout 1 /bin/sleep 5 >/dev/null 2>&1 || timed_out=1
(( timed_out == 1 )) || _dd_fail "the timeout did not interrupt a slow probe"

# Same contract without coreutils timeout, so the polling fallback is covered.
if [[ -n "$real_timeout" ]]; then
  command rm -f "$bin_dir/timeout"
  rehash
  typeset -i fallback_elapsed=0 fallback_status=0
  typeset -F SECONDS=0
  _devdoctor_run_timeout 1 /bin/sleep 5 >/dev/null 2>&1 || fallback_status=1
  fallback_elapsed=$(( SECONDS ))
  (( fallback_status == 1 )) ||
    _dd_fail "the fallback timeout did not interrupt a slow probe"
  (( fallback_elapsed < 4 )) ||
    _dd_fail "the fallback waited $fallback_elapsed s instead of interrupting"

  typeset fallback_out
  fallback_out="$(_devdoctor_run_timeout 3 /bin/echo fallback-ok)" ||
    _dd_fail "the fallback failed a command that finishes in time"
  [[ "$fallback_out" == "fallback-ok" ]] ||
    _dd_fail "the fallback lost the command output, got '$fallback_out'"

  fallback_status=0
  SECONDS=0
  _devdoctor_run_timeout 1 /bin/sh -c 'trap "" TERM; while :; do :; done' \
    >/dev/null 2>&1 || fallback_status=$?
  (( fallback_status == 124 && SECONDS < 4 )) ||
    _dd_fail "the fallback did not bound a probe that ignores TERM"

  command ln -s "$real_timeout" "$bin_dir/timeout"
  rehash
fi

# +++++++++++++++++++++++++++++ NPM PREFIX CHECK +++++++++++++++++++++++++++++ #

# A global npm prefix inside a version manager's tree is how globally installed
# CLIs disappear when a Node version is replaced or removed.
# A leading VAR=value on an assignment is another assignment in zsh, not an
# environment prefix, so the stub only sees an exported variable.
typeset scoped_output
export DD_NPM_PREFIX="$ok_root/lib/node_modules"
scoped_output="$(devdoctor --only ok_mgr --json)" || true
[[ "$scoped_output" == *'"kind":"npm globals"'*"lib/node_modules"* ]] ||
  _dd_fail "a version-scoped npm prefix was not reported"

typeset unscoped_output
export NPM_CONFIG_PREFIX="$fixture_root/npm-global"
unscoped_output="$(devdoctor --only ok_mgr --json)" || true
[[ "$unscoped_output" != *'"kind":"npm globals"'* ]] ||
  _dd_fail "a prefix outside every manager tree must not be reported"
unset DD_NPM_PREFIX NPM_CONFIG_PREFIX

# ++++++++++++++++++++++++++++ REGISTRY HARDENING ++++++++++++++++++++++++++++ #

# Registry fields are executed as commands, so a registry other accounts can
# rewrite must be refused rather than run.
typeset shared_registry="$fixture_root/shared-registry.tsv"
command cp "$registry" "$shared_registry"
command chmod 666 "$shared_registry"
typeset -i shared_status=0
DEVDOCTOR_REGISTRY="$shared_registry" devdoctor >/dev/null 2>&1 || shared_status=$?
(( shared_status == 2 )) ||
  _dd_fail "a world-writable registry must be refused, got $shared_status"
command chmod 600 "$shared_registry"
DEVDOCTOR_REGISTRY="$shared_registry" devdoctor >/dev/null 2>&1 || true

# The id becomes a filename in the work directory.
typeset bad_id_registry="$fixture_root/bad-id.tsv"
{ print -- "../escape\tEscape\tany\t-\t-\tokmgr\t-\t-\t-\t-\t-\talways" } >| "$bad_id_registry"
typeset -i bad_id_status=0
DEVDOCTOR_REGISTRY="$bad_id_registry" devdoctor >/dev/null 2>&1 || bad_id_status=$?
(( bad_id_status == 2 )) ||
  _dd_fail "a path-traversing manager id must be refused, got $bad_id_status"

typeset dup_registry="$fixture_root/duplicate.tsv"
{
  print -- "ok_mgr\tFirst\tany\t-\t-\tokmgr\t-\t-\t-\t-\t-\talways\talways"
  print -- "ok_mgr\tSecond\tany\t-\t-\tokmgr\t-\t-\t-\t-\t-\talways\talways"
} >| "$dup_registry"
typeset -i dup_status=0
DEVDOCTOR_REGISTRY="$dup_registry" devdoctor >/dev/null 2>&1 || dup_status=$?
(( dup_status == 2 )) ||
  _dd_fail "a duplicate manager id must be refused, got $dup_status"

# A probe that emits a tab must not be able to shift the record columns.
_dd_stub "$bin_dir/tabmgr" 'printf "weird\tinjected\tvalue\n"'
typeset tab_registry="$fixture_root/tabbed.tsv"
{ print -- "tab_mgr\tTab Manager\tany\t-\t-\ttabmgr\ttabmgr --version\t-\t-\t-\t-\talways" } >| "$tab_registry"
rehash
typeset tab_output
tab_output="$(DEVDOCTOR_REGISTRY="$tab_registry" devdoctor --json)" || true
[[ "$tab_output" == *'"active":"weird injected value"'* ]] ||
  _dd_fail "a tab in probe output was not neutralised: $tab_output"

export PATH="$original_path"
rehash
print -r -- "PASS: manager states, PATH conflicts, update signals, and timeouts"

# ============================================================================ #
# End of tests/test-dev-doctor.zsh
