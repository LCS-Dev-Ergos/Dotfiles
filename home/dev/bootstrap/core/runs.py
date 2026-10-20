"""What each apply leaves behind: its output, its events and its report.

A run is recorded once `apply` or `prune --yes` holds the lock, in
$XDG_STATE_HOME/dev-bootstrap/runs/<UTC timestamp>/: a log per ecosystem,
and per stage for work outside one, with every child's complete output;
`events.jsonl`, the progress events `--events` also streams; and
`report.json`, the report as printed, or what was known when the run failed.
The last ten runs are kept.
"""

import json
import os
import re
import shutil
import time
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from . import process
from .engine import LEGACY_STATE_NAME, STATE_NAME
from .errors import BootstrapError, Interrupted
from .paths import (
    read_json_object,
    renamed_directory,
    root_path,
    writable_directory,
)

KEPT = 10
# The event stream's own version; Interfaces.md says what changes it.
EVENTS_SCHEMA = 1
RUN_ID = re.compile(r"\d{8}T\d{6}Z(-\d+)?")


def runs_directory():
    """Where runs are kept; read in place while an earlier release's
    state directory has not moved yet."""
    home = Path.home()
    state = root_path("XDG_STATE_HOME", home / ".local/state")
    return renamed_directory(state, STATE_NAME, LEGACY_STATE_NAME) / "runs"


def timestamp(seconds):
    return (
        datetime.fromtimestamp(seconds, UTC)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def outcome(code):
    if code == 0:
        return "ok"
    return "interrupted" if code > 128 else "failed"


class Recorder:
    """One run's record, started when the run takes the lock.

    Before that nothing is written: a run refused for its consents or a
    held lock changed nothing worth keeping.
    """

    def __init__(self, command, events=None):
        self.command = command
        self.started = time.time()
        self.directory = None
        self.logs = {}
        # The innermost log a failure passed through: its output explains it.
        self.failed_log = None
        self.files = []
        # Callables given each event as it happens (core.progress).
        self.listeners = []
        if events is not None:
            # A file or a FIFO a frontend reads as the run progresses.
            self.files.append(open(events, "w", encoding="utf-8"))

    def begin(self, state):
        if self.directory is not None:
            return
        runs = state / "runs"
        writable_directory(runs)
        name = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(self.started))
        for attempt in range(1, 100):
            candidate = runs / (name if attempt == 1 else f"{name}-{attempt}")
            try:
                candidate.mkdir(mode=0o700)
            except FileExistsError:
                continue
            self.directory = candidate
            break
        else:
            raise BootstrapError(f"Cannot create a run directory in {runs}")
        self.retain(runs)
        descriptor = os.open(
            self.directory / "events.jsonl",
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        self.files.append(open(descriptor, "w", encoding="utf-8"))
        self.emit(
            "run-start",
            schema=EVENTS_SCHEMA,
            run=self.directory.name,
            command=self.command,
            directory=str(self.directory),
        )

    def retain(self, runs):
        """Remove all but the newest runs; anything else there is left alone."""
        recorded = sorted(
            entry
            for entry in runs.iterdir()
            if RUN_ID.fullmatch(entry.name)
            and entry.is_dir()
            and not entry.is_symlink()
        )
        for entry in recorded[:-KEPT]:
            shutil.rmtree(entry)

    def emit(self, event, **fields):
        record = {"time": timestamp(time.time()), "event": event, **fields}
        line = json.dumps(record)
        for file in self.files:
            file.write(line + "\n")
            file.flush()
        for listener in self.listeners:
            listener(record)

    @contextmanager
    def log(self, name):
        """Copy the block's child output into the run's `name`.log."""
        if self.directory is None:
            yield
            return
        path = self.directory / f"{name}.log"
        try:
            with process.recorded(path):
                yield
        except BaseException:
            if self.failed_log is None and path.exists():
                self.failed_log = str(path)
            raise
        finally:
            if path.exists():
                self.logs[name] = str(path)

    def log_path(self, name):
        return str(self.directory / f"{name}.log") if self.directory else ""

    @contextmanager
    def step(self, kind, *, detail=None, **identity):
        """`<kind>-start` and `<kind>-finish` around the block.

        The finish event repeats the identity, so a reader can pair them,
        and adds the outcome and the duration in seconds.
        """
        started = time.monotonic()
        self.emit(f"{kind}-start", **identity, **(detail or {}))
        result = "ok"
        try:
            yield
        except (KeyboardInterrupt, Interrupted):
            result = "interrupted"
            raise
        except BaseException:
            result = "failed"
            raise
        finally:
            self.emit(
                f"{kind}-finish",
                **identity,
                outcome=result,
                duration=round(time.monotonic() - started, 1),
            )

    def summary(self, code, error=None):
        """The report's `run` field."""
        run = {
            "id": self.directory.name,
            "command": self.command,
            "path": str(self.directory),
            "started": timestamp(self.started),
            "duration": round(time.time() - self.started, 1),
            "exit": code,
            "outcome": outcome(code),
            "logs": dict(sorted(self.logs.items())),
        }
        if error is not None:
            run["error"] = error
            if self.failed_log:
                run["error"]["log"] = self.failed_log
        return run

    def finish(self, result, code, error=None):
        """Persist the report with its `run` field, and end the stream."""
        try:
            if self.directory is not None:
                result["run"] = self.summary(code, error)
                temporary = self.directory / "report.json.tmp"
                temporary.write_text(json.dumps(result, indent=2) + "\n")
                os.replace(temporary, self.directory / "report.json")
            self.emit(
                "run-finish",
                outcome=outcome(code),
                exit=code,
                duration=round(time.time() - self.started, 1),
                **(
                    {"report": str(self.directory / "report.json")}
                    if self.directory is not None
                    else {}
                ),
            )
        finally:
            for file in self.files:
                file.close()
            self.files = []
        return result


def recorded_runs(runs=None):
    """Each kept run, newest first, as the `report` listing shows it."""
    runs = runs or runs_directory()
    if not runs.is_dir():
        return []
    entries = []
    for entry in sorted(runs.iterdir(), reverse=True):
        if (
            not RUN_ID.fullmatch(entry.name)
            or entry.is_symlink()
            or not entry.is_dir()
        ):
            continue
        row = {"id": entry.name, "path": str(entry), "state": "incomplete"}
        report = entry / "report.json"
        if report.is_file():
            run = read_json_object(report).get("run", {})
            if not isinstance(run, dict):
                raise BootstrapError(
                    f"Run metadata must be an object: {report}"
                )
            row.update(
                {
                    key: run[key]
                    for key in ("command", "started", "duration", "exit")
                    if key in run
                },
                state=run.get("outcome", "incomplete"),
            )
        entries.append(row)
    return entries


def stored_report(run_id=None, runs=None):
    """A kept run's report: the named one, or the newest with a report."""
    runs = runs or runs_directory()
    for row in recorded_runs(runs):
        if run_id is not None and row["id"] != run_id:
            continue
        report = Path(row["path"]) / "report.json"
        if report.is_file():
            return read_json_object(report)
        if run_id is not None:
            raise BootstrapError(
                f"Run {run_id} has no report: it is still running, or it "
                "stopped before writing one"
            )
    if run_id is not None:
        raise BootstrapError(f"No kept run is named {run_id}")
    raise BootstrapError(f"No run is recorded in {runs} yet")
