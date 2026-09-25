#!/usr/bin/env python3

"""Exercise the real Starship/ZLE prompt in a disposable tmux server.

Run explicitly with Python 3, tmux, Starship and Zsh installed. The fixture
does not modify user sessions, history or configuration. It reads the repository
Starship config, or the managed config when run from the deployed Zsh tree.
Set ZSH_PROMPT_RESIZE_STRESS=1 to include the known failure below the width of
the information line.
"""

import os
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

CONFIG_ROOT = Path(__file__).resolve().parents[2]

# --------------------------- Configuration Paths ---------------------------- #


def starship_config_path() -> Path:
    """Resolve the source TOML in the checkout or the deployed user's config.

    Home Manager copies the Zsh unit into the store separately from Starship.
    Resolve the managed fallback before the fixture replaces HOME and XDG paths.

    Returns:
        Path to the Starship configuration exercised by the test.
    """
    source = CONFIG_ROOT.parent.parent / "starship/starship.toml"
    if source.is_file():
        return source
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return Path(os.environ.get("STARSHIP_CONFIG", config_home / "starship.toml"))


# ---------------------------- Prompt Regression ----------------------------- #


@unittest.skipUnless(
    all(shutil.which(tool) for tool in ("tmux", "starship", "zsh")),
    "requires tmux, starship and zsh",
)
class PromptResizeTest(unittest.TestCase):
    """Verify prompt redraws against a terminal with real reflow behavior."""

    def test_resize_preserves_prompt_output_and_pending_command(self) -> None:
        """Preserve one full prompt, prior output and input through pane changes.

        Start the repository's prompt module in an isolated interactive shell,
        then shrink, grow and split its terminal before accepting a command.
        Always stop the private server, including when an assertion fails.
        """
        starship_config = starship_config_path()
        self.assertTrue(starship_config.is_file(), str(starship_config))
        # Nested macOS TMPDIR paths can exceed the Unix socket path limit.
        with tempfile.TemporaryDirectory(prefix="zsh-resize-", dir="/tmp") as directory:
            root = Path(directory)
            work = root / "PROMPT_PROBE"
            work.mkdir()
            # The Docker context only shows in a Docker project.
            (work / "Dockerfile").touch()
            env = {
                key: os.environ[key]
                for key in ("PATH", "LANG", "LC_ALL", "TERMINFO_DIRS", "TMPDIR")
                if key in os.environ
            }
            env.update(
                HOME=str(root),
                ZDOTDIR=str(root),
                XDG_CONFIG_HOME=str(root / "config"),
                XDG_CACHE_HOME=str(root / "cache"),
                XDG_DATA_HOME=str(root / "data"),
                STARSHIP_CONFIG=str(starship_config),
                DOCKER_CONTEXT="RESIZE_RIGHT",
            )
            (root / ".zshrc").write_text(
                "HISTFILE=; SAVEHIST=0\n"
                "source "
                + shlex.quote(str(CONFIG_ROOT / "lib/30-prompt.zsh"))
                + "\nsource "
                + shlex.quote(str(CONFIG_ROOT / "lib/40-vi-mode.zsh"))
                + "\n_init_starship_prompt\n"
                "print -l SENTINEL_{1..5}\n"
            )
            base = [shutil.which("tmux"), "-S", str(root / "socket"), "-f", "/dev/null"]

            def tmux(*args: str) -> str:
                """Run a command against the fixture's private tmux server.

                Args:
                    args: tmux subcommand and its arguments.

                Returns:
                    Captured standard output, including trailing newlines.
                """
                try:
                    return subprocess.check_output(
                        base + list(args),
                        env=env,
                        text=True,
                        stderr=subprocess.PIPE,
                        timeout=10,
                    )
                except subprocess.CalledProcessError as error:
                    self.fail("tmux failed: " + error.stderr)

            def screen() -> str:
                """Capture the test pane and scrollback to expose hidden ghosts."""
                # Include scrollback: checking only the viewport can hide ghosts.
                return tmux("capture-pane", "-p", "-t", pane, "-S", "-")

            def settled() -> str:
                """Return a stable prompt capture or fail after five seconds."""
                deadline = time.monotonic() + 5
                previous = None
                while time.monotonic() < deadline:
                    time.sleep(0.15)
                    current = screen()
                    if current == previous and "PROMPT_PROBE" in current:
                        return current
                    previous = current
                self.fail("prompt did not settle:\n" + (previous or ""))

            def check_display(text: str, pending: str = "") -> None:
                """Assert that redraws preserve the header, output and input.

                Args:
                    text: Captured viewport and scrollback after a redraw.
                    pending: Unsubmitted command expected to remain visible.
                """
                self.assertEqual(text.count("PROMPT_PROBE"), 1, text)
                for index in range(1, 6):
                    self.assertEqual(text.count(f"SENTINEL_{index}"), 1, text)
                if pending:
                    self.assertIn(pending, text)

            try:
                pane = tmux(
                    "new-session",
                    "-d",
                    "-P",
                    "-F",
                    "#{pane_id}",
                    "-s",
                    "resize",
                    "-x",
                    "100",
                    "-y",
                    "24",
                    "-c",
                    str(work),
                    shlex.quote(shutil.which("zsh")) + " -di",
                ).strip()
                initial = settled()
                check_display(initial)
                self.assertIn("RESIZE_RIGHT", initial)
                pending = "echo BUFFER_OK_123456789012345"
                tmux("send-keys", "-t", pane, "-l", pending)
                # A terminal re-wraps any line wider than its new width, and
                # ZLE cannot tell it did. The layout therefore promises resize
                # safety down to the width of its information line, no further.
                header = next(
                    line for line in initial.splitlines() if "PROMPT_PROBE" in line
                )
                narrowest = len(header.rstrip()) + 2
                self.assertLessEqual(narrowest, 60, header)
                sizes = [
                    (60, 24),
                    (110, 24),
                    (max(narrowest, 45), 12),
                    (100, 24),
                ]
                # Keep the unresolved boundary reproducible without confusing
                # it with the original full-width-header regression.
                if os.environ.get("ZSH_PROMPT_RESIZE_STRESS") == "1":
                    sizes.extend(((35, 24), (120, 24), (60, 10), (100, 24)))
                for columns, rows in sizes:
                    tmux(
                        "resize-window",
                        "-t",
                        "resize:0",
                        "-x",
                        str(columns),
                        "-y",
                        str(rows),
                    )
                    current = settled()
                    with self.subTest(columns=columns, rows=rows):
                        check_display(current, pending)
                other = tmux(
                    "split-window",
                    "-d",
                    "-h",
                    "-P",
                    "-F",
                    "#{pane_id}",
                    "-t",
                    pane,
                    "sleep 30",
                ).strip()
                check_display(settled(), pending)
                tmux("kill-pane", "-t", other)
                check_display(settled(), pending)
                tmux("send-keys", "-t", pane, "Enter")
                final = settled()
                # The accepted prompt collapses; there is one full prompt left.
                self.assertEqual(final.count("╭─"), 1, final)
                self.assertIn("\nBUFFER_OK_123456789012345\n", final)
                for index in range(1, 6):
                    self.assertEqual(final.count(f"SENTINEL_{index}"), 1, final)
                # Verify the real Zsh/Starship hooks preserve every pipeline
                # status, not just a synthetic --pipestatus CLI argument.
                tmux("send-keys", "-t", pane, "-l", "false | true")
                tmux("send-keys", "-t", pane, "Enter")
                self.assertIn("[1 | 0]", settled())
            finally:
                subprocess.run(
                    base + ["kill-server"],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                    check=False,
                )


# ------------------------------- Entry Point -------------------------------- #

if __name__ == "__main__":
    unittest.main()
