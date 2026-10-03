"""Contracts for Kitty's direct StatWell reader and asynchronous fallback."""

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "kitty"))
from statwell_snapshot import MAX_SNAPSHOT_BYTES, SnapshotReader, cpu_display, fresh_value


def document(status="ok"):
    """Return a fresh schema-v1 CPU snapshot with the requested metric status."""
    return {
        "schema_version": 1,
        "metrics": {
            "cpu": {
                "status": status,
                "value_at_unix_ms": int(time.time() * 1000),
                "max_age_ms": 6000,
                "value": {"total_percent": 25.0},
            }
        },
    }


class SnapshotReaderTests(unittest.TestCase):
    """Check private daemon reads, bounded values and fallback process lifetime."""

    def test_runtime_becoming_unsafe_reaps_pending_fallback(self):
        """Kill and reap an active fallback after its private runtime becomes shared."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            executable = root / "statwell"
            executable.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n")
            executable.chmod(0o700)
            reader = SnapshotReader(str(executable), runtime)
            self.assertIsNone(reader.get())
            process = reader._process
            self.assertIsNotNone(process)
            try:
                runtime.chmod(0o777)
                reader._last_read = float("-inf")
                self.assertIsNone(reader.get())
                self.assertIsNone(reader._process)
                self.assertIsNotNone(process.poll())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_unsafe_runtime_does_not_start_fallback(self):
        """Reject shared or symlinked runtime roots before spawning the CLI fallback."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.chmod(0o777)
            reader = SnapshotReader("/missing/statwell", root)
            self.assertIsNone(reader.get())
            self.assertIsNone(reader._process)
            root.chmod(0o700)
            alias = root / "alias"
            alias.symlink_to(root, target_is_directory=True)
            reader = SnapshotReader("/missing/statwell", alias)
            self.assertIsNone(reader.get())
            self.assertIsNone(reader._process)

    def test_unsafe_snapshot_and_lock_rejected_without_blocking(self):
        """Reject FIFO, link and permission violations before reading daemon files.

        Keep a real daemon lock for snapshot cases and use a subprocess watchdog
        so the original FIFO hang becomes a test failure, not a blocked runner.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.chmod(0o700)
            lock, snapshot = root / "daemon.lock", root / "snapshot.json"
            lock.touch(mode=0o600)
            snapshot.write_text(json.dumps(document()))
            snapshot.chmod(0o600)
            fd = os.open(lock, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                # A separate process and timeout catch the original FIFO
                # hang instead of hanging the regression test runner.
                code = (
                    "import sys; from pathlib import Path; "
                    f"sys.path.insert(0, {str(Path(__file__).parents[1] / 'kitty')!r}); "
                    "from statwell_snapshot import SnapshotReader; "
                    "assert SnapshotReader('/missing/statwell', Path(sys.argv[1]))._daemon_snapshot() is None"
                )
                for kind in ("fifo", "symlink", "hardlink", "shared", "oversize"):
                    with self.subTest(kind=kind):
                        snapshot.unlink()
                        if kind == "fifo":
                            os.mkfifo(snapshot, 0o600)
                        elif kind == "symlink":
                            snapshot.symlink_to(lock)
                        elif kind == "hardlink":
                            snapshot.hardlink_to(lock)
                        else:
                            snapshot.write_bytes(b"x" * (MAX_SNAPSHOT_BYTES + 1) if kind == "oversize" else b"{}")
                            snapshot.chmod(0o666 if kind == "shared" else 0o600)
                        subprocess.run([sys.executable, "-c", code, str(root)], check=True, timeout=3)
                snapshot.unlink()
            finally:
                os.close(fd)
            for kind in ("fifo", "symlink", "hardlink", "shared"):
                with self.subTest(lock=kind):
                    lock.unlink()
                    extra = root / "extra"
                    if extra.exists():
                        extra.unlink()
                    if kind == "fifo":
                        os.mkfifo(lock, 0o600)
                    elif kind == "symlink":
                        lock.symlink_to(extra)
                    elif kind == "hardlink":
                        extra.touch(mode=0o600)
                        lock.hardlink_to(extra)
                    else:
                        lock.touch(mode=0o666)
                        lock.chmod(0o666)
                    subprocess.run([sys.executable, "-c", code, str(root)], check=True, timeout=3)

    def test_cpu_display_uses_bounded_system_utilization(self):
        """Format valid utilization and reject non-finite or out-of-range samples."""
        self.assertEqual(cpu_display({"total_percent": 23.6}), ("24%", 0))
        self.assertEqual(cpu_display({"total_percent": 100}), ("100%", 2))
        for value in (-1, 100.1, float("nan"), float("inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                cpu_display({"total_percent": value})

    def test_freshness_and_schema_are_enforced(self):
        """Expose fresh metrics only from supported schemas and successful samples."""
        value = document()
        self.assertEqual(fresh_value(value, "cpu"), {"total_percent": 25.0})
        value["metrics"]["cpu"]["status"] = "error"
        self.assertIsNone(fresh_value(value, "cpu"))
        value["metrics"]["cpu"]["status"] = "ok"
        value["metrics"]["cpu"]["value_at_unix_ms"] = 1
        self.assertIsNone(fresh_value(value, "cpu"))
        value["schema_version"] = 2
        self.assertIsNone(fresh_value(value, "cpu"))
        self.assertIsNone(fresh_value({"schema_version": 1, "metrics": []}, "cpu"))

    def test_reads_live_daemon_without_spawning(self):
        """Read a private snapshot under a held daemon lock without CLI fallback."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.chmod(0o700)
            lock = root / "daemon.lock"
            lock.touch(mode=0o600)
            snapshot = root / "snapshot.json"
            snapshot.write_text(json.dumps(document()))
            snapshot.chmod(0o600)
            fd = os.open(lock, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                reader = SnapshotReader("/missing/statwell", root)
                self.assertEqual(reader.metric("cpu"), {"total_percent": 25.0})
                self.assertIsNone(reader._process)
            finally:
                os.close(fd)

    def test_missing_daemon_uses_background_one_shot(self):
        """Start a non-blocking CLI fallback and collect its snapshot on a later poll."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = root / "statwell"
            executable.write_text(
                "#!/bin/sh\ncat <<'SNAPSHOT'\n"
                + json.dumps(document())
                + "\nSNAPSHOT\n"
            )
            executable.chmod(0o700)
            reader = SnapshotReader(str(executable), root / "absent")
            self.assertIsNone(reader.metric("cpu"))
            self.assertIsNotNone(reader._process, "first read starts a background process")
            reader._process.wait(timeout=3)
            reader._last_read = float("-inf")
            self.assertEqual(reader.metric("cpu"), {"total_percent": 25.0})

    def test_daemon_replaces_and_reaps_completed_fallback(self):
        """Prefer a newly available daemon and reap the completed one-shot process."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = root / "statwell"
            executable.write_text("#!/bin/sh\nprintf '{}\\n'\n")
            executable.chmod(0o700)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            reader = SnapshotReader(str(executable), runtime)
            self.assertIsNone(reader.metric("cpu"))
            reader._process.wait(timeout=3)

            lock = runtime / "daemon.lock"
            lock.touch(mode=0o600)
            snapshot = runtime / "snapshot.json"
            snapshot.write_text(json.dumps(document()))
            snapshot.chmod(0o600)
            fd = os.open(lock, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                reader._last_read = float("-inf")
                self.assertEqual(reader.metric("cpu"), {"total_percent": 25.0})
                self.assertIsNone(reader._process)
            finally:
                os.close(fd)

    def test_daemon_stops_running_fallback_immediately(self):
        """Stop and reap a sleeping fallback as soon as a valid daemon takes over."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = root / "statwell"
            executable.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n")
            executable.chmod(0o700)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            reader = SnapshotReader(str(executable), runtime)
            self.assertIsNone(reader.metric("cpu"))
            process = reader._process
            self.assertIsNotNone(process)

            lock = runtime / "daemon.lock"
            lock.touch(mode=0o600)
            snapshot = runtime / "snapshot.json"
            snapshot.write_text(json.dumps(document()))
            snapshot.chmod(0o600)
            fd = os.open(lock, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                reader._last_read = float("-inf")
                self.assertEqual(reader.metric("cpu"), {"total_percent": 25.0})
                self.assertIsNone(reader._process)
                self.assertIsNotNone(process.poll())
            finally:
                os.close(fd)
                if process.poll() is None:
                    process.kill()
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
