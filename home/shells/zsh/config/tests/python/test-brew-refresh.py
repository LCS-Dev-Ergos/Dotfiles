#!/usr/bin/env python3

"""Verify Homebrew mutations invalidate StatWell without changing Brew's status.

The real package-management module runs in a clean Zsh process. Executable
fixtures replace Brew, StatWell and SketchyBar, so checks cannot update the
host's packages, contact its daemon, or change its bar. A shared call log checks
that provider refresh follows command completion, including partial failures.

Usage: python3 test-brew-refresh.py [path/to/package-management.zsh]
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

# --------------------------- Configuration Paths ---------------------------- #

module = (
    Path(sys.argv[1])
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[2] / "functions/package-management.zsh"
)

# --------------------------- Executable Fixtures ---------------------------- #

with tempfile.TemporaryDirectory(prefix="brew-refresh-") as directory:
    root = Path(directory)
    log = root / "calls"
    argv_log = root / "arguments"
    env = dict(
        os.environ,
        PATH=str(root) + ":/usr/bin:/bin",
        CALLS=str(log),
        BREW_ARGS=str(argv_log),
        PLATFORM="macOS",
        ZSH_CONFIG_DIR=str(root),
    )
    # Brew and refresh failures are independently selectable. Keeping the old
    # SketchyBar command available makes an obsolete brew_update notification
    # visible in the log instead of hiding it behind a missing executable.
    for name, body in {
        "brew": (
            'printf "%s\\n" "$@" > "$BREW_ARGS"; '
            'printf "brew:%s\\n" "$*" >> "$CALLS"; exit "${BREW_RC:-0}"'
        ),
        "statwell": 'printf "statwell:%s\\n" "$*" >> "$CALLS"; exit "${REFRESH_RC:-0}"',
        "sketchybar": 'printf "sketchybar:%s\\n" "$*" >> "$CALLS"',
    }.items():
        path = root / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o700)

    def run(arguments, brew_rc=0, refresh_rc=0):
        """Invoke the wrapper, preserve its exit status and return ordered calls.

        Args:
            arguments: Homebrew arguments passed through the real wrapper.
            brew_rc: Exit status supplied by the Brew executable fixture.
            refresh_rc: Exit status supplied by the StatWell fixture.

        Returns:
            Executable calls in their observed order.
        """
        log.write_text("")
        response = subprocess.run(
            ["/bin/zsh", "-dfc", 'source "$1"; shift; brew "$@"', "test", str(module), *arguments],
            env=dict(env, BREW_RC=str(brew_rc), REFRESH_RC=str(refresh_rc)),
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert response.returncode == brew_rc, (arguments, response, log.read_text())
        assert not response.stdout and not response.stderr, response
        # Log each argument separately so words with spaces cannot be split
        # unnoticed by the human-readable command log above.
        assert argv_log.read_text().splitlines() == arguments, arguments
        return log.read_text().splitlines()

    # ------------------------- Mutation Regression -------------------------- #

    # Every inventory or metadata mutation requests one refresh after Brew.
    for command in ("update", "upgrade", "install", "reinstall", "uninstall", "remove", "rm", "autoremove", "cleanup", "tap", "untap", "pin", "unpin", "link", "unlink"):
        calls = run([command, "package with spaces"])
        assert calls == [f"brew:{command} package with spaces", "statwell:refresh --provider homebrew"], (command, calls)
    # Read-only commands reuse the daemon's cadence instead of starting checks.
    for arguments in (["outdated"], ["info", "foo"], ["search", "foo"], ["--version"]):
        assert len(run(arguments)) == 1, arguments
    # Global options must not hide the mutation subcommand from the wrapper.
    assert run(["--verbose", "upgrade"])[-1] == "statwell:refresh --provider homebrew"

    # -------------------------- Failure Regression -------------------------- #

    # A partially failed upgrade can still change installed packages. Refresh
    # failures must never change Brew's status or leak diagnostics to its user.
    assert run(["upgrade"], brew_rc=7)[-1] == "statwell:refresh --provider homebrew", "partial failures also invalidate the count"
    assert run(["update"], refresh_rc=1)[-1] == "statwell:refresh --provider homebrew", "daemon failure must preserve brew status"
    # The wrapper remains usable when the optional StatWell command is absent.
    (root / "statwell").unlink()
    assert len(run(["upgrade"])) == 1, "Homebrew must still work without StatWell"
print("PASS: Homebrew mutation refresh, argv, failures, and absent daemon")
