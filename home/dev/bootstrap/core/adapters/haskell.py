"""GHC and Cabal through GHCup; installation and selection are separate."""

import os
import re
from pathlib import Path

from ..errors import BootstrapError
from .toolchain import LinkedToolchain


class HaskellAdapter(LinkedToolchain):
    language = "haskell"
    manager_name = "ghcup"
    runtime_directory = "ghc"
    selection_link = "bin/ghc"
    identity_arguments = ("--numeric-version",)
    compiles = True

    @classmethod
    def validate_declaration(cls, spec):
        super().validate_declaration(spec)
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+", spec["cabal"]):
            raise BootstrapError("Invalid Cabal release")

    def resolve_roots(self):
        base = Path(
            os.environ.get("GHCUP_INSTALL_BASE_PREFIX", str(Path.home()))
        )
        if not base.is_absolute():
            raise BootstrapError("GHCUP_INSTALL_BASE_PREFIX must be absolute")
        # GHCup appends .ghcup to the exported prefix itself.
        root = self.locate(
            "GHCUP_INSTALL_BASE_PREFIX",
            base / ".ghcup",
            from_environment=False,
        )
        return {"GHCUP_INSTALL_BASE_PREFIX": root}

    def environment(self):
        return {"GHCUP_INSTALL_BASE_PREFIX": str(self.root.parent)}

    def binary(self, selection=None):
        release = selection or self.spec["version"]
        return self.root / "ghc" / release / "bin/ghc"

    @property
    def cabal(self):
        return self.root / "bin" / ("cabal-" + self.spec["cabal"])

    def baseline(self):
        return [
            self.row(self.spec["version"], self.binary(), component="ghc"),
            self.row(self.spec["cabal"], self.cabal, component="cabal"),
        ]

    def prefix(self, row):
        if row["component"] == "cabal":
            return Path(row["path"])
        return super().prefix(row)

    def install_arguments(self, row):
        return [
            "install",
            row.get("component", "ghc"),
            row["version"],
            "--no-set",
        ]

    def canary(self, row, path, *, complete):
        # Cabal is a build tool without a runtime canary of its own.
        if row.get("component") != "cabal":
            super().canary(row, path, complete=complete)

    def exercise(self, executable, work, call):
        return call(
            [executable, "-ignore-dot-ghci", "-e", 'putStrLn "bootstrap-ok"']
        )

    def selected(self):
        rows = super().selected()
        path = self.root / "bin/cabal"
        row = {
            "language": self.language,
            "component": "cabal",
            "version": self.spec["cabal"],
            "path": str(path),
            "owner": self.manager_name,
        }
        try:
            self.check_runtime(path)
            row["state"] = "present"
        except BootstrapError as error:
            row.update(state="blocked", reason=str(error))
        return [*rows, row]

    def default_arguments(self):
        return ["set", "ghc", self.spec["version"]]

    def initialize_default(self):
        super().initialize_default()
        if not os.path.lexists(self.root / "bin/cabal"):
            self.invoke("set", "cabal", self.spec["cabal"])
