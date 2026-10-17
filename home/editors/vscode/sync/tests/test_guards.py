"""The guards around a changing run, and VS Code's update command."""

import os
import shutil
import unittest
from pathlib import Path
from unittest.mock import patch

import terminal_style as ui

from core.errors import SyncError
from core.host import Edition, Host, Platform
from core.safety import confirm, locked, running_editions
from core.update import find_command, install_extension, update_extensions
from tests.support import Machine


_TOOLS = os.pathsep.join(
    sorted(
        {
            os.path.dirname(found)
            for found in map(shutil.which, ("env", "mkdir", "sleep"))
            if found
        }
    )
)


def script(directory: Path, name: str, body: str) -> Path:
    """An executable shell script that finds the basic tools on any PATH.

    The tools' directories come from the test's own PATH, since a build
    sandbox has no /usr/bin.
    """
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    header = f'#!/bin/sh\nPATH="${{PATH:+$PATH:}}{_TOOLS}"\n'
    path.write_text(f"{header}{body}\n")
    path.chmod(0o755)
    return path


class RunningTests(unittest.TestCase):
    """Which editions count as running."""

    def test_macos_processes_run_inside_the_bundle(self) -> None:
        """Helpers count; the other edition's bundle does not."""
        host = Host(Platform.DARWIN, Path("/Users/u"))
        lines = [
            "/Applications/Visual Studio Code.app/Contents/Frameworks/"
            "Code Helper.app/Contents/MacOS/Code Helper --type=utility",
            "/usr/bin/vim notes.txt",
        ]
        self.assertEqual(running_editions(host, lines), {Edition.STABLE})
        insiders = [
            "/Applications/Visual Studio Code - Insiders.app/Contents/"
            "MacOS/Code Insiders"
        ]
        self.assertEqual(running_editions(host, insiders), {Edition.INSIDERS})

    def test_linux_processes_run_the_editions_binary(self) -> None:
        """The binary's name decides; an argument named code does not."""
        host = Host(Platform.LINUX, Path("/home/u"))
        lines = [
            "/usr/share/code/code --type=renderer",
            "/opt/visual-studio-code-insiders/code-insiders",
            "/usr/bin/grep code",
        ]
        self.assertEqual(
            running_editions(host, lines), {Edition.STABLE, Edition.INSIDERS}
        )
        self.assertEqual(running_editions(host, lines[2:]), set())

    def test_a_server_runs_while_a_client_is_connected(self) -> None:
        """Its builds' programs count; the tunnel service does not."""
        for platform, home in (
            (Platform.LINUX, Path("/home/u")),
            (Platform.DARWIN, Path("/Users/u")),
        ):
            host = Host(platform, home)
            root = home / ".vscode-server"
            lines = [
                f"{root}/cli/servers/Stable-abc/server/node "
                f"{root}/cli/servers/Stable-abc/server/out/server-main.js",
                f"{root}/bin/abc/node {root}/bin/abc/out/server-main.js",
            ]
            with self.subTest(platform=platform):
                for line in lines:
                    self.assertEqual(
                        running_editions(host, [line]), {Edition.SERVER}
                    )
                tunnel = [f"{root}/code-abc tunnel --accept-server-license"]
                self.assertEqual(running_editions(host, tunnel), set())

    def test_an_unreadable_process_list_counts_as_running(self) -> None:
        """Without ps, the run is refused rather than guessed."""
        machine = Machine(self)
        with (
            patch("core.safety.shutil.which", return_value="/nonexistent/ps"),
            self.assertRaises(SyncError),
        ):
            running_editions(machine.host)


class LockTests(unittest.TestCase):
    """Only one changing run at a time."""

    def test_a_second_run_is_refused(self) -> None:
        """The lock is exclusive and released afterwards."""
        machine = Machine(self)
        state = machine.host.state_dir()
        with locked(state):
            with self.assertRaises(SyncError), locked(state):
                pass
        with locked(state):
            pass
        self.assertEqual(os.stat(state).st_mode & 0o777, 0o700)


class ConfirmTests(unittest.TestCase):
    """Nothing changes without a yes."""

    def test_no_terminal_is_no(self) -> None:
        """Without a terminal the question fails and names --yes."""
        with self.assertRaisesRegex(SyncError, "--yes"):
            confirm("Go?", ui.Style(False), {}, stdin_is_terminal=False)

    def test_line_prompt(self) -> None:
        """Plain output asks on a line; only yes is yes."""
        for answer, expected in (("y", True), ("YES", True), ("", False)):
            with (
                self.subTest(answer=answer),
                patch("builtins.input", return_value=answer),
            ):
                self.assertIs(
                    confirm(
                        "Go?", ui.Style(False), {}, stdin_is_terminal=True
                    ),
                    expected,
                )

    def test_gum_asks_on_a_styled_terminal(self) -> None:
        """Gum's status decides, themed like every shell tool."""
        machine = Machine(self)
        log = machine.home / "gum.log"
        bin_dir = machine.home / "bin"
        script(
            bin_dir,
            "gum",
            f'env > "{log}"; echo "$@" >> "{log}"; exit "$GUM_STATUS"',
        )
        style = ui.Style(True)
        environ = {"PATH": str(bin_dir)}
        for status, expected in (("0", True), ("1", False), ("130", False)):
            with self.subTest(status=status):
                answer = confirm(
                    "Go?",
                    style,
                    {**environ, "GUM_STATUS": status},
                    stdin_is_terminal=True,
                )
                self.assertIs(answer, expected)
        self.assertIn("GUM_CONFIRM_PROMPT_FOREGROUND=6", log.read_text())
        self.assertIn("confirm --default=false -- Go?", log.read_text())
        with self.assertRaises(SyncError):
            confirm(
                "Go?",
                style,
                {**environ, "GUM_STATUS": "2"},
                stdin_is_terminal=True,
            )


class UpdateTests(unittest.TestCase):
    """Running an edition's update command."""

    def setUp(self) -> None:
        """A fake code command on the host's PATH."""
        self.machine = Machine(self)
        self.bin = self.machine.home / "bin"
        self.lines: list[str] = []

    def code(self, body: str) -> Path:
        """Install ``code`` with ``body`` and return it."""
        return script(self.bin, "code", body)

    def test_lines_are_passed_on_and_updates_noted(self) -> None:
        """Lines reach the caller, without Node's deprecation warnings."""
        command = self.code(
            'echo "Updating extensions: a.b, c.d"\n'
            "echo \"Extension 'a.b' v2.0.0 was successfully updated.\"\n"
            "echo '(node:42) [DEP0169] DeprecationWarning: `url.parse()`'\n"
            "echo '(Use `Code --trace-deprecation ...` to show where the "
            "warning was created)'\n"
            'printf "no newline"'
        )
        updated = update_extensions(
            command, self.machine.root(Edition.STABLE), {}, self.lines.append
        )
        self.assertEqual(updated, ("a.b",))
        self.assertEqual(len(self.lines), 3)
        self.assertEqual(self.lines[-1], "no newline")

    def test_arguments_and_environment(self) -> None:
        """The directory is named, and a running editor is not reached."""
        command = self.code('echo "$@"; echo "hook=${VSCODE_IPC_HOOK_CLI-}"')
        root = self.machine.root(Edition.STABLE)
        update_extensions(
            command, root, {"VSCODE_IPC_HOOK_CLI": "/tmp/x"}, self.lines.append
        )
        self.assertEqual(
            self.lines,
            [f"--extensions-dir {root} --update-extensions", "hook="],
        )

    def test_downloads_are_kept_apart(self) -> None:
        """An install names its own user data and extensions directory."""
        command = self.code('echo "$@"')
        stage = self.machine.home / "stage"
        root = install_extension(
            command,
            Edition.INSIDERS,
            stage,
            "a.b",
            {},
            self.lines.append,
            pre_release=True,
        )
        self.assertEqual(root, stage / "extensions")
        self.assertEqual(
            self.lines,
            [
                f"--user-data-dir {stage / 'user'} --extensions-dir {root} "
                "--install-extension a.b --pre-release"
            ],
        )
        with self.assertRaisesRegex(SyncError, "--install-extension a.b@1"):
            install_extension(
                self.code("exit 1"),
                Edition.SERVER,
                stage,
                "a.b@1",
                {},
                self.lines.append,
            )

    def test_failure_and_timeout(self) -> None:
        """A failing or hanging update stops the run."""
        root = self.machine.root(Edition.STABLE)
        with self.assertRaisesRegex(SyncError, "exited 3"):
            update_extensions(self.code("exit 3"), root, {}, self.lines.append)
        with self.assertRaisesRegex(SyncError, "longer than"):
            update_extensions(
                self.code("sleep 5"), root, {}, self.lines.append, timeout=0.5
            )

    def test_the_command_is_found_on_path(self) -> None:
        """Only the host's PATH is searched."""
        self.code("exit 0")
        host = Host(Platform.LINUX, self.machine.home, {"PATH": str(self.bin)})
        self.assertEqual(find_command(host, Edition.STABLE), self.bin / "code")
        self.assertIsNone(find_command(host, Edition.INSIDERS))


if __name__ == "__main__":
    unittest.main()
