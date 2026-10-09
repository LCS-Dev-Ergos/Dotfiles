#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++ NATIVE MANAGER LIFECYCLE QUALIFICATION ++++++++++++++++++ #
# ============================================================================ #
# Shows that bootstrap coexists with the managers' ordinary evolution, in one
# disposable root holding every selected ecosystem and its requirements:
#   1. apply from zero;
#   2. each manager's ordinary update, then apply, verify, verify --health;
#   3. user evolution: add a release and change the default by hand, then
#      apply, verify, verify --health.
# After steps 2 and 3, apply must install nothing and change no selection,
# the seeds must still pass exact verification and health must pass; step 3
# must also have changed what it meant to change. Native package upgrades
# are global, so they run only with DEV_BOOTSTRAP_PACKAGE_UPGRADES=1, as in
# CI: Homebrew upgrades the declared managers and build libraries, pacman the
# whole system. Health after them is the native ABI drift check.
# Usage: native-lifecycle.zsh DEV_BOOTSTRAP LOG_DIR LANGUAGE...
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset executable="${1:?Provide the dev-bootstrap executable}"
typeset log="${2:?Provide a log directory}"
shift 2
(( $# )) || { print -u2 'Provide at least one language'; return 2; }
[[ -x "$executable" ]] || { print -u2 "Not executable: $executable"; return 2; }
source "${0:A:h}/common.zsh" || return 2

_snapshot_home > "$log/real-home-before.txt"
_snapshot_packages > "$log/packages-before.txt"
_requirements || return 1
_selection "$@" || return 2
typeset -a selection=("${reply[@]}")
typeset -a languages=("${(@)selection:#--only}")

# SDKMAN needs the Bash 4 the package runs it with.
typeset manifest="${executable:A:h:h}/share/development-bootstrap/baseline.json"
typeset sdkman_bash
sdkman_bash="$("$analysis" -I -c '
import json, sys
print(json.load(open(sys.argv[1]))["setup"].get("sdkmanShell", ""))
' "$manifest")"
# The native packages the declaration names: managers and build libraries.
typeset -a declared_packages=(${(f)"$("$analysis" -I -c '
import json, sys
setup = json.load(open(sys.argv[1]))["setup"]
names = set(setup.get("managers", {}).values())
for packages in setup.get("buildPackages", {}).values():
    names.update(packages)
print("\n".join(sorted(names)))
' "$manifest")"})

typeset home="$root/home" coursier_bin coursier_cache
if [[ "$OSTYPE" == darwin* ]]; then
  coursier_bin="$home/Library/Application Support/Coursier/bin"
  coursier_cache="$home/Library/Caches/Coursier/v1"
else
  coursier_bin="$root/data/coursier/bin"
  coursier_cache="$root/cache/coursier/v1"
fi
# The roots and search path an interactive shell exports for these managers.
# Coursier's native launcher finds the home through the account database, not
# HOME, so every Coursier directory is named explicitly; otherwise `cs`
# writes into the real home.
typeset -a manager_environment=(
  PATH="$home/.cargo/bin:$home/.elan/bin:$home/.ghcup/bin:$home/.juliaup/bin:$coursier_bin:$root/data/fnm:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  FNM_DIR="$root/data/fnm"
  COURSIER_BIN_DIR="$coursier_bin"
  COURSIER_CACHE="$coursier_cache"
  COURSIER_ARCHIVE_CACHE="$root/data/coursier/arc"
  JULIAUP_DEPOT_PATH="$home/.julia"
)

typeset -F start
typeset -i failed=0
: > "$log/steps.tsv"

# -----------------------------------------------------------------------------
# _step
# @description Runs one executor action on the whole selection.
# @arg $1 string Log name.
# @arg $@ string The action and its options.
# -----------------------------------------------------------------------------
_step() {
  local name="$1" code=0
  shift
  start=$EPOCHREALTIME
  _executor "$@" "${selection[@]}" --json \
    > "$log/$name.json" 2> "$log/$name.err" || code=$?
  printf 'executor\t%s\t%d\t%.1f\n' "$name" "$code" \
    $(( EPOCHREALTIME - start )) >> "$log/steps.tsv"
  printf '%-28s exit=%d %6.1fs\n' "$name" "$code" $(( EPOCHREALTIME - start ))
  (( code == 0 )) || failed=1
}

# -----------------------------------------------------------------------------
# _manager
# @description Runs a manager command as a user would, in the root.
# @option --tolerated Record the exit status without failing the run.
# @arg $1 string Log name.
# @arg $@ string The command.
# -----------------------------------------------------------------------------
_manager() {
  local tolerated=0
  [[ "$1" == --tolerated ]] && { tolerated=1; shift; }
  local name="$1" code=0
  shift
  start=$EPOCHREALTIME
  _isolated "${manager_environment[@]}" "$@" \
    > "$log/$name.log" 2>&1 < /dev/null || code=$?
  printf 'manager\t%s\t%d\t%.1f\n' "$name" "$code" \
    $(( EPOCHREALTIME - start )) >> "$log/steps.tsv"
  printf '%-28s exit=%d %6.1fs\n' "$name" "$code" $(( EPOCHREALTIME - start ))
  (( code == 0 || tolerated )) || failed=1
}

_sdk() {
  _manager "$1" "$sdkman_bash" --noprofile --norc -c \
    'source "$HOME/.sdkman/bin/sdkman-init.sh" || exit; sdk "$@" <<< n' \
    sdk "${@:2}"
}

_has() { (( ${languages[(Ie)$1]} )) }

_step 1-apply apply

# 2. Ordinary manager updates. FNM, pyenv and rbenv update only through their
# native packages; .NET has no manager, and `conda update` evolves the base
# that exact verification describes, so neither has an update here.
if [[ "${DEV_BOOTSTRAP_PACKAGE_UPGRADES:-0}" == 1 ]]; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    # brew refuses to upgrade a formula that is not installed.
    typeset -a installed_packages=(
      ${(f)"$(/opt/homebrew/bin/brew list --formula -1)"}
    )
    typeset -a upgrade=("${(@)declared_packages:*installed_packages}")
    # Homebrew exits 1 when it installs a formula but cannot link it over a
    # file another formula owns (a runner's openssl@1.1 owns bin/openssl).
    # Runtimes use the opt prefixes, so what counts is that nothing declared
    # is still outdated afterwards.
    _manager --tolerated update-packages env HOMEBREW_NO_INSTALL_CLEANUP=1 \
      HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
      /opt/homebrew/bin/brew upgrade --formula "${upgrade[@]}"
    _manager update-packages-current sh -c \
      'test -z "$(/opt/homebrew/bin/brew outdated --formula --quiet "$@")"' \
      sh "${upgrade[@]}"
  elif [[ -x /usr/bin/pacman ]]; then
    _manager update-packages sudo -n /usr/bin/pacman -Syu --noconfirm
  fi
fi
_has ocaml && _manager update-opam opam update
_has rust && _manager update-rustup rustup update
_has haskell && _manager update-ghcup ghcup upgrade
_has lean && _manager update-elan elan self update
_has jvm && _sdk update-sdkman selfupdate
_has scala && _manager update-coursier cs update
_has julia && _manager update-juliaup juliaup self update
_step 2-plan-updated plan
_step 3-apply-updated apply
_step 4-verify-updated verify
_step 5-health-updated verify --health

# 3. User evolution, kept cheap: where adding a release means a compiler
# build (Python, Ruby, OCaml) or a large download (Lean, a JDK, .NET), only
# the default changes. Each language whose recorded selection changes is
# listed, so a vacuous evolution fails the run.
typeset -a evolved=()
if _has node; then
  _manager evolve-node fnm install 22
  _manager evolve-node-default fnm default 22
  evolved+=(node)
fi
# `system` needs a host interpreter: the Arch image has Python, not Ruby.
if _has python && [[ -x /usr/bin/python3 ]]; then
  _manager evolve-python pyenv global system
  evolved+=(python)
fi
if _has ocaml; then
  _manager evolve-ocaml opam switch set "$(
    "$analysis" -I -c '
import json, sys
rows = json.load(open(sys.argv[1]))["runtimes"]
print(sorted(r["path"] for r in rows if r["language"] == "ocaml")[0]
      .rsplit("/bin/", 1)[0].rsplit("/", 1)[1])
' "$log/2-plan-updated.json")"
  evolved+=(ocaml)
fi
if _has rust; then
  _manager evolve-rust rustup toolchain install 1.97.0 --profile minimal
  _manager evolve-rust-default rustup default 1.97.0
  evolved+=(rust)
fi
# The report does not record the Cabal selection; the selected cabal's own
# release is checked after the evolved apply.
if _has haskell; then
  _manager evolve-cabal ghcup install cabal 3.14.2.0
  _manager evolve-cabal-default ghcup set cabal 3.14.2.0
fi
if _has ruby && [[ -x /usr/bin/ruby ]]; then
  _manager evolve-ruby rbenv global system
  evolved+=(ruby)
fi
if _has kotlin; then
  _sdk evolve-kotlin install kotlin 2.4.20
  _sdk evolve-kotlin-default default kotlin 2.4.20
  evolved+=(kotlin)
fi
if _has maven; then
  _sdk evolve-maven install maven 3.9.16
  _sdk evolve-maven-default default maven 3.9.16
  evolved+=(maven)
fi
if _has scala; then
  _manager evolve-scala cs install scala:3.8.1 scalac:3.8.1
  evolved+=(scala)
fi
if _has julia; then
  _manager evolve-julia juliaup add 1.11
  _manager evolve-julia-default juliaup default 1.11
  evolved+=(julia)
fi
_step 6-plan-evolved plan
_step 7-apply-evolved apply
_step 8-verify-evolved verify
_step 9-health-evolved verify --health
if _has haskell; then
  _manager kept-cabal sh -c \
    'test "$("$HOME/.ghcup/bin/cabal" --numeric-version)" = 3.14.2.0'
fi

_snapshot_home > "$log/real-home-after.txt"
_snapshot_packages > "$log/packages-after.txt"

"$analysis" -I - "$log" "${evolved[@]}" <<'PY' || failed=1
import json
import pathlib
import sys

log = pathlib.Path(sys.argv[1])


def observed(name):
    return json.loads((log / f"{name}.json").read_text())["observed"]


steps = [line.split("\t") for line in (log / "steps.tsv").read_text().splitlines()]
updated, after_update = observed("2-plan-updated"), observed("3-apply-updated")
evolved, after_evolution = observed("6-plan-evolved"), observed("7-apply-evolved")
before = set((log / "packages-before.txt").read_text().split())
after = set((log / "packages-after.txt").read_text().split())
report = {
    "steps": [
        {"kind": k, "step": s, "exit": int(c), "seconds": float(t)}
        for k, s, c, t in steps
    ],
    "nativePackagesChanged": sorted(after ^ before),
    "realHomeUnchanged": (log / "real-home-before.txt").read_text()
    == (log / "real-home-after.txt").read_text(),
    # apply after an update or an evolution installs and selects nothing.
    "applyKeptUpdatedState": updated == after_update,
    "applyKeptEvolvedState": evolved == after_evolution,
    # The evolution really changed selections, so the check above means
    # something: every changed language is listed.
    "evolvedSelections": sorted(
        language
        for language, selection in evolved["globalSelections"].items()
        if selection != updated["globalSelections"][language]
    ),
    "expectedEvolution": sorted(sys.argv[2:]),
}
(log / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "steps"}, indent=2))
ok = (
    report["realHomeUnchanged"]
    and report["applyKeptUpdatedState"]
    and report["applyKeptEvolvedState"]
    and set(report["expectedEvolution"]) <= set(report["evolvedSelections"])
)
sys.exit(0 if ok else 1)
PY

if (( failed )); then
  print -u2 'FAIL: native manager lifecycle; see the logs'
  return 1
fi
print -r -- 'PASS: updates and user evolution leave bootstrap with nothing to do'

# ============================================================================ #
# End of tests/qualification/native-lifecycle.zsh
