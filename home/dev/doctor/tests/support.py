"""Throwaway machines: a temporary home, its own PATH and fake programs."""

import contextlib
import io
import os
import shutil
import tempfile
import unittest
from collections.abc import Callable, Sequence
from datetime import datetime
from pathlib import Path

import terminal_style as ui

from core.cli import Context, doctor_main, toolchain_main
from core.host import Host, Platform

TOOLS = os.pathsep.join(
    sorted(
        {
            os.path.dirname(found)
            for found in map(
                shutil.which, ("cat", "grep", "ln", "sh", "sleep", "touch")
            )
            if found
        }
    )
)
"""Where the basic tools are; a build sandbox has no /usr/bin."""

FROZEN = datetime(2026, 10, 18, 12, 0)
"""The clock every report is drawn at."""


class Machine:
    """A home directory whose PATH holds only the programs a test writes.

    ``bin`` is the first PATH directory; ``env`` is what every lookup and
    child process sees.
    """

    def __init__(
        self, testcase: unittest.TestCase, platform: Platform = Platform.LINUX
    ) -> None:
        temporary = tempfile.TemporaryDirectory()
        testcase.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.platform = platform
        self.env: dict[str, str] = {
            "HOME": str(self.home),
            "PATH": str(self.bin),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
        }

    @property
    def host(self) -> Host:
        """The machine as the tools see it."""
        return Host(self.platform, self.home, dict(self.env), "x86_64", "Arch")

    def tool(
        self, name: str, body: str = "exit 0", directory: Path | None = None
    ) -> Path:
        """A shell script on PATH that finds the basic tools."""
        directory = directory or self.bin
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        header = f'#!/bin/sh\nPATH="${{PATH:+$PATH:}}{TOOLS}"\n'
        path.write_text(f"{header}{body}\n")
        path.chmod(0o755)
        return path

    def prepend(self, directory: Path) -> None:
        """Put a directory first on PATH."""
        self.env["PATH"] = f"{directory}:{self.env['PATH']}"

    def context(self, styled: bool = False, width: int = 100) -> Context:
        """The context the commands run in, at a frozen time."""
        style = ui.Style(styled, width)
        return Context(self.host, style, ui.Style(False), lambda: FROZEN)

    def doctor(
        self, *argv: str, styled: bool = False, width: int = 100
    ) -> tuple[int, str, str]:
        """Run ``dev-doctor``: its status, standard output and error."""
        return self._capture(doctor_main, argv, self.context(styled, width))

    def toolchain(self, *argv: str) -> tuple[int, str, str]:
        """Run ``toolchain``: its status, standard output and error."""
        return self._capture(toolchain_main, argv, self.context())

    def _capture(
        self,
        main: Callable[[Sequence[str], Context], int],
        argv: Sequence[str],
        context: Context,
    ) -> tuple[int, str, str]:
        """Run a command line with its streams captured."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = main(list(argv), context)
            except SystemExit as exit:
                code = int(exit.code or 0)
        return code, out.getvalue(), err.getvalue()
