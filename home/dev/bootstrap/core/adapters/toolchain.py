"""Managers that install exact toolchains into their own roots.

rustup, GHCup, elan, rbenv, SDKMAN and juliaup share one lifecycle: acquire
the manager, install a declared release through its native interface, select
it only when no global selection exists, and verify the runtime directly.
Probes never launch download-capable proxies.
"""

import hashlib
import os
import re
import tempfile
import tomllib
import urllib.request
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from .base import Adapter

RELEASE = r"[0-9]+\.[0-9]+\.[0-9]+"
IDENTITY = r"[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?"
INSTALLER_LIMIT = 1024 * 1024


class ToolchainAdapter(Adapter):
    identity_arguments = ("--version",)
    release_pattern = RELEASE

    @classmethod
    def declared(cls, data):
        return cls.language in data.get("nativeToolchains", {})

    @classmethod
    def validate_declaration(cls, spec):
        """Reject identifiers before they reach paths, URLs or arguments."""
        if not re.fullmatch(cls.release_pattern, spec["version"]):
            raise BootstrapError("Native toolchains require exact releases")

    @property
    def spec(self):
        return self.context.data["nativeToolchains"][self.language]

    def manager_candidates(self):
        return [self.home / "bin" / self.manager_name]

    def invoke(self, *arguments, timeout=7200):
        return process.run(
            [str(self.manager()), *arguments],
            env=self.recipe.get("buildEnvironment", {}) | self.environment(),
            source_build=True,
            cwd=str(self.context.state),
            timeout=timeout,
        )

    def guard_acquisition(self):
        """Refuse to reinstall a manager over state that needs inspection."""

    def acquire(self):
        """Only apply reaches the network; hash every bounded installer first."""
        try:
            self.manager()
            return
        except BootstrapError:
            if self.language not in self.recipe.get("installers", {}):
                raise
        if self.home.exists() and any(self.home.iterdir()):
            raise BootstrapError(
                "Inspect incomplete native manager root before acquisition: "
                f"{self.home}"
            )
        self.guard_acquisition()
        recipe = self.recipe["installers"][self.language]
        with urllib.request.urlopen(recipe["url"], timeout=60) as response:
            payload = response.read(INSTALLER_LIMIT + 1)
        if (
            len(payload) > INSTALLER_LIMIT
            or hashlib.sha256(payload).hexdigest() != recipe["sha256"]
        ):
            raise BootstrapError(
                f"Native {self.language} installer checksum/size mismatch; "
                "refresh its declaration"
            )
        with tempfile.TemporaryDirectory(
            prefix="native-manager-", dir=self.context.state
        ) as directory:
            script = Path(directory) / "installer"
            script.write_bytes(payload)
            environment = (
                self.recipe.get("buildEnvironment", {})
                | self.environment()
                | recipe.get("environment", {})
            )
            bindings = {**self.environment(), "version": self.spec["version"]}
            process.run(
                [
                    recipe["shell"],
                    str(script),
                    *(
                        part.format_map(bindings)
                        for part in recipe["arguments"]
                    ),
                ],
                env=environment,
                source_build=True,
                cwd=directory,
                timeout=1800,
            )
        self.manager()

    def readiness(self):
        output = self.invoke("--version", timeout=30)
        if not re.search(r"[0-9]+\.[0-9]+", output):
            raise BootstrapError(
                f"Unrecognized native {self.language} manager: {output}"
            )

    # Declared baseline -------------------------------------------------------

    def binary(self, selection=None):
        """The runtime executable for a selection, or for the declaration."""
        raise NotImplementedError

    def baseline(self):
        return [self.row(self.spec["version"], self.binary())]

    def install_arguments(self, row):
        raise NotImplementedError

    def install(self, row):
        self.invoke(*self.install_arguments(row))
        # Some managers only reveal the installed path afterwards (juliaup).
        row["path"] = next(
            installed["path"]
            for installed in self.baseline()
            if installed.get("component") == row.get("component")
        )

    # Verification ------------------------------------------------------------

    def check_runtime(self, path):
        if (
            not path.is_file()
            or not os.access(path, os.X_OK)
            or not path.resolve().is_relative_to(self.root)
        ):
            raise BootstrapError(
                f"Native runtime is unavailable or escapes its root: {path}"
            )
        if path.resolve() == self.manager().resolve():
            raise BootstrapError(
                f"Runtime resolves to a download-capable manager: {path}"
            )

    check_selected = check_runtime

    def runtime_environment(self):
        """What the runtime itself needs; the manager roots by default."""
        return self.environment()

    def identity(self, row, path):
        return self.parse_identity(
            process.run(
                [str(path), *self.identity_arguments],
                env=self.runtime_environment(),
                source_build=True,
                cwd="/",
            )
        )

    def parse_identity(self, output):
        match = re.search(IDENTITY, output)
        if not match:
            raise BootstrapError(
                f"Unrecognized {self.language} runtime identity: {output}"
            )
        return match.group()

    def exercise(self, executable, work, call):
        """Run a small local program and return what it printed."""
        raise NotImplementedError

    def canary(self, row, path, *, complete):
        """Small local compiler/interpreter probes, with no package resolution."""
        environment = (
            self.recipe.get("buildEnvironment", {})
            | self.runtime_environment()
        )
        with tempfile.TemporaryDirectory(prefix="native-canary-") as directory:

            def call(args):
                return process.run(
                    [str(arg) for arg in args],
                    env=environment,
                    source_build=True,
                    cwd=directory,
                    timeout=120,
                )

            output = self.exercise(path, Path(directory), call)
        if output != "bootstrap-ok":
            raise BootstrapError(
                f"{self.language} runtime canary failed: {output}"
            )

    # Global selection --------------------------------------------------------

    def read_selection(self):
        raise NotImplementedError

    def selection(self):
        value = self.read_selection()
        if value is not None and not isinstance(value, str):
            raise BootstrapError(f"Invalid {self.language} global selection")
        return value

    def selected_runtime(self):
        selection = self.selection()
        if not selection:
            raise BootstrapError(f"No global {self.language} selection")
        return self.runtime_for(selection)

    def runtime_for(self, selection):
        """The executable a recorded global selection designates."""
        return self.binary(selection)

    def default_arguments(self):
        raise NotImplementedError

    def initialize_default(self):
        if self.selection() is None:
            self.invoke(*self.default_arguments())


class SettingsToolchain(ToolchainAdapter):
    """rustup and elan record the global toolchain in settings.toml."""

    def read_selection(self):
        settings = self.root / "settings.toml"
        if os.path.lexists(settings) and not settings.is_file():
            raise BootstrapError(
                f"Inspect the existing {self.language} selector file"
            )
        if not settings.is_file():
            return None
        return tomllib.loads(settings.read_text()).get("default_toolchain")


class LinkedToolchain(ToolchainAdapter):
    """GHCup and SDKMAN select a runtime by pointing a link at its prefix."""

    selection_link = ""
    # The selected path, relative to the prefix the link resolves to.
    selection_executable = ""

    def read_selection(self):
        marker = self.root / self.selection_link
        return str(marker.resolve()) if os.path.lexists(marker) else None

    def runtime_for(self, selection):
        return Path(selection) / self.selection_executable
