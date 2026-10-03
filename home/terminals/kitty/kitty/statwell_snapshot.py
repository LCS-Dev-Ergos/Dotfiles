"""Read StatWell's shared snapshot without blocking Kitty's tab-bar redraw."""

import fcntl
import json
import math
import os
import stat
import subprocess
import time
from pathlib import Path

MAX_SNAPSHOT_BYTES = 1 << 20
READ_INTERVAL = 1.0
FALLBACK_INTERVAL = 5.0
FALLBACK_TIMEOUT = 10.0


def cpu_display(value: dict) -> tuple[str, int]:
    """Format the system-wide CPU percentage shared with SketchyBar."""
    percent = float(value["total_percent"])
    if not math.isfinite(percent) or not 0.0 <= percent <= 100.0:
        raise ValueError("invalid CPU percentage")
    return f"{percent:.0f}%", 2 if percent >= 80 else 1 if percent >= 60 else 0


def default_runtime_dir() -> Path:
    base = os.environ.get("TMPDIR" if os.uname().sysname == "Darwin" else "XDG_RUNTIME_DIR")
    return Path(base or "/tmp") / f"statwell-{os.geteuid()}"


def fresh_value(document: dict | None, name: str) -> dict | None:
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        return None
    metrics = document.get("metrics")
    if not isinstance(metrics, dict):
        return None
    record = metrics.get(name)
    if not isinstance(record, dict) or record.get("status") != "ok":
        return None
    value = record.get("value")
    stamped, max_age = record.get("value_at_unix_ms"), record.get("max_age_ms")
    if not isinstance(value, dict) or not isinstance(stamped, int) or not isinstance(max_age, int):
        return None
    now = int(time.time() * 1000)
    if stamped <= 0 or max_age <= 0 or not stamped <= now <= stamped + max_age:
        return None
    return value


class SnapshotReader:
    """Use the daemon file when it is live, else poll a one-shot CLI process."""

    def __init__(self, executable: str, runtime_dir: Path | None = None) -> None:
        self.executable = executable
        self.runtime_dir = runtime_dir or default_runtime_dir()
        self._document = None
        self._last_read = float("-inf")
        self._next_fallback = float("-inf")
        self._process = None
        self._process_started = 0.0
        self._from_daemon = False

    def metric(self, name: str) -> dict | None:
        return fresh_value(self.get(), name)

    def get(self) -> dict | None:
        now = time.monotonic()
        if now - self._last_read < READ_INTERVAL:
            return self._document
        self._last_read = now
        # An absent runtime may be created by the CLI. An existing unsafe
        # runtime must not be handed to that fallback either.
        try:
            runtime = self.runtime_dir.lstat()
        except FileNotFoundError:
            runtime = None
        except OSError:
            self._stop_fallback()
            self._document = None
            self._from_daemon = False
            return None
        if runtime is not None and not self._private(runtime, directory=True):
            self._stop_fallback()
            self._document = None
            self._from_daemon = False
            return None
        document = self._daemon_snapshot()
        if document is not None:
            self._stop_fallback()
            self._document = document
            self._from_daemon = True
            return document
        if self._from_daemon:
            self._document = None
            self._from_daemon = False
        if self._process is not None:
            if self._process.poll() is not None:
                output = self._process.communicate()[0]
                self._process = None
                self._document = self._parse(output)
                self._from_daemon = False
            elif now - self._process_started > FALLBACK_TIMEOUT:
                self._process.kill()
                self._process.communicate()
                self._process = None
                self._document = None
        if self._process is None and now >= self._next_fallback:
            self._next_fallback = now + FALLBACK_INTERVAL
            try:
                self._process = subprocess.Popen(
                    [self.executable, "snapshot", "--runtime-dir", str(self.runtime_dir)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                self._process_started = now
            except OSError:
                self._document = None
        return self._document

    def _daemon_snapshot(self) -> dict | None:
        try:
            directory = os.open(self.runtime_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                if not self._private(os.fstat(directory), directory=True):
                    return None
                fd = os.open("daemon.lock", os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                try:
                    if not self._private(os.fstat(fd)):
                        return None
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        return None  # The daemon has released the lock.
                    except BlockingIOError:
                        pass
                finally:
                    os.close(fd)
                fd = os.open("snapshot.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                try:
                    metadata = os.fstat(fd)
                    if not self._private(metadata) or metadata.st_size > MAX_SNAPSHOT_BYTES:
                        return None
                    return self._parse(os.read(fd, MAX_SNAPSHOT_BYTES + 1))
                finally:
                    os.close(fd)
            finally:
                os.close(directory)
        except OSError:
            return None

    def _stop_fallback(self) -> None:
        if self._process is not None:
            if self._process.poll() is None:
                self._process.kill()
            self._process.communicate()
            self._process = None

    @staticmethod
    def _private(metadata: os.stat_result, *, directory: bool = False) -> bool:
        expected_type = stat.S_ISDIR if directory else stat.S_ISREG
        return (
            expected_type(metadata.st_mode)
            and metadata.st_uid == os.geteuid()
            and not metadata.st_mode & 0o077
            and (directory or metadata.st_nlink == 1)
        )

    @staticmethod
    def _parse(content: str | bytes) -> dict | None:
        try:
            document = json.loads(content)
        except (ValueError, UnicodeDecodeError):
            return None
        if isinstance(document, dict) and document.get("schema_version") == 1:
            return document
        return None
