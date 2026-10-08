"""Node through FNM, installed from nodejs.org into a staging root."""

import os
import tempfile
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import writable_directory
from .base import Adapter

# fnm records `fnm default system` as a link to this placeholder.
FNM_SYSTEM_TARGET = "/dev/null/installation"


class NodeAdapter(Adapter):
    language = "node"
    manager_name = "fnm"
    runtime_directory = "node-versions"

    def resolve_roots(self):
        data = os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share"
        return {"FNM_DIR": self.locate("FNM_DIR", Path(data) / "fnm")}

    def manager_candidates(self):
        """The canonical command, then FNM's local single-command exposure."""
        if not self.recipe:
            return None
        directory = Path(self.recipe["managerDirectory"])
        return [directory / self.recipe["managers"]["node"], self.root / "fnm"]

    def readiness(self):
        self.check_manager_release()
        writable_directory(self.root)
        link = self.root / "fnm"
        native = self.manager()
        # Existing shell adapters prioritize this single-command directory
        # when native readiness is enabled, without promoting all Homebrew.
        if os.path.lexists(link):
            if link.resolve() != native.resolve():
                raise BootstrapError(
                    f"Conflicting native FNM exposure: {link}"
                )
        else:
            link.symlink_to(native)

    def baseline(self):
        return [
            self.row(
                release,
                self.root
                / "node-versions"
                / f"v{release}"
                / "installation/bin/node",
            )
            for release in self.context.data["node"]["versions"]
        ]

    def prefix(self, row):
        return Path(row["path"]).parents[2]

    def identity(self, row, path):
        return process.run([str(path), "--version"]).removeprefix("v")

    def canary(self, row, path, *, complete):
        process.run([str(path), "-e", "if (1 + 1 !== 2) process.exit(1)"])

    def selection(self):
        alias = self.root / "aliases/default"
        return os.readlink(alias) if alias.is_symlink() else None

    def selected_runtime(self):
        alias = self.root / "aliases/default"
        if not alias.is_symlink():
            raise BootstrapError("No valid FNM default alias")
        if os.readlink(alias) == FNM_SYSTEM_TARGET:
            return None
        executable = alias.resolve() / "bin/node"
        if not executable.is_relative_to(self.root):
            raise BootstrapError("FNM default escapes its runtime root")
        return executable

    def initialize_default(self):
        if os.path.lexists(self.root / "aliases/default"):
            return
        process.run(
            [
                str(self.manager()),
                *self.context.arguments(
                    "nodeDefault",
                    root=str(self.root),
                    version=self.context.data["defaults"]["node"],
                ),
            ],
            env={},
            cwd=str(self.context.state),
        )

    # Installation ------------------------------------------------------------

    def install(self, row):
        """Install into a staging root, verify there, then move into place.

        FNM tags the first release it installs as `default`. Staging keeps
        that alias out of the real root, where defaults are initialized only
        when absent, and an interrupted download leaves no partial release.
        """
        writable_directory(self.root)
        writable_directory(self.root / "node-versions")
        with tempfile.TemporaryDirectory(
            prefix=".devrestore-", dir=self.root
        ) as temporary:
            process.run(
                [
                    str(self.manager()),
                    *self.context.arguments(
                        "nodeInstall",
                        staging=temporary,
                        version=row["version"],
                    ),
                ],
                env={"FNM_COREPACK_ENABLED": "false"},
                timeout=self.context.data["policy"]["timeouts"]["node"],
                cwd=temporary,
            )
            staged = Path(temporary) / "node-versions" / f"v{row['version']}"
            self.verify(dict(row, path=str(staged / "installation/bin/node")))
            target = self.root / "node-versions" / staged.name
            if os.path.lexists(target):
                raise BootstrapError(
                    "Node target appeared during installation; refusing overwrite"
                )
            staged.rename(target)
