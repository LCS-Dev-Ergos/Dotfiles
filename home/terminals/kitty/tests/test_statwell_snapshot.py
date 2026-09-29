"""Contracts for Kitty's direct StatWell reader and asynchronous fallback."""

import fcntl
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "kitty"))
from statwell_snapshot import SnapshotReader, cpu_display, fresh_value


def document(status="ok"):
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
    def test_cpu_display_uses_bounded_system_utilization(self):
        self.assertEqual(cpu_display({"total_percent": 23.6}), ("24%", 0))
        self.assertEqual(cpu_display({"total_percent": 100}), ("100%", 2))
        for value in (-1, 100.1, float("nan"), float("inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                cpu_display({"total_percent": value})

    def test_freshness_and_schema_are_enforced(self):
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
