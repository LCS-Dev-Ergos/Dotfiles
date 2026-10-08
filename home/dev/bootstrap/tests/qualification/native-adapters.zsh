#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++ NATIVE ADAPTER FROM-ZERO QUALIFICATION ++++++++++++++++++ #
# ============================================================================ #
# Runs the packaged executor against real native managers in one disposable
# root: plan, apply, verify, verify --health, then apply again, per ecosystem.
# Each run also selects what the ecosystem requires, read from the catalog.
# The executor starts from an empty environment, so no exported manager root
# can redirect writes into the real home. The native package manager stays
# global: packages it installs are reported, not undone.
# Usage: native-adapters.zsh DEV_BOOTSTRAP LOG_DIR LANGUAGE...
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077
zmodload zsh/datetime

typeset executable="${1:?Provide the dev-bootstrap executable}"
typeset log="${2:?Provide a log directory}"
shift 2
(( $# )) || { print -u2 'Provide at least one language'; return 2; }
[[ -x "$executable" ]] || { print -u2 "Not executable: $executable"; return 2; }
typeset analysis="${DEV_BOOTSTRAP_ANALYSIS_PYTHON:-$(whence -p python3)}"
[[ -x "$analysis" ]] || { print -u2 'The report needs python3'; return 2; }

typeset root
root="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-native-adapters.XXXXXX")" || return 1
root="${root:A}"
[[ -d "$root" && "$root:t" == bootstrap-native-adapters.* ]] || return 1
command mkdir -p "$log" "$root"/{home,tmp,cache,state,data,config}
log="${log:A}"
if [[ "${DEV_BOOTSTRAP_KEEP_ROOT:-0}" != 1 ]]; then
  trap 'command rm -rf -- "$root"' EXIT
fi
trap 'exit 130' INT TERM HUP
print -r -- "root=$root"

# Selections and settings the real managers keep under the real home.
typeset -a guarded=(
  .local/share/fnm/aliases/default .pyenv/version .opam/config
  .rustup/settings.toml .ghcup/bin/ghc .ghcup/bin/cabal
  .ghcup/bin/haskell-language-server-wrapper .elan/settings.toml
  .rbenv/version .sdkman/candidates/java/current
  .sdkman/candidates/kotlin/current .sdkman/candidates/maven/current
  .sdkman/candidates/gradle/current .juliaup/juliaup.json
  .local/share/coursier/bin/scala
  'Library/Application Support/Coursier/bin/scala' .dotnet/dotnet
)
_snapshot_home() {
  local entry
  command ls -A "$HOME"
  for entry in "${guarded[@]}"; do
    if [[ -L "$HOME/$entry" ]]; then
      print -r -- "$entry link $(command readlink "$HOME/$entry")"
    elif [[ -f "$HOME/$entry" ]]; then
      print -r -- "$entry file $(command cksum < "$HOME/$entry")"
    else
      print -r -- "$entry absent"
    fi
  done
}
_snapshot_packages() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 /opt/homebrew/bin/brew list --formula -1
  elif [[ -x /usr/bin/pacman ]]; then
    /usr/bin/pacman -Qq
  fi
}
_executor() {
  local -a proxies=()
  local name
  for name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    [[ -n "${(P)name:-}" ]] && proxies+=("$name=${(P)name}")
  done
  command env -i HOME="$root/home" USER="$USER" LOGNAME="$USER" \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 TERM=dumb \
    TMPDIR="$root/tmp" XDG_CACHE_HOME="$root/cache" \
    XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
    XDG_CONFIG_HOME="$root/config" "${proxies[@]}" "$executable" "$@"
}

_snapshot_home > "$log/real-home-before.txt"
_snapshot_packages > "$log/packages-before.txt"

# The executor rejects a selection without its requirements; ask it for them.
_executor plan --json > "$log/catalog.json" 2> "$log/catalog.err" || {
  print -u2 'The executor did not report its catalog'
  return 1
}
typeset -A requires
typeset language required
while IFS=$'\t' read -r language required; do
  requires[$language]="$required"
done < <("$analysis" -I -c '
import json, sys
for entry in json.load(open(sys.argv[1]))["catalog"]:
    print(entry["language"], " ".join(entry["requires"]), sep="\t")
' "$log/catalog.json")

typeset step name
typeset -a selection
typeset -F start
typeset -i index code failed=0
: > "$log/steps.tsv"
for language in "$@"; do
  (( ${+requires[$language]} )) || {
    print -u2 "Unknown ecosystem: $language"
    return 2
  }
  selection=()
  for required in ${=requires[$language]} "$language"; do
    selection+=(--only "$required")
  done
  index=0
  for step in plan apply verify 'verify --health' apply; do
    (( ++index ))
    name="$language-$index-${step// /}"
    start=$EPOCHREALTIME
    code=0
    _executor ${=step} "${selection[@]}" --json \
      > "$log/$name.json" 2> "$log/$name.err" || code=$?
    printf '%s\t%s\t%d\t%.1f\n' "$language" "$step" "$code" \
      $(( EPOCHREALTIME - start )) >> "$log/steps.tsv"
    printf '%-8s %-16s exit=%d %6.1fs\n' "$language" "$step" "$code" \
      $(( EPOCHREALTIME - start ))
    (( code == 0 )) || failed=1
  done
done
_snapshot_home > "$log/real-home-after.txt"
_snapshot_packages > "$log/packages-after.txt"
command du -sk "$root"/home/.[!.]*(N) "$root"/data/*(N) "$root"/cache/*(N) \
  > "$log/disk-kib.txt" 2>/dev/null || true

# The second apply must install nothing: its installed releases equal those
# reported by the verification that preceded it.
"$analysis" -I - "$log" "$@" <<'PY' || failed=1
import json
import pathlib
import sys

log = pathlib.Path(sys.argv[1])
steps = [line.split("\t") for line in (log / "steps.tsv").read_text().splitlines()]
disk = {}
for line in (log / "disk-kib.txt").read_text().splitlines():
    size, path = line.split("\t", 1)
    disk[pathlib.Path(path).name] = int(size)
before = set((log / "packages-before.txt").read_text().split())
after = set((log / "packages-after.txt").read_text().split())
report = {
    "steps": [
        {"language": l, "step": s, "exit": int(c), "seconds": float(t)}
        for l, s, c, t in steps
    ],
    "diskKiB": disk,
    "nativePackagesInstalled": sorted(after - before),
    "realHomeUnchanged": (log / "real-home-before.txt").read_text()
    == (log / "real-home-after.txt").read_text(),
    "secondApplyInstalledNothing": {},
}
for language in sys.argv[2:]:
    try:
        verified = json.loads((log / f"{language}-3-verify.json").read_text())
        repeated = json.loads((log / f"{language}-5-apply.json").read_text())
        same = (
            verified["observed"]["installed"]
            == repeated["observed"]["installed"]
        )
    except (OSError, ValueError, KeyError):
        same = False
    report["secondApplyInstalledNothing"][language] = same
(log / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: report[k] for k in report if k != "steps"}, indent=2))
ok = report["realHomeUnchanged"] and all(
    report["secondApplyInstalledNothing"].values()
)
sys.exit(0 if ok else 1)
PY

if (( failed )); then
  print -u2 'FAIL: native adapter qualification; see the logs'
  return 1
fi
print -r -- 'PASS: native adapters from zero, preservation and idempotent rerun'

# ============================================================================ #
# End of tests/qualification/native-adapters.zsh
