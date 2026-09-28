"""Read StatWell's shared snapshot without blocking Kitty's tab-bar redraw."""

import fcntl
import json
import os
import stat
import subprocess
import time
from pathlib import Path

MAX_SNAPSHOT_BYTES = 1 << 20
READ_INTERVAL = 1.0
FALLBACK_INTERVAL = 5.0
FALLBACK_TIMEOUT = 10.0


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
        document = self._daemon_snapshot()
        if document is not None:
            if self._process is not None:
                if self._process.poll() is None:
                    self._process.kill()
                self._process.communicate()
                self._process = None
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
        lock = self.runtime_dir / "daemon.lock"
        try:
            fd = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return None  # The daemon has released the lock.
            except BlockingIOError:
                pass
            finally:
                os.close(fd)
            fd = os.open(self.runtime_dir / "snapshot.json", os.O_RDONLY | os.O_NOFOLLOW)
            try:
                metadata = os.fstat(fd)
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.geteuid()
                    or metadata.st_mode & 0o077
                    or metadata.st_size > MAX_SNAPSHOT_BYTES
                ):
                    return None
                return self._parse(os.read(fd, MAX_SNAPSHOT_BYTES + 1))
            finally:
                os.close(fd)
        except OSError:
            return None

    @staticmethod
    def _parse(content: str | bytes) -> dict | None:
        try:
            document = json.loads(content)
        except (ValueError, UnicodeDecodeError):
            return None
        if isinstance(document, dict) and document.get("schema_version") == 1:
            return document
        return None
