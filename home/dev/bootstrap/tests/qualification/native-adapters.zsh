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

typeset executable="${1:?Provide the dev-bootstrap executable}"
typeset log="${2:?Provide a log directory}"
shift 2
(( $# )) || { print -u2 'Provide at least one language'; return 2; }
[[ -x "$executable" ]] || { print -u2 "Not executable: $executable"; return 2; }
source "${0:A:h}/common.zsh" || return 2

_snapshot_home > "$log/real-home-before.txt"
_snapshot_packages > "$log/packages-before.txt"
_requirements || return 1

typeset language step name
typeset -a selection
typeset -F start
typeset -i index code failed=0
: > "$log/steps.tsv"
for language in "$@"; do
  _selection "$language" || return 2
  selection=("${reply[@]}")
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
