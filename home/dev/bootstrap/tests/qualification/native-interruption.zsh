#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++ NATIVE INTERRUPTION QUALIFICATION +++++++++++++++++++++ #
# ============================================================================ #
# Interrupts a real apply during its runtime stage and checks the recovery,
# each scenario in its own disposable home:
#   LANGUAGE:SIGINT, LANGUAGE:SIGTERM  signal the executor once the
#                                      manager's install is running;
#   LANGUAGE:network[:BYTES]           cut a proxy-only network after a byte
#                                      budget (4 MiB by default), which the
#                                      language's download exceeds.
# Each interrupted run must exit (128 + signal, or 2 for the network), leave
# the lock free and no process behind; `plan` then reports the language's
# rows, and a plain retry must complete.
# Usage: native-interruption.zsh DEV_BOOTSTRAP LOG_DIR LANGUAGE:KIND[:BYTES]...
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset executable="${1:?Provide the dev-bootstrap executable}"
typeset log="${2:?Provide a log directory}"
shift 2
(( $# )) || { print -u2 'Provide at least one LANGUAGE:KIND scenario'; return 2; }
[[ -x "$executable" ]] || { print -u2 "Not executable: $executable"; return 2; }
source "${0:A:h}/common.zsh" || return 2
typeset base="$root"
if [[ "${DEV_BOOTSTRAP_KEEP_ROOT:-0}" != 1 ]]; then
  trap 'command rm -rf -- "$base"' EXIT
fi

_snapshot_home > "$log/real-home-before.txt"
_requirements || return 1

# The command line of each language's runtime installation, once it runs.
typeset -A installing=(
  node 'fnm.* install' python python-build ocaml 'opam switch create'
  rust 'rustup toolchain install' haskell 'ghcup install' lean
  'elan toolchain install' ruby ruby-build jvm 'dev-bootstrap-sdkman.* install'
  kotlin 'dev-bootstrap-sdkman.* install' maven 'dev-bootstrap-sdkman.* install'
  gradle 'dev-bootstrap-sdkman.* install' scala 'cs install' julia
  'juliaup add' dotnet dotnet-install conda Miniforge3
)
typeset bootstrap="${executable:A:h:h}/share/development-bootstrap/bootstrap.py"
# A non-interactive shell starts background jobs with SIGINT ignored, and
# Python keeps an inherited ignore; a terminal's foreground apply has the
# default, so restore it before the executor starts.
typeset interruptible='import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])'
typeset -i failed=0 proxy=0 proxy_pid job
typeset scenario language kind budget name lock_state lingering

_lingering() {
  # How many processes still work inside the scenario root.
  local -i count=0
  if [[ -d /proc/self ]]; then
    local link
    for link in /proc/[0-9]*/cwd(N); do
      [[ "$(command readlink "$link" 2>/dev/null)" == "$root"* ]] && (( ++count ))
    done
  else
    count=$(command lsof -a -d cwd -Fn 2>/dev/null | command grep -c "^n$root" || true)
  fi
  print -r -- $count
}

_lock_free() {
  "$analysis" -I -c '
import fcntl, sys
try:
    with open(sys.argv[1], "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("free")
except BlockingIOError:
    print("held")
except FileNotFoundError:
    print("absent")
' "$root/state/dev-bootstrap/apply.lock"
}

: > "$log/scenarios.tsv"
for scenario in "$@"; do
  language="${scenario%%:*}" kind="${${scenario#*:}%%:*}"
  budget="${${scenario#*:*:}:-}"
  [[ "$scenario" == *:*:* ]] || budget=$(( 4 * 1024 * 1024 ))
  name="${language}-${kind}"
  _selection "$language" || return 2
  root="$base/$name"
  command mkdir -p "$root"/{home,tmp,cache,state,data,config}
  print -r -- "== $scenario"
  case "$kind" in
    SIGINT|SIGTERM)
      _isolated "$analysis" -I -c "$interruptible" "$executable" apply \
        "${reply[@]}" --json \
        > "$log/$name-1-apply.json" 2> "$log/$name-1-apply.err" &
      job=$!
      # Wait for the manager's install, then let it get going.
      until command pgrep -f -- "${installing[$language]}" > /dev/null; do
        kill -0 $job 2>/dev/null || break
        sleep 0.5
      done
      sleep 5
      print -r -- "install running: $(command pgrep -f -- "${installing[$language]}" | head -1); sending $kind"
      command pkill -"${kind#SIG}" -f -- "$bootstrap" ||
        print -u2 "No executor to signal: $bootstrap"
      ;;
    network)
      coproc "$analysis" -I "${0:A:h}/cut-proxy.py" "$budget"
      proxy_pid=$!
      read -r proxy <&p
      HTTPS_PROXY="http://127.0.0.1:$proxy" https_proxy="http://127.0.0.1:$proxy" \
        _executor apply "${reply[@]}" --json \
        > "$log/$name-1-apply.json" 2> "$log/$name-1-apply.err" &
      job=$!
      ;;
    *) print -u2 "Unknown scenario kind: $kind"; return 2 ;;
  esac
  typeset -i code=0
  wait $job || code=$?
  [[ "$kind" == network ]] && kill $proxy_pid 2>/dev/null
  sleep 2
  lock_state="$(_lock_free)"
  lingering="$(_lingering)"
  _executor plan "${reply[@]}" --json > "$log/$name-2-plan.json" 2>/dev/null || true
  typeset -i retry=0
  _executor apply "${reply[@]}" --json \
    > "$log/$name-3-retry.json" 2> "$log/$name-3-retry.err" || retry=$?
  printf '%s\t%s\t%d\t%s\t%s\t%d\n' "$language" "$kind" "$code" \
    "$lock_state" "${lingering:-0}" "$retry" >> "$log/scenarios.tsv"
  printf '%-8s %-8s exit=%d lock=%s lingering=%s retry=%d\n' "$language" \
    "$kind" "$code" "$lock_state" "${lingering:-0}" "$retry"
  command rm -rf -- "$root"
done
root="$base"
_snapshot_home > "$log/real-home-after.txt"

"$analysis" -I - "$log" <<'PY' || failed=1
import json
import pathlib
import signal
import sys

log = pathlib.Path(sys.argv[1])
rows = []
for line in (log / "scenarios.tsv").read_text().splitlines():
    language, kind, code, lock, lingering, retry = line.split("\t")
    plan = json.loads((log / f"{language}-{kind}-2-plan.json").read_text())
    expected = 2 if kind == "network" else 128 + getattr(signal, kind)
    rows.append(
        {
            "language": language,
            "kind": kind,
            "exit": int(code),
            "expectedExit": expected,
            "lock": lock,
            "lingering": int(lingering),
            "planAfter": {
                r.get("component") or r["version"]: r["state"]
                for r in plan["runtimes"]
                if r["language"] == language
            },
            "retryExit": int(retry),
        }
    )
report = {
    "scenarios": rows,
    "realHomeUnchanged": (log / "real-home-before.txt").read_text()
    == (log / "real-home-after.txt").read_text(),
}
(log / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
ok = report["realHomeUnchanged"] and all(
    r["exit"] == r["expectedExit"]
    and r["lock"] == "free"
    and r["lingering"] == 0
    and r["retryExit"] == 0
    for r in rows
)
sys.exit(0 if ok else 1)
PY

if (( failed )); then
  print -u2 'FAIL: native interruption; see the logs'
  return 1
fi
print -r -- 'PASS: interrupted applies release the lock and complete on retry'

# ============================================================================ #
# End of tests/qualification/native-interruption.zsh
