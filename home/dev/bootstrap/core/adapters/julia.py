"""Julia through juliaup, whose JSON state maps channels to installed paths."""

import os
from pathlib import Path

from ..errors import BootstrapError
from ..paths import read_json_object
from .toolchain import ToolchainAdapter


class JuliaAdapter(ToolchainAdapter):
    language = "julia"
    manager_name = "juliaup"
    runtime_directory = "juliaup"
    identity_arguments = (
        "--startup-file=no",
        "--history-file=no",
        "-e",
        "print(VERSION)",
    )

    def resolve_roots(self):
        home = Path.home()
        return {
            "JULIAUP_DEPOT_PATH": self.locate(
                "JULIAUP_DEPOT_PATH", home / ".julia"
            ),
            "JULIAUP_HOME": self.locate("JULIAUP_HOME", home / ".juliaup"),
        }

    @property
    def home(self):
        return self.roots["JULIAUP_HOME"]

    def config(self):
        path = self.root / "juliaup/juliaup.json"
        if os.path.lexists(path) and not path.is_file():
            raise BootstrapError("Inspect the existing Julia selector file")
        data = read_json_object(path) if path.is_file() else {}
        for field in ("InstalledVersions", "InstalledChannels"):
            entries = data.get(field, {})
            if not isinstance(entries, dict) or any(
                not isinstance(entry, dict) for entry in entries.values()
            ):
                raise BootstrapError(
                    f"Invalid Julia selector mapping: {field}"
                )
        for entry in data.get("InstalledVersions", {}).values():
            if not any(
                isinstance(entry.get(key), str)
                for key in ("Path", "BinaryPath")
            ):
                raise BootstrapError("Julia runtime has no declared path")
            if any(
                key in entry and not isinstance(entry[key], str)
                for key in ("Path", "BinaryPath")
            ):
                raise BootstrapError("Invalid Julia runtime path")
        return data

    def binary(self, selection=None, *, channel=None):
        """The installed runtime for a release identity or a channel."""
        data = self.config()
        identity = selection or self.spec["version"]
        if channel:
            identity = (
                data.get("InstalledChannels", {})
                .get(channel, {})
                .get("Version")
            )
            if not identity:
                raise BootstrapError(
                    f"Julia channel has no installed release: {channel}"
                )
        for release, entry in data.get("InstalledVersions", {}).items():
            if release == identity or release.split("+", 1)[0] == identity:
                relative = (
                    entry["BinaryPath"]
                    if "BinaryPath" in entry
                    else str(Path(entry["Path"]) / "bin/julia")
                )
                path = self.root / "juliaup" / relative
                if "BinaryPath" not in entry and not path.is_file():
                    prefix = self.root / "juliaup" / entry["Path"]
                    bundles = list(
                        prefix.glob(
                            "Julia-*.app/Contents/Resources/julia/bin/julia"
                        )
                    )
                    if len(bundles) == 1:
                        path = bundles[0]
                if not path.resolve().is_relative_to(self.root):
                    raise BootstrapError(
                        "Julia runtime escapes its native root"
                    )
                return path
        return self.root / "juliaup" / f"missing-{identity}" / "bin/julia"

    def prefix(self, row):
        # juliaup reports installations through its JSON state, not directories.
        return None

    def installed(self):
        return sorted(self.config().get("InstalledVersions", {}))

    def read_selection(self):
        return self.config().get("Default")

    def runtime_for(self, selection):
        return self.binary(channel=selection)

    def guard_acquisition(self):
        if self.config().get("Default") is not None:
            raise BootstrapError(
                "Inspect existing Julia selection before reinstalling its manager"
            )

    def install_arguments(self, row):
        return ["add", row["version"]]

    def default_arguments(self):
        return ["default", self.spec["version"]]

    def exercise(self, executable, work, call):
        return call(
            [
                executable,
                "--startup-file=no",
                "--history-file=no",
                "-e",
                '@assert 1+1==2; print("bootstrap-ok")',
            ]
        )
