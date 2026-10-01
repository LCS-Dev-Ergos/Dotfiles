"""Regression checks for the Brew widget's click controller."""

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "sketchybar/helpers/brew_action.sh"


class BrewActionTests(unittest.TestCase):
    def test_click_passes_one_initial_command_not_file_arguments(self):
        """AppKit receives one quoted command, never a positional file."""
        with tempfile.TemporaryDirectory(prefix="brew click '") as tmp:
            root = Path(tmp)
            script = root / "action ' $name.sh"
            script.write_bytes(SCRIPT.read_bytes())
            brew = root / "brew ' $name"
            brew.touch()
            brew.chmod(0o700)
            for button, action in [("left", "outdated"), ("right", "upgrade")]:
                with self.subTest(button=button):
                    result = subprocess.run(
                        [
                            "/bin/bash",
                            "-c",
                            'function /usr/bin/open() { printf "%s\\0" "$@"; }; source "$0" "$@"',
                            str(script),
                            str(brew),
                            "/fixture/statwell",
                            "",
                        ],
                        env={**os.environ, "BUTTON": button},
                        capture_output=True,
                        check=True,
                    )
                    args = result.stdout.decode().rstrip("\0").split("\0")
                    self.assertEqual(args[:4], ["-n", "-a", "Ghostty", "--args"])
                    options = args[4:]
                    self.assertTrue(
                        all(arg.startswith("--") and "=" in arg for arg in options),
                        "AppKit must not receive positional paths as files to open",
                    )
                    commands = [
                        arg.split("=", 1)[1]
                        for arg in options
                        if arg.startswith("--initial-command=")
                    ]
                    self.assertEqual(len(commands), 1)
                    self.assertEqual(
                        shlex.split(commands[0]),
                        ["/bin/bash", str(script), "--run", str(brew), action, "/fixture/statwell", ""],
                    )

    def test_refresh_follows_command_completion(self):
        """The provider refreshes after brew exits, while Brew's status survives."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            done, refreshed = root / "done", root / "refreshed"
            brew = root / "brew"
            brew.write_text(f'#!/bin/sh\nprintf done > "{done}"\nexit 7\n')
            brew.chmod(0o700)
            launchctl = root / "statwell"
            launchctl.write_text(
                '#!/bin/sh\n[ -f "$DONE_PATH" ] || exit 9\n'
                'printf "%s\\n" "$*" > "$REFRESH_PATH"\n'
            )
            launchctl.chmod(0o700)
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT), "--run", str(brew), "upgrade", str(launchctl), str(root / "runtime")],
                env={
                    **os.environ,
                    "PATH": f'{root}:{os.environ.get("PATH", "")}',
                    "DONE_PATH": str(done),
                    "REFRESH_PATH": str(refreshed),
                },
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=5,
                check=False,
            )
            self.assertEqual(result.returncode, 7, "preserve Brew's exit status")
            self.assertEqual(
                refreshed.read_text().strip(),
                f"refresh --provider homebrew --runtime-dir {root / 'runtime'}",
            )


if __name__ == "__main__":
    unittest.main()
