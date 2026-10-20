"""Child processes: output, missing programs and timeouts."""

import contextlib
import os
import time
import unittest

from core import process
from tests.support import Machine


class RunTests(unittest.TestCase):
    """``process.run``."""

    def setUp(self) -> None:
        """An empty machine."""
        self.machine = Machine(self)

    def test_output_and_status(self) -> None:
        """Standard output is kept; standard error only on request."""
        tool = self.machine.tool("t", "echo out; echo err >&2; exit 3")
        quiet = process.run([str(tool)], self.machine.env, 5)
        self.assertEqual((quiet.status, quiet.output), (3, "out\n"))
        loud = process.run([str(tool)], self.machine.env, 5, errors=True)
        self.assertIn("err", loud.output)

    def test_a_missing_program_is_not_runnable(self) -> None:
        """A program that cannot start is reported, not raised."""
        outcome = process.run(["/missing/program"], self.machine.env, 5)
        self.assertEqual(outcome.status, process.NOT_RUNNABLE)
        self.assertEqual(process.run([], {}, 5).status, process.NOT_RUNNABLE)

    def test_standard_input_is_empty(self) -> None:
        """Nothing can wait for a person."""
        tool = self.machine.tool("t", "cat; echo done")
        outcome = process.run([str(tool)], self.machine.env, 5)
        self.assertEqual(outcome.output, "done\n")

    def test_relative_path_entries_cannot_select_a_program(self) -> None:
        """Direct and nested lookups use only absolute PATH directories."""
        project = self.machine.root / "project"
        project.mkdir()
        marker = project / "executed"
        self.machine.tool("cc", "echo trusted")
        launcher = self.machine.tool("launcher", "exec cc --version")
        self.machine.tool("cc", f'touch "{marker}"; echo project', project)
        self.machine.tool("cc", f'touch "{marker}"', project / "tools")
        with contextlib.chdir(project):
            for entry in ("", ".", "tools"):
                env = {**self.machine.env}
                env["PATH"] = f"{entry}:{self.machine.bin}"
                for argv in (("cc", "--version"), (str(launcher),)):
                    with self.subTest(entry=entry, argv=argv):
                        result = process.run(argv, env, 5)
                        self.assertEqual(result.output, "trusted\n")
                        self.assertFalse(marker.exists())
            for path in ("", ".", "tools"):
                env = {**self.machine.env, "PATH": path}
                self.assertEqual(
                    process.run(("cc",), env, 5).status,
                    process.NOT_RUNNABLE,
                )
                self.assertFalse(marker.exists())

    def test_a_timeout_ends_the_whole_group(self) -> None:
        """A grandchild that ignores TERM is killed with its parent."""
        pid_file = self.machine.root / "pid"
        tool = self.machine.tool(
            "t",
            f'sh -c \'trap "" TERM; echo $$ > "{pid_file}"; sleep 30\' &\n'
            "sleep 30",
        )
        started = time.monotonic()
        outcome = process.run([str(tool)], self.machine.env, 0.5)
        self.assertTrue(outcome.timed_out)
        self.assertLess(time.monotonic() - started, 5)
        grandchild = int(pid_file.read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and _alive(grandchild):
            time.sleep(0.05)
        self.assertFalse(_alive(grandchild))

    def test_children_cannot_download(self) -> None:
        """rustup's automatic installs and .NET telemetry are off."""
        tool = self.machine.tool(
            "t", 'echo "$RUSTUP_AUTO_INSTALL $DOTNET_CLI_TELEMETRY_OPTOUT"'
        )
        outcome = process.run([str(tool)], self.machine.env, 5)
        self.assertEqual(outcome.output, "0 1\n")


def _alive(pid: int) -> bool:
    """Whether a process exists and is not a zombie."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


if __name__ == "__main__":
    unittest.main()
