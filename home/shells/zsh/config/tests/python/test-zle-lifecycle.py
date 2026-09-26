#!/usr/bin/env python3

"""Verify prompt/vi widget composition and reloads inside an actual line editor."""

import os
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[2]

# ----------------------------- ZLE Integration ------------------------------ #


@unittest.skipUnless(
    all(shutil.which(tool) for tool in ("tmux", "zsh", "starship")),
    "requires tmux, Zsh and Starship",
)
class ZleLifecycleTest(unittest.TestCase):
    """Exercise the real widget chain with Starship and preexisting hooks."""

    def setUp(self) -> None:
        """Start a private terminal with event counters and the two real modules."""
        temporary = tempfile.TemporaryDirectory(prefix="zle-lifecycle-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.base = ["tmux", "-S", str(self.root / "socket"), "-f", "/dev/null"]
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.root),
            "ZDOTDIR": str(self.root),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "LANG": "en_US.UTF-8",
            "STARSHIP_CONFIG": str(self.root / "starship.toml"),
        }
        # A small real Starship theme isolates hook lifecycle from project scans.
        (self.root / "starship.toml").write_text(
            'format = "LIFECYCLE $character"\nadd_newline = false\n'
            '[character]\nsuccess_symbol = "[INS](green)"\n'
            'error_symbol = "[ERR](red)"\nvimcmd_symbol = "[CMD](yellow)"\n'
        )
        prompt = shlex.quote(str(CONFIG / "lib/30-prompt.zsh"))
        vi = shlex.quote(str(CONFIG / "lib/40-vi-mode.zsh"))
        (self.root / ".zshrc").write_text(
            "HISTFILE=; SAVEHIST=0; FUNCNEST=64\n"
            "_fixture_init() { print init >> $HOME/events; }\n"
            "_fixture_finish() { print finish >> $HOME/events; }\n"
            "_fixture_keymap() { print keymap >> $HOME/events; }\n"
            "zle -N zle-line-init _fixture_init\n"
            "zle -N zle-line-finish _fixture_finish\n"
            "zle -N zle-keymap-select _fixture_keymap\n"
            f"source {prompt}\nsource {vi}\n_init_starship_prompt\n"
        )
        self.addCleanup(self.stop)
        self.tmux(
            "new-session",
            "-d",
            "-s",
            "probe",
            "-x",
            "100",
            "-y",
            "24",
            "-c",
            str(self.root),
            shlex.quote(shutil.which("zsh")) + " -di",
        )
        self.settled()

    def tmux(self, *args: str) -> str:
        """Run one command on the private server and capture its output."""
        return subprocess.check_output(
            self.base + list(args),
            env=self.env,
            text=True,
            stderr=subprocess.PIPE,
            timeout=10,
        )

    def stop(self) -> None:
        """Stop the fixture server even if startup or an assertion fails."""
        subprocess.run(
            self.base + ["kill-server"],
            env=self.env,
            timeout=10,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    def settled(self) -> str:
        """Wait for a stable active prompt and reject hook recursion errors."""
        previous = ""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            time.sleep(0.1)
            current = self.tmux("capture-pane", "-p", "-S", "-")
            self.assertNotIn("maximum nested function", current)
            if current == previous and "LIFECYCLE" in current:
                return current
            previous = current
        self.fail("editor did not settle:\n" + previous)

    def events(self, name: str) -> int:
        """Count one type of observed hook event from the fixture log."""
        event_file = self.root / "events"
        return (
            event_file.read_text().splitlines().count(name)
            if event_file.exists()
            else 0
        )

    def command(self, text: str) -> str:
        """Type and accept a command, then wait for the next prompt."""
        self.tmux("send-keys", "-l", text)
        self.tmux("send-keys", "Enter")
        return self.settled()

    def test_existing_hooks_survive_and_insert_start_does_not_switch_keymap(
        self,
    ) -> None:
        """Preserve third-party hooks and avoid an unnecessary startup redraw."""
        self.assertEqual(self.events("init"), 1)
        self.assertEqual(self.events("keymap"), 0)
        self.command("true")
        self.assertEqual(self.events("finish"), 1)
        self.assertEqual(self.events("init"), 2)
        self.assertEqual(self.events("keymap"), 0)

    def test_repeated_initialization_keeps_one_mode_transition_and_cancellation(
        self,
    ) -> None:
        """Reload both owners, edit in vi mode and cancel without losing hooks."""
        vi = shlex.quote(str(CONFIG / "lib/40-vi-mode.zsh"))
        self.command(
            f"source {vi}; source {vi}; _init_starship_prompt; _init_starship_prompt"
        )
        before = self.events("keymap")
        self.tmux("send-keys", "Escape")
        self.assertIn("LIFECYCLE CMD", self.settled().strip().splitlines()[-1])
        self.assertEqual(self.events("keymap"), before + 1)
        self.tmux("send-keys", "i")
        self.assertIn("LIFECYCLE INS", self.settled().strip().splitlines()[-1])
        self.assertEqual(self.events("keymap"), before + 2)
        self.tmux("send-keys", "-l", "echo SHOULD_NOT_RUN")
        self.tmux("send-keys", "C-c")
        self.assertIn("LIFECYCLE", self.settled().strip().splitlines()[-1])
        self.command("print -r -- alive > $HOME/alive")
        self.assertEqual((self.root / "alive").read_text(), "alive\n")
        # Zsh skips line-finish on send-break; the transient widget handles it.
        self.assertEqual(self.events("finish"), 2)
        self.assertEqual(self.events("init"), 4)

    def test_clipboard_failure_is_reported_without_claiming_success(self) -> None:
        """Keep clipboard failures visible without touching the host clipboard."""
        self.command("clipcopy() { return 1; }")
        self.tmux("send-keys", "C-o")
        screen = self.settled()
        self.assertIn("Clipboard copy failed", screen)
        self.assertNotIn("Copied:", screen)


# ------------------------------- Entry Point -------------------------------- #

if __name__ == "__main__":
    unittest.main()
