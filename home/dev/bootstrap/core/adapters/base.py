"""The contract every ecosystem adapter implements for the engine and setup.

One subclass owns one native manager: its roots, executable, declared
baseline, global selection and verification. The engine and setup stages
iterate adapters through this interface and never branch on a language.
"""

import os
import re
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import NIX_STORE, native_command, root_path

NIXOS_MARKER = Path("/etc/NIXOS")
# pyenv and rbenv record `system` as a global selection. The host PATH then
# decides which runtime runs, so health reports such selections as external
# instead of executing whatever happens to be found.
SYSTEM_SELECTION = "system"
SELECTION_NAME = r"[A-Za-z0-9][A-Za-z0-9._-]*"


class Adapter:
    """A native ecosystem manager and the runtimes it owns."""

    language = ""
    manager_name = ""
    # Directory below the runtime root that holds one entry per installation.
    runtime_directory = None
    # Missing runtimes compile natively and need the platform SDK.
    compiles = False
    # The manager script is sourced rather than executed (SDKMAN).
    sourced_manager = False

    def __init__(self, context):
        self.context = context
        self.roots = self.resolve_roots()

    @classmethod
    def declared(cls, data):
        """Whether the manifest declares a baseline for this ecosystem."""
        return True

    def resolve_roots(self):
        """Map exported root variables to resolved paths, runtime root first."""
        raise NotImplementedError

    @staticmethod
    def locate(variable, default, *, from_environment=True):
        return root_path(variable, default, from_environment=from_environment)

    @property
    def root(self):
        return next(iter(self.roots.values()))

    @property
    def home(self):
        """Where the manager itself is installed; the runtime root by default."""
        return self.root

    @property
    def recipe(self):
        return self.context.data.get("setup", {})

    def environment(self):
        return {name: str(path) for name, path in self.roots.items()}

    def mutable_directories(self):
        """Directories whose ownership is checked before any apply stage."""
        directories = list(self.roots.values())
        if self.runtime_directory:
            directories.append(self.root / self.runtime_directory)
        return directories

    # Manager -----------------------------------------------------------------

    def manager_candidates(self):
        """Canonical manager locations; None falls back to PATH discovery."""
        raise NotImplementedError

    def manager(self):
        candidates = self.manager_candidates()
        if candidates is None:
            return Path(native_command(self.manager_name))
        for candidate in candidates:
            if candidate.is_file() and (
                self.sourced_manager or os.access(candidate, os.X_OK)
            ):
                if candidate.resolve().is_relative_to(NIX_STORE):
                    raise BootstrapError(
                        f"Native {self.manager_name} resolves into the Nix store: "
                        f"{candidate}"
                    )
                return candidate
        locations = " or ".join(str(candidate) for candidate in candidates)
        raise BootstrapError(
            f"Native {self.manager_name} is unavailable at {locations}"
        )

    def manager_packages(self):
        """Native packages that provide a missing manager."""
        packages = []
        package = self.recipe.get("managers", {}).get(self.language)
        if package:
            packages.append(package)
        if self.language in self.recipe.get("installers", {}):
            packages.extend(self.recipe.get("installerPackages", []))
        return packages

    def acquire(self):
        """Install a missing manager outside the package manager, if needed."""

    def readiness(self):
        raise NotImplementedError

    def check_manager_release(self):
        """Reject a manager older than the release the declared argv relies on."""
        output = process.run([str(self.manager()), "--version"])
        match = re.search(r"[0-9]+\.[0-9]+\.[0-9]+", output)
        minimum = self.context.data["policy"]["managerMinimums"][self.language]
        if not match or tuple(map(int, match.group().split("."))) < tuple(
            map(int, minimum.split("."))
        ):
            raise BootstrapError(
                f"Unsupported native manager: {output}; requires >= {minimum}"
            )

    # Declared baseline -------------------------------------------------------

    def baseline(self):
        """One row per declared runtime identity, with its expected path."""
        raise NotImplementedError

    def row(self, version, path, **fields):
        return {
            "language": self.language,
            "version": version,
            "path": str(path),
            "owner": self.manager_name,
            **fields,
        }

    def prefix(self, row):
        """The installation directory whose presence marks partial work."""
        return Path(row["path"]).parent.parent

    def plan(self):
        """Inspect paths only. Present means installed, not yet validated."""
        rows = []
        for row in self.baseline():
            path = Path(row["path"])
            prefix = self.prefix(row)
            if self.context.backend == "native" and NIXOS_MARKER.exists():
                row.update(
                    state="blocked",
                    reason="NixOS requires the explicit nixpkgs backend",
                )
            elif self.context.backend == "nixpkgs":
                self.context.nix_runtime(row)
            elif path.is_file():
                row["state"] = "present"
            elif prefix is not None and os.path.lexists(prefix):
                row.update(
                    state="conflict",
                    reason="Existing incomplete runtime; manual inspection required",
                )
            else:
                try:
                    self.manager()
                    row["state"] = "missing"
                except BootstrapError as error:
                    row.update(state="blocked", reason=str(error))
            rows.append(row)
        return rows

    def preflight(self, missing):
        """Fail before any installation when a missing runtime cannot be built."""

    def install(self, row):
        raise NotImplementedError

    # Verification ------------------------------------------------------------

    def check_runtime(self, path):
        """Reject a runtime path before executing it."""

    def identity(self, row, path):
        """The runtime's own report of its release."""
        raise NotImplementedError

    def canary(self, row, path, *, complete):
        """Exercise the runtime; complete=False is the release-agnostic check."""
        raise NotImplementedError

    def verify(self, row, *, exact=True):
        """Exact baseline identity, or (exact=False) any working selection.

        Native managers own downgrades as well as upgrades, so health has no
        version floor: it asks whether the selection works.
        """
        path = Path(row["path"])
        self.check_runtime(path)
        identity = self.identity(row, path)
        if exact and identity != row["version"]:
            raise BootstrapError(
                f"{self.language} identity mismatch: "
                f"expected {row['version']}, got {identity}"
            )
        if not re.search(r"[0-9]+\.[0-9]+", identity):
            raise BootstrapError(
                f"Unrecognized {self.language} runtime identity: {identity}"
            )
        self.canary(row, path, complete=exact)
        return identity

    # Global selection --------------------------------------------------------

    def selection(self):
        """The manager's global selection as recorded on disk, or None."""
        raise NotImplementedError

    def installed(self):
        if not self.runtime_directory:
            return []
        container = self.root / self.runtime_directory
        if not container.is_dir():
            return []
        return sorted(
            path.name
            for path in container.iterdir()
            if path.is_dir() and not path.name.startswith(".")
        )

    def selected_runtime(self):
        """The executable of the global selection; None when the host owns it."""
        raise NotImplementedError

    def check_selected(self, path):
        if not path.is_file() or path.resolve().is_relative_to(NIX_STORE):
            raise BootstrapError(
                f"Selected native runtime is unavailable: {path}"
            )

    def selected(self):
        """Resolve global selections without creating state or running them."""
        row = {
            "language": self.language,
            "version": self.context.data["defaults"][self.language],
            "path": "",
            "owner": self.manager_name,
        }
        try:
            self.manager()
            path = self.selected_runtime()
            if path is None:
                row.update(
                    state="external",
                    reason="Global selection delegates to the host system runtime",
                )
                return [row]
            self.check_selected(path)
            row.update(state="present", path=str(path))
        except BootstrapError as error:
            row.update(state="blocked", reason=str(error))
        return [row]

    def initialize_default(self):
        """Set the declared default only when no global selection exists."""
        raise NotImplementedError

    def repair_hooks(self):
        """Recreate missing manager shims or shell hooks without reselecting."""
