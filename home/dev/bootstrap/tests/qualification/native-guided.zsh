#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++ GUIDED SETUP REAL-TERMINAL QUALIFICATION +++++++++++++ #
# ============================================================================ #
# Drives `dev-bootstrap setup` through a pseudo-terminal with the pinned Gum,
# against real native managers in one disposable root, for the ecosystems
# given and what they require:
#   cancel      setup without options, Esc at the ecosystem question: exit
#               130 and nothing written.
#   apply       setup --only ...: the privilege choice (default: authenticate)
#               when packages need it, then the review (default: yes).
#   rerun       the same again: only the review is asked, nothing installs.
#   unattended  setup without a terminal and without --yes: exit 2 before any
#               change.
#   health      verify --health for the selection.
# The executor starts from an empty environment, so no exported manager root
# can redirect writes into the real home. The native package manager stays
# global: packages it installs are reported, not undone.
# Usage: native-guided.zsh DEV_BOOTSTRAP LOG_DIR LANGUAGE...
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
typeset driver="${0:A:h}/guided-pty.py"

_snapshot_home > "$log/real-home-before.txt"
_snapshot_packages > "$log/packages-before.txt"
_requirements || return 1
_selection "$@" || return 2
typeset -a selection=("${reply[@]}")

# _guided NAME ANSWER... -- ARGUMENTS...: one setup in a real terminal.
_guided() {
  local name="$1" code=0
  shift
  local -a answers=()
  while [[ "$1" != -- ]]; do
    answers+=(--answer "$1")
    shift
  done
  shift
  local -F start=$EPOCHREALTIME
  _isolated TERM=xterm-256color "$analysis" -I "$driver" \
    "$log/$name.transcript" "$log/$name.json" "${answers[@]}" -- \
    "$executable" setup "$@" || code=$?
  printf '%-10s exit=%d %6.1fs\n' "$name" "$code" $(( EPOCHREALTIME - start ))
  printf '%s\t%d\t%.1f\n' "$name" "$code" $(( EPOCHREALTIME - start )) \
    >> "$log/steps.tsv"
}

: > "$log/steps.tsv"
_guided cancel 'Ecosystems to set up=\x1b' --
command ls -A "$root/state" "$root/config" > "$log/cancel-state.txt" 2>&1
# A password prompt means privilege was not set up for an unattended runner:
# Ctrl-C fails the run instead of waiting for a person.
_guided apply 'needs administrator rights=\r' 'Apply this review?=\r' \
  'password for=\x03' -- "${selection[@]}"
_guided rerun 'needs administrator rights=\r' 'Apply this review?=\r' \
  -- "${selection[@]}"

typeset -i code=0
_executor setup "${selection[@]}" < /dev/null \
  > "$log/unattended.out" 2> "$log/unattended.err" || code=$?
printf 'unattended\t%d\t0\n' "$code" >> "$log/steps.tsv"
code=0
_executor verify --health "${selection[@]}" --json \
  > "$log/health.json" 2> "$log/health.err" || code=$?
printf 'health\t%d\t0\n' "$code" >> "$log/steps.tsv"

_snapshot_home > "$log/real-home-after.txt"
_snapshot_packages > "$log/packages-after.txt"

"$analysis" -I - "$log" <<'PY'
import json
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1])
steps = {
    name: int(code)
    for name, code, _ in (
        line.split("\t") for line in (log / "steps.tsv").read_text().splitlines()
    )
}


def record(name):
    try:
        return json.loads((log / f"{name}.json").read_text())
    except (OSError, ValueError):
        return {}


def screen(name):
    raw = (log / f"{name}.transcript").read_bytes().decode("utf-8", "replace")
    return re.sub(r"\x1b\[[0-9;?<>=$]*[A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", raw)


before = set((log / "packages-before.txt").read_text().split())
after = set((log / "packages-after.txt").read_text().split())
checks = {
    "cancelExits130": steps.get("cancel") == 130
    and record("cancel").get("answered") == ["Ecosystems to set up"],
    # Cancelling writes no run and no saved selection.
    "cancelWritesNothing": not re.search(
        r"runs|selection", (log / "cancel-state.txt").read_text()
    ),
    # With packages to install as root, the privilege choice stands in for
    # the confirmation; otherwise the confirmation alone is asked.
    "applySucceeds": steps.get("apply") == 0
    and record("apply").get("answered")
    in (["Apply this review?"], ["needs administrator rights"]),
    "rerunOnlyConfirms": steps.get("rerun") == 0
    and record("rerun").get("answered") == ["Apply this review?"]
    and "Every runtime of the selection is installed." in screen("rerun"),
    "unattendedNeedsYes": steps.get("unattended") == 2
    and "--yes" in (log / "unattended.err").read_text(),
    "healthPasses": steps.get("health") == 0,
    "realHomeUnchanged": (log / "real-home-before.txt").read_text()
    == (log / "real-home-after.txt").read_text(),
}
report = {
    "steps": steps,
    "checks": checks,
    "privilegeAsked": "needs administrator rights"
    in record("apply").get("answered", []),
    "nativePackagesInstalled": sorted(after - before),
}
(log / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
sys.exit(0 if all(checks.values()) else 1)
PY
print -r -- 'PASS: guided setup in a real terminal, cancel, apply, rerun and unattended'

# ============================================================================ #
# End of tests/qualification/native-guided.zsh
