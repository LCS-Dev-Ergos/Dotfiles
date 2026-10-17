"""Throwaway homes with both VS Code editions in them."""

import contextlib
import dataclasses
import io
import json
import os
import re
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path

import terminal_style as ui

from core.cli import Context, main
from core.host import Edition, Host, Platform
from core.plan import Plan, Snapshot, plan_setup, take_snapshot
from core.transaction import Transaction

STABLE = Edition.STABLE
INSIDERS = Edition.INSIDERS


class Machine:
    """A home directory with Stable and Insiders extensions and user files.

    Extensions get a ``package.json`` that matches their folder name, and
    manifests are written the way VS Code writes them.
    """

    def __init__(
        self, testcase: unittest.TestCase, platform: Platform = Platform.LINUX
    ) -> None:
        temporary = tempfile.TemporaryDirectory()
        testcase.addCleanup(temporary.cleanup)
        self.testcase = testcase
        self.home = Path(temporary.name).resolve() / "home"
        self.home.mkdir()
        env = {
            "PATH": "",
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".local" / "state"),
        }
        self.host = Host(platform, self.home, env)
        self.host.state_home().mkdir(parents=True)
        for edition in Edition:
            self.root(edition).mkdir(parents=True)
            self.host.user_dir(edition).mkdir(parents=True)

    def set_env(self, **values: str) -> None:
        """Replace the host with one whose environment has ``values``."""
        env = {**self.host.env, **values}
        self.host = dataclasses.replace(self.host, env=env)

    def root(self, edition: Edition) -> Path:
        """An edition's extensions directory."""
        return self.host.extensions_dir(edition)

    def extension(
        self,
        edition: Edition,
        extension_id: str,
        version: str,
        platform: str | None = None,
    ) -> str:
        """Install a real extension folder; its name."""
        suffix = f"-{platform}" if platform else ""
        name = f"{extension_id}-{version}{suffix}"
        folder = self.root(edition) / name
        folder.mkdir()
        publisher, package = extension_id.split(".", 1)
        manifest = {
            "publisher": publisher,
            "name": package,
            "version": version,
        }
        (folder / "package.json").write_text(json.dumps(manifest))
        (folder / "extension.js").write_text(f"// {name}\n")
        return name

    def link(self, name: str, target: str | None = None) -> Path:
        """Make Insiders' ``name`` a link to Stable's ``target`` folder."""
        path = self.root(INSIDERS) / name
        path.symlink_to(self.root(STABLE) / (target or name))
        return path

    def entry(
        self,
        edition: Edition,
        folder: str,
        *,
        root: Edition | None = None,
        metadata: dict[str, object] | None = None,
    ) -> dict[str, object]:
        """A manifest entry for ``folder``, located in ``root``'s directory."""
        extension_id, version = _split(folder)
        located = self.root(root or edition) / folder
        entry: dict[str, object] = {
            "identifier": {"id": extension_id, "uuid": "0"},
            "version": version,
            "location": {"$mid": 1, "path": str(located), "scheme": "file"},
            "relativeLocation": folder,
        }
        if metadata is not None:
            entry["metadata"] = metadata
        return entry

    def manifest(
        self,
        edition: Edition,
        entries: Sequence[dict[str, object] | str],
        profile: str | None = None,
    ) -> Path:
        """Write an edition's manifest, the default or a profile's."""
        payload = [
            self.entry(edition, item) if isinstance(item, str) else item
            for item in entries
        ]
        if profile is None:
            path = self.root(edition) / "extensions.json"
        else:
            location = profile.lower()
            self._register(edition, profile, location)
            directory = self.host.user_dir(edition) / "profiles" / location
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / "extensions.json"
        path.write_text(json.dumps(payload, separators=(",", ":")))
        return path

    def read_manifest(
        self, edition: Edition, profile: str | None = None
    ) -> list[dict[str, object]]:
        """An edition's manifest, parsed."""
        if profile is None:
            path = self.root(edition) / "extensions.json"
        else:
            path = (
                self.host.user_dir(edition)
                / "profiles"
                / profile.lower()
                / "extensions.json"
            )
        loaded: list[dict[str, object]] = json.loads(path.read_text())
        return loaded

    def obsolete(self, edition: Edition, *names: str) -> Path:
        """Write an edition's ``.obsolete`` file."""
        path = self.root(edition) / ".obsolete"
        path.write_text(json.dumps(dict.fromkeys(names, True)))
        return path

    def user_file(self, edition: Edition, name: str, text: str) -> Path:
        """Write a user file of an edition."""
        path = self.host.user_dir(edition) / name
        path.write_text(text)
        return path

    def snapshot(self) -> Snapshot:
        """Read the machine."""
        return take_snapshot(self.host)

    def apply(self, plan: Plan) -> list[Path]:
        """Apply a plan as a run would; the kept user files."""
        workspace = self.host.state_dir() / "runs" / "test"
        workspace.mkdir(parents=True)
        transaction = Transaction(workspace, self.host.state_dir() / "kept")
        for operation in plan.operations:
            transaction.apply(operation)
        kept, warnings = transaction.commit()
        self.testcase.assertEqual(warnings, [])
        return kept

    def setup(self) -> Plan:
        """Plan and apply setup; the plan."""
        plan = plan_setup(self.snapshot())
        self.apply(plan)
        return plan

    def tree(self) -> dict[str, str]:
        """Every path below the home, with its content or link text.

        The tool's own state directory is left out.
        """
        state: dict[str, str] = {}
        own = self.host.state_dir()
        for directory, names, files in os.walk(self.home):
            for name in names + files:
                path = Path(directory) / name
                if path == own or own in path.parents:
                    continue
                key = str(path.relative_to(self.home))
                if path.is_symlink():
                    state[key] = f"-> {os.readlink(path)}"
                elif path.is_file():
                    state[key] = path.read_text()
                else:
                    state[key] = "/"
        return state

    def run(
        self,
        *argv: str,
        processes: Sequence[str] = (),
        terminal: bool = False,
    ) -> tuple[int, str, str]:
        """Run the command line; its status, stdout and stderr."""
        context = Context(
            self.host, ui.Style(False), list(processes), terminal
        )
        out, err = io.StringIO(), io.StringIO()
        with (
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            try:
                code = main(list(argv), context)
            except SystemExit as exit_:
                code = int(exit_.code or 0)
        return code, out.getvalue(), err.getvalue()

    def _register(self, edition: Edition, name: str, location: str) -> None:
        """Add a profile to an edition's ``storage.json``."""
        path = self.host.user_dir(edition) / "globalStorage" / "storage.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        data: dict[str, list[dict[str, str]]] = {"userDataProfiles": []}
        if path.exists():
            data = json.loads(path.read_text())
        profiles = data["userDataProfiles"]
        if all(profile["location"] != location for profile in profiles):
            profiles.append({"name": name, "location": location})
        path.write_text(json.dumps(data))


def _split(folder: str) -> tuple[str, str]:
    """The identifier and version of a folder name made by ``extension``."""
    found = re.fullmatch(r"(.+?)-(\d[^-]*)(-.+)?", folder)
    assert found is not None, folder
    return found[1], found[2]
