"""GHC, Cabal and HLS through GHCup; installation and selection are separate."""

import os
import re
from pathlib import Path

from ..errors import BootstrapError
from .toolchain import LinkedToolchain

FOUR_PART = r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"
# The links `ghcup set` creates for the build tools; GHC's is `bin/ghc`.
SELECTED_TOOLS = {
    "cabal": "bin/cabal",
    "hls": "bin/haskell-language-server-wrapper",
}


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
        if not re.fullmatch(FOUR_PART, spec["cabal"]):
            raise BootstrapError("Invalid Cabal release")
        if not re.fullmatch(FOUR_PART, spec["hls"]):
            raise BootstrapError("Invalid HLS release")

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

    def runtime_environment(self):
        # The HLS bindist launcher only starts its server once it finds a GHC
        # whose version and boot-package ABI hashes match its build. Naming
        # the declared GHC makes it check that one, not whatever is on PATH.
        # GHC and Cabal ignore the variable.
        return super().runtime_environment() | {"GHC_BIN": str(self.binary())}

    def binary(self, selection=None):
        release = selection or self.spec["version"]
        return self.root / "ghc" / release / "bin/ghc"

    @property
    def cabal(self):
        return self.root / "bin" / ("cabal-" + self.spec["cabal"])

    @property
    def server(self):
        """The HLS binary built against the declared GHC."""
        return (
            self.root
            / "hls"
            / self.spec["hls"]
            / "bin"
            / ("haskell-language-server-" + self.spec["version"])
        )

    def baseline(self):
        return [
            self.row(self.spec["version"], self.binary(), component="ghc"),
            self.row(self.spec["cabal"], self.cabal, component="cabal"),
            self.row(self.spec["hls"], self.server, component="hls"),
        ]

    def prefix(self, row):
        if row["component"] == "cabal":
            return Path(row["path"])
        return super().prefix(row)

    def incomplete(self, row):
        if row["component"] == "hls":
            # Each HLS release ships servers for a fixed set of GHC releases.
            return (
                f"HLS {row['version']} has no server for GHC "
                f"{self.spec['version']}; choose an HLS release that does"
            )
        return super().incomplete(row)

    def install_arguments(self, row):
        return [
            "install",
            row.get("component", "ghc"),
            row["version"],
            "--no-set",
        ]

    def canary(self, row, path, *, complete):
        # Cabal is a build tool without a runtime canary of its own, and a
        # selected HLS wrapper serves whichever GHC a project uses.
        component = row.get("component")
        if component == "cabal" or (component == "hls" and not complete):
            return
        super().canary(row, path, complete=complete)

    def exercise(self, executable, work, call):
        if executable.name.startswith("haskell-language-server-"):
            # Reaching the server at all passed the launcher's ABI check.
            output = call([executable, "--version"])
            supported = f"(GHC: {self.spec['version']})" in output
            return "bootstrap-ok" if supported else output
        return call(
            [executable, "-ignore-dot-ghci", "-e", 'putStrLn "bootstrap-ok"']
        )

    def selected(self):
        rows = super().selected()
        for component, link in SELECTED_TOOLS.items():
            path = self.root / link
            row = {
                "language": self.language,
                "component": component,
                "version": self.spec[component],
                "path": str(path),
                "owner": self.manager_name,
            }
            try:
                self.check_runtime(path)
                row["state"] = "present"
            except BootstrapError as error:
                row.update(state="blocked", reason=str(error))
            rows.append(row)
        return rows

    def default_arguments(self):
        return ["set", "ghc", self.spec["version"]]

    def initialize_default(self):
        super().initialize_default()
        for component, link in SELECTED_TOOLS.items():
            if not os.path.lexists(self.root / link):
                self.invoke("set", component, self.spec[component])
