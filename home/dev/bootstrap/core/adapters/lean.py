"""Lean through elan; toolchains live in directories named after selectors."""

from pathlib import Path

from .toolchain import SettingsToolchain


class LeanAdapter(SettingsToolchain):
    language = "lean"
    manager_name = "elan"
    runtime_directory = "toolchains"

    def resolve_roots(self):
        return {"ELAN_HOME": self.locate("ELAN_HOME", Path.home() / ".elan")}

    @property
    def toolchain(self):
        return "leanprover/lean4:v" + self.spec["version"]

    @staticmethod
    def directory(selection):
        return selection.replace("/", "--").replace(":", "---")

    def binary(self, selection=None):
        return (
            self.root
            / "toolchains"
            / self.directory(selection or self.toolchain)
            / "bin/lean"
        )

    def install_arguments(self, row):
        return ["toolchain", "install", self.toolchain]

    def default_arguments(self):
        return ["default", self.toolchain]

    def exercise(self, executable, work, call):
        source = work / "Main.lean"
        source.write_text('def main : IO Unit := IO.println "bootstrap-ok"\n')
        return call([executable, "--run", source])
