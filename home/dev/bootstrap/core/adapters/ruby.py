"""Ruby through rbenv and ruby-build, both provided by the native packages."""

import os
from pathlib import Path

from ..errors import BootstrapError
from .base import SYSTEM_SELECTION
from .toolchain import ToolchainAdapter


class RubyAdapter(ToolchainAdapter):
    language = "ruby"
    manager_name = "rbenv"
    runtime_directory = "versions"
    compiles = True

    def resolve_roots(self):
        return {
            "RBENV_ROOT": self.locate("RBENV_ROOT", Path.home() / ".rbenv")
        }

    def manager_candidates(self):
        candidates = super().manager_candidates()
        directory = self.recipe.get("managerDirectory")
        if directory:
            candidates.append(Path(directory) / "rbenv")
        return candidates

    def binary(self, selection=None):
        release = selection or self.spec["version"]
        return self.root / "versions" / release / "bin/ruby"

    def read_selection(self):
        marker = self.root / "version"
        return marker.read_text().strip() if marker.is_file() else None

    def selected_runtime(self):
        if self.selection() == SYSTEM_SELECTION:
            return None
        return super().selected_runtime()

    def install_arguments(self, row):
        return ["install", "--skip-existing", row["version"]]

    def default_arguments(self):
        return ["global", self.spec["version"]]

    def initialize_default(self):
        if self.selection() is None and os.path.lexists(self.root / "version"):
            raise BootstrapError("Inspect the existing Ruby global selection")
        super().initialize_default()

    def repair_hooks(self):
        if not (self.root / "shims/ruby").is_file():
            self.invoke("rehash")

    def exercise(self, executable, work, call):
        return call(
            [
                executable,
                "--disable-gems",
                "-e",
                'require "openssl"; require "zlib"; abort unless 1+1==2; '
                'puts "bootstrap-ok"',
            ]
        )
