"""Regression tests for ``brew_action.sh``, the Brew widget's click handler.

A click opens Ghostty with exactly one ``--initial-command`` option, never a
positional path that AppKit could open as a file. The terminal branch then runs
brew and signals ``brew_check`` only after brew returns, even when it fails.
"""

import os
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "sketchybar/helpers/brew_action.sh"

# Stand-in for brew_check: it has the same argv shape for pkill, reports that
# it is ready, waits for SIGUSR1 and exits 0 only if brew had finished by then.
PROVIDER_SOURCE = r"""
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv) {
  sigset_t set;
  sigemptyset(&set);
  sigaddset(&set, SIGUSR1);
  sigprocmask(SIG_BLOCK, &set, NULL);

  FILE* ready = fopen(argv[2], "w");
  fclose(ready);

  int received;
  sigwait(&set, &received);
  return access(argv[3], F_OK) == 0 ? 0 : 9;
}
"""


class BrewActionTests(unittest.TestCase):
    """Click routing and completion signalling of ``brew_action.sh``."""

    def test_click_passes_one_initial_command_not_file_arguments(self):
        """Each button opens Ghostty with a single quoted initial command."""
        # Intercept open in the same Bash process, before sourcing the real
        # helper. No application is launched and no Homebrew command runs.
        with tempfile.TemporaryDirectory(prefix="brew click '") as tmp:
            tmp = Path(tmp)
            script = tmp / "action ' $name.sh"
            script.write_bytes(SCRIPT.read_bytes())
            brew = tmp / "brew ' $name"
            brew.touch()
            brew.chmod(0o700)
            provider = tmp / "provider"
            for button, action in [("left", "outdated"), ("right", "upgrade")]:
                with self.subTest(button=button):
                    result = subprocess.run(
                        [
                            "/bin/bash",
                            "-c",
                            'function /usr/bin/open() { printf "%s\\0" "$@"; }; source "$0" "$@"',
                            str(script),
                            str(brew),
                            str(provider),
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
                        [
                            "/bin/bash",
                            str(script),
                            "--run",
                            str(brew),
                            str(provider),
                            action,
                        ],
                    )

    def test_refresh_follows_command_completion(self):
        """The provider is signalled after brew exits, and brew's status is kept."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = tmp / "provider.c"
            source.write_text(PROVIDER_SOURCE)
            provider = tmp / "brew_check"
            compiler = os.environ.get("CC", "clang")
            subprocess.run([compiler, str(source), "-o", str(provider)], check=True)
            ready, done = tmp / "ready", tmp / "done"
            brew = tmp / "brew"
            brew.write_text(f'#!/bin/sh\nsleep 0.2\nprintf done > "{done}"\nexit 7\n')
            brew.chmod(0o700)
            process = subprocess.Popen(
                [str(provider), "brew_update", str(ready), str(done)]
            )
            try:
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                result = subprocess.run(
                    [
                        "/bin/bash",
                        str(SCRIPT),
                        "--run",
                        str(brew),
                        str(provider),
                        "upgrade",
                    ],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    timeout=5,
                    check=False,
                )
                self.assertEqual(result.returncode, 7, "preserve brew exit status")
                self.assertEqual(
                    process.wait(timeout=3), 0, "refresh must follow completion"
                )
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    unittest.main()
