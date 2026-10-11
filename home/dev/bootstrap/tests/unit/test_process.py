"""The process boundary ends a child's whole process group with the call."""

import io
import os
import shutil
import signal
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from core import cli, process
from core.errors import BootstrapError, Interrupted


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


class RecordedOutputTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="bootstrap-log-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / "python.log"

    def test_a_recorded_child_keeps_its_complete_output(self):
        script = "echo out; echo err >&2; exit 3"
        with (
            process.recorded(self.log),
            self.assertRaisesRegex(BootstrapError, "exited 3: err"),
        ):
            process.run(["/bin/sh", "-c", script])
        text = self.log.read_text()
        self.assertTrue(text.startswith(f"$ /bin/sh -c '{script}'\n"))
        self.assertIn("out\n", text)
        self.assertIn("err\n", text)
        self.assertIn("[exit 3 after ", text)
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)

    def test_output_reaches_the_log_while_the_child_runs(self):
        # The child waits until the log shows its first line.
        flag = self.root / "seen"
        script = (
            f'echo first; while [ ! -e "{flag}" ]; do sleep 0.05; done; '
            "echo second"
        )

        def watch():
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.log.exists() and "first" in self.log.read_text():
                    flag.touch()
                    return
                time.sleep(0.05)

        watcher = threading.Thread(target=watch)
        watcher.start()
        with process.recorded(self.log):
            output = process.run(["/bin/sh", "-c", script], timeout=20)
        watcher.join()
        self.assertEqual(output, "first\nsecond")

    def test_a_block_without_children_leaves_no_log(self):
        with process.recorded(self.log):
            pass
        self.assertFalse(self.log.exists())

    def test_output_is_read_as_utf8_with_unified_newlines(self):
        printf = shutil.which("printf")
        output = process.run([printf, "\\377ok\\r\\nnext"])
        self.assertEqual(output, "\ufffdok\nnext")


class AttendedTests(unittest.TestCase):
    def test_only_a_terminal_on_stdin_is_attended(self):
        with patch.object(process.sys, "stdin", io.StringIO()):
            self.assertFalse(process.attended())
        with patch.object(process.sys, "stdin", None):
            self.assertFalse(process.attended())

    def test_authentication_fails_with_its_status(self):
        process.attend(["/bin/sh", "-c", "exit 0"])
        with self.assertRaisesRegex(BootstrapError, "exited 3"):
            process.attend(["/bin/sh", "-c", "exit 3"])


class TerminationTests(unittest.TestCase):
    def test_termination_signals_raise_unless_the_caller_ignores_them(self):
        for signum in (signal.SIGTERM, signal.SIGHUP):
            self.addCleanup(signal.signal, signum, signal.getsignal(signum))
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        with cli.termination():
            self.assertEqual(signal.getsignal(signal.SIGHUP), signal.SIG_IGN)
            with self.assertRaises(Interrupted) as raised:
                os.kill(os.getpid(), signal.SIGTERM)
                time.sleep(1)
        self.assertEqual(raised.exception.signum, signal.SIGTERM)
        self.assertEqual(signal.getsignal(signal.SIGHUP), signal.SIG_IGN)


if __name__ == "__main__":
    unittest.main()
