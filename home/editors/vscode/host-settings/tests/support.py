"""Throwaway machines and the settings text the tests share."""

import dataclasses
import tempfile
import unittest
from pathlib import Path

from core.host import Host, Platform
from core.plan import Plan, build_plan

CRLF_SETTINGS = (
    "{\r\n"
    "  // The editor.\r\n"
    '  "editor.fontSize": 14,\r\n'
    '  "clangd.path": "/etc/profiles/per-user/olduser/bin/clangd", '
    "// stays documented\r\n"
    '  "clangd.arguments": [\r\n'
    '    "--clang-tidy",\r\n'
    "    // Let clangd ask the drivers.\r\n"
    '    "--query-driver=/etc/profiles/per-user/olduser/bin/clang",\r\n'
    "  ],\r\n"
    '  "settingsSync.ignoredSettings": [\r\n'
    '    "editor.fontFamily",\r\n'
    '    "-sonarlint.pathToNodeExecutable",\r\n'
    "  ],\r\n"
    '  "cmake.environment": {\r\n'
    '    "CC": "/etc/profiles/per-user/olduser/bin/clang",\r\n'
    "  },\r\n"
    "  /* trailing */\r\n"
    '  "last": true,\r\n'
    "}\r\n"
)


def make_executable(path: Path) -> Path:
    """Create an executable shell script at ``path``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return path


class Machine:
    """A throwaway home directory with a Nix profile in it."""

    def __init__(
        self, testcase: unittest.TestCase, platform: Platform = Platform.LINUX
    ) -> None:
        temporary = tempfile.TemporaryDirectory()
        testcase.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "home" / "tester"
        self.home.mkdir(parents=True)
        self.profile = self.home / ".nix-profile"
        self.state = self.root / "state"
        gcroots = self.state / "home-manager" / "gcroots"
        self.gcroot = gcroots / "current-home" / "home-path"
        env = {"PATH": "", "XDG_STATE_HOME": str(self.state)}
        self.host = Host(platform, self.home, "tester", env)

    def tool(self, name: str, where: str = ".nix-profile/bin") -> Path:
        """Create an executable ``name`` below the home directory."""
        return make_executable(self.home / where / name)

    def settings(self, text: str, name: str = "settings.json") -> Path:
        """Write a settings file into the machine's root directory."""
        path = self.root / name
        path.write_bytes(text.encode("utf-8"))
        return path

    def set_env(self, **values: str) -> None:
        """Replace the host with one whose environment has ``values``."""
        env = {**self.host.env, **values}
        self.host = dataclasses.replace(self.host, env=env)

    def plan(self, text: str) -> Plan:
        """Plan a run over ``text`` for this machine."""
        return build_plan(self.root / "settings.json", text, self.host)
