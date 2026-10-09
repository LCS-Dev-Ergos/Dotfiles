"""The process boundary ends a child's whole process group with the call."""

import os
import signal
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from core import process
from core.errors import BootstrapError


def gone(pid, seconds=10):
    """Whether the process has exited and been reaped within the deadline."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


class ProcessGroupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="bootstrap-process-")
        self.addCleanup(temporary.cleanup)
        self.pidfile = Path(temporary.name) / "worker.pid"

    def worker(self, *, ignore_term=False, seconds=60):
        """A manager stand-in whose own child outlives a plain kill."""
        trap = "trap '' TERM; " if ignore_term else ""
        return [
            "/bin/sh",
            "-c",
            f'{trap}sleep {seconds} & echo $! > "{self.pidfile}"; wait',
        ]

    def worker_pid(self):
        deadline = time.monotonic() + 10
        while not self.pidfile.is_file() or not self.pidfile.read_text():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.05)
        return int(self.pidfile.read_text())

    def test_timeout_stops_the_whole_process_group(self):
        with self.assertRaisesRegex(BootstrapError, "timed out"):
            process.run(self.worker(), timeout=1)
        self.assertTrue(gone(self.worker_pid()))

    def test_interruption_stops_the_whole_process_group(self):
        def interrupt(signum, frame):
            raise KeyboardInterrupt

        previous = signal.signal(signal.SIGALRM, interrupt)
        self.addCleanup(signal.signal, signal.SIGALRM, previous)
        signal.setitimer(signal.ITIMER_REAL, 1)
        self.addCleanup(signal.setitimer, signal.ITIMER_REAL, 0)
        with self.assertRaises(KeyboardInterrupt):
            process.run(self.worker(), timeout=60)
        self.assertTrue(gone(self.worker_pid()))

    def test_a_group_ignoring_sigterm_is_killed_after_the_grace(self):
        with (
            patch.object(process, "GRACE", 0.5),
            self.assertRaisesRegex(BootstrapError, "timed out"),
        ):
            process.run(self.worker(ignore_term=True), timeout=1)
        self.assertTrue(gone(self.worker_pid()))

    def test_a_vanished_group_keeps_the_original_exception(self):
        # macOS reports EPERM for a group that only holds zombies.
        with (
            patch.object(process.os, "killpg", side_effect=PermissionError),
            self.assertRaisesRegex(BootstrapError, "timed out"),
        ):
            process.run(self.worker(seconds=2), timeout=0.5)


if __name__ == "__main__":
    unittest.main()
