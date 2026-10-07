"""Rust through rustup, with the native default profile."""

from pathlib import Path

from .toolchain import SettingsToolchain

HOSTS = {
    "aarch64-darwin": "aarch64-apple-darwin",
    "x86_64-linux": "x86_64-unknown-linux-gnu",
}


class RustAdapter(SettingsToolchain):
    language = "rust"
    manager_name = "rustup"
    runtime_directory = "toolchains"
    compiles = True

    def resolve_roots(self):
        home = Path.home()
        return {
            "RUSTUP_HOME": self.locate("RUSTUP_HOME", home / ".rustup"),
            "CARGO_HOME": self.locate("CARGO_HOME", home / ".cargo"),
        }

    @property
    def home(self):
        return self.roots["CARGO_HOME"]

    def binary(self, selection=None):
        if selection is None:
            selection = f"{self.spec['version']}-{HOSTS[self.context.data['platform']]}"
        return self.root / "toolchains" / selection / "bin/rustc"

    def install_arguments(self, row):
        return [
            "toolchain",
            "install",
            row["version"],
            "--profile",
            "default",
            "--no-self-update",
        ]

    def default_arguments(self):
        return ["default", self.spec["version"]]

    def exercise(self, executable, work, call):
        source = work / "main.rs"
        source.write_text('fn main() { println!("bootstrap-ok"); }\n')
        call([executable, source, "-o", work / "canary"])
        return call([work / "canary"])
