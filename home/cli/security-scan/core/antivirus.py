"""The ClamAV layer: the antivirus's signatures, over the whole batch.

``clamscan`` comes from the caller's PATH, since its signature database
belongs to that installation; ``freshclam`` keeps the database current. One
run covers every file, because loading the database takes most of
ClamAV's time. The files go in a private list rather than on the command
line, the output is read line by line for progress, and a watchdog stops
the whole process group when the time runs out or the scan is
interrupted.

A file counts as scanned only when ClamAV reports on it: one it skips,
cannot read or never mentions becomes an error, never a clean result.
"""

import os
import shutil
import signal
import subprocess
import tempfile
import threading
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .findings import Finding, LayerError, Severity

STALE_DAYS = 7
"""A database older than this misses recent threats: ClamAV warns too."""

_CLEAN = ("OK", "Empty file")
_AFTER_FOUND = "Virus(es) detected ERROR"


@dataclass(frozen=True)
class ClamAV:
    """An installed ``clamscan`` with a signature database."""

    command: Path
    version: str
    database: str
    updated: datetime | None

    def stale(self, now: datetime) -> bool:
        """Whether the database is older than STALE_DAYS."""
        if self.updated is None:
            return False
        return (now - self.updated).days > STALE_DAYS


@dataclass
class Outcome:
    """What ClamAV said about each file of a batch."""

    findings: dict[Path, list[Finding]] = field(
        default_factory=dict[Path, list[Finding]]
    )
    clean: set[Path] = field(default_factory=set[Path])
    errors: dict[Path, str] = field(default_factory=dict[Path, str])


def find(environ: Mapping[str, str]) -> tuple[ClamAV | None, str]:
    """The installed ClamAV, or None and why it cannot scan.

    ``clamscan --version`` names the database after the engine
    (``ClamAV 1.5.4/27412/Sat Oct 18 08:12:00 2026``); without one it prints
    the engine alone, and a scan would fail on every file.
    """
    command = shutil.which("clamscan", path=environ.get("PATH", ""))
    if command is None:
        return None, "Not installed"
    try:
        result = subprocess.run(
            [command, "--version"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            errors="replace",
            env={**environ, "LC_ALL": "C"},
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, f"Cannot run clamscan: {error}"
    line = result.stdout.strip()
    if result.returncode != 0 or not line.startswith("ClamAV "):
        return None, f"Cannot run clamscan: {line or 'no version printed'}"
    engine, _, rest = line.removeprefix("ClamAV ").partition("/")
    database, _, stamp = rest.partition("/")
    if not database:
        return None, "No signature database"
    try:
        updated = datetime.strptime(stamp.strip(), "%a %b %d %H:%M:%S %Y")
    except ValueError:
        updated = None
    return ClamAV(Path(command), engine, database, updated), ""


def scan(
    clamav: ClamAV,
    files: Sequence[Path],
    environ: Mapping[str, str],
    progress: Callable[[int], None] = lambda done: None,
    timeout: float | None = None,
) -> Outcome:
    """Scan files in one run; ``progress`` hears how many are done.

    The default time limit allows for loading the database and a generous
    share per file.

    Raises:
        LayerError: If clamscan fails before reporting on any file, or runs
            out of time.
    """
    outcome = Outcome()
    names: dict[str, Path] = {}
    for path in files:
        if "\n" in str(path):
            outcome.errors[path] = (
                "ClamAV cannot take a name with a line break"
            )
        else:
            names[str(path)] = path
    if not names:
        return outcome
    limit = timeout if timeout is not None else 300 + 30 * len(names)
    with tempfile.TemporaryDirectory(prefix="security-scan.") as private:
        listing = Path(private, "files")
        listing.write_bytes(b"".join(os.fsencode(n) + b"\n" for n in names))
        errors = Path(private, "stderr")
        status, expired = _run(
            clamav, listing, errors, environ, limit, names, outcome, progress
        )
        message = errors.read_bytes().decode(errors="replace").strip()
    if expired:
        raise LayerError(f"ClamAV took longer than {limit:.0f} s")
    reported = outcome.clean | outcome.findings.keys() | outcome.errors.keys()
    if status not in (0, 1) and not reported & set(names.values()):
        detail = message.splitlines()[-1] if message else f"status {status}"
        raise LayerError(f"ClamAV failed: {detail}")
    for path in names.values():
        if path not in reported:
            outcome.errors[path] = "ClamAV did not report on this file"
    return outcome


def _run(
    clamav: ClamAV,
    listing: Path,
    errors: Path,
    environ: Mapping[str, str],
    limit: float,
    names: Mapping[str, Path],
    outcome: Outcome,
    progress: Callable[[int], None],
) -> tuple[int, bool]:
    """Run clamscan over the listing; its status and whether time ran out.

    ``--alert-exceeds-max`` makes a file ClamAV only partly scanned, because
    of its size limits, say so instead of passing as clean.
    """
    command = [
        str(clamav.command),
        "--no-summary",
        "--alert-exceeds-max=yes",
        f"--file-list={listing}",
    ]
    expired = threading.Event()
    with errors.open("wb") as sink:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=sink,
            env={**environ, "LC_ALL": "C"},
            start_new_session=True,
        )

    def stop() -> None:
        """Stop a scan that ran out of time."""
        if process.poll() is None:
            expired.set()
            _kill(process)

    watchdog = threading.Timer(limit, stop)
    watchdog.daemon = True
    watchdog.start()
    try:
        assert process.stdout is not None
        done = 0
        for raw in process.stdout:
            if _record(os.fsdecode(raw.rstrip(b"\n")), names, outcome):
                done += 1
                progress(done)
        status = process.wait()
    finally:
        watchdog.cancel()
        if process.poll() is None:
            _kill(process)
        if process.stdout is not None:
            process.stdout.close()
    return status, expired.is_set()


def _kill(process: subprocess.Popen[bytes]) -> None:
    """Stop clamscan and anything it started, then reap it."""
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def _record(line: str, names: Mapping[str, Path], outcome: Outcome) -> bool:
    """Note one output line; whether it was a file's first verdict.

    Lines read ``<path>: <result>``. The path is the one given, so it is
    looked up whole, and a name that itself holds ``: `` still matches.
    """
    text, separator, result = line.rpartition(": ")
    path = names.get(text) if separator else None
    if path is None:
        return False
    first = not (
        path in outcome.clean
        or path in outcome.findings
        or path in outcome.errors
    )
    if result in _CLEAN:
        outcome.clean.add(path)
    elif result.endswith(" FOUND"):
        signature = result.removesuffix(" FOUND")
        outcome.findings.setdefault(path, []).append(_finding(signature))
    elif result == _AFTER_FOUND and path in outcome.findings:
        return False
    else:
        outcome.errors[path] = f"ClamAV: {result.removesuffix(' ERROR')}"
    return first


def _finding(signature: str) -> Finding:
    """A signature match as a finding.

    ClamAV reports its size limits as a match too; that only says part of
    the file went unchecked. Heuristic matches are likelier to be false
    alarms than signatures.
    """
    detail: dict[str, object] = {"signature": signature}
    if signature.startswith("Heuristics.Limits.Exceeded"):
        return Finding(
            "clamav",
            Severity.INFO,
            "Was only partly scanned by ClamAV: it exceeds a size limit",
            detail,
        )
    if signature.startswith("Heuristics."):
        return Finding(
            "clamav",
            Severity.WARNING,
            f"Trips a ClamAV heuristic: {signature}",
            detail,
        )
    return Finding(
        "clamav",
        Severity.CRITICAL,
        f"Matches the ClamAV signature {signature}",
        detail,
    )
