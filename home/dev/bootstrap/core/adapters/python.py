"""CPython through pyenv, built by the pinned python-build from retained sources."""

import hashlib
import os
import re
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import writable_directory
from .base import SELECTION_NAME, SYSTEM_SELECTION, Adapter

# The declared baseline must provide every extension module python-build
# compiles from the retained sources, including 3.14's Zstandard support.
BUILD_CANARY = (
    "import ssl, sqlite3, bz2, lzma, ctypes, readline, tkinter, venv; "
    "import zlib, compression.zstd as zstd; "
    "assert zstd.decompress(zstd.compress(b'bootstrap')) == b'bootstrap'; "
    "db = sqlite3.connect(':memory:'); "
    "assert db.execute('select 2').fetchone() == (2,)"
)
# A selected Python, of any release, needs what package installation uses.
HEALTH_CANARY = "import ssl, venv, zlib"


class PythonAdapter(Adapter):
    language = "python"
    manager_name = "pyenv"
    runtime_directory = "versions"
    compiles = True

    def resolve_roots(self):
        return {
            "PYENV_ROOT": self.locate("PYENV_ROOT", Path.home() / ".pyenv")
        }

    def manager_candidates(self):
        """A supported pyenv checkout owns its command before the host package.

        This matches production Zsh, which puts the checkout first on PATH.
        """
        if not self.recipe:
            return None
        directory = Path(self.recipe["managerDirectory"])
        return [
            self.root / "bin/pyenv",
            directory / self.recipe["managers"]["python"],
        ]

    def readiness(self):
        self.check_manager_release()

    def baseline(self):
        release = self.context.data["python"]["version"]
        return [
            self.row(release, self.root / "versions" / release / "bin/python")
        ]

    @staticmethod
    def flags(row):
        # Native interpreters support -I. A Nix Python environment needs its
        # wrapper's controlled PYTHONPATH; run() clears the caller's PYTHONPATH
        # and -P/-s exclude cwd and user-site packages.
        return ["-I"] if row.get("isolated", True) else ["-P", "-s"]

    def identity(self, row, path):
        return process.run(
            [
                str(path),
                *self.flags(row),
                "-B",
                "-c",
                "import platform; print(platform.python_version())",
            ]
        )

    def canary(self, row, path, *, complete):
        process.run(
            [
                str(path),
                *self.flags(row),
                "-B",
                "-c",
                BUILD_CANARY if complete else HEALTH_CANARY,
            ]
        )

    def selection(self):
        marker = self.root / "version"
        return marker.read_text()[:4096].strip() if marker.is_file() else None

    def selected_runtime(self):
        selection = (self.selection() or "").split()
        if selection[:1] == [SYSTEM_SELECTION]:
            return None
        if not selection or not re.fullmatch(SELECTION_NAME, selection[0]):
            raise BootstrapError("No supported pyenv global selection")
        return self.root / "versions" / selection[0] / "bin/python"

    def initialize_default(self):
        if os.path.lexists(self.root / "version"):
            return
        process.run(
            [
                str(self.manager()),
                *self.context.arguments(
                    "pythonDefault",
                    version=self.context.data["defaults"]["python"],
                ),
            ],
            env={"PYENV_ROOT": str(self.root)},
            cwd=str(self.context.state),
        )

    def repair_hooks(self):
        shim = self.root / "shims/python"
        if not shim.is_file():
            self.rehash(cwd=str(self.context.state))
        if not shim.is_file():
            raise BootstrapError(
                "pyenv did not create the requested Python shim"
            )

    def rehash(self, **options):
        process.run(
            [str(self.manager()), *self.context.arguments("pythonRehash")],
            env={"PYENV_ROOT": str(self.root)},
            **options,
        )

    # Source build ------------------------------------------------------------

    def check_builder(self):
        expected = (
            f"python-build {self.context.data['python']['pythonBuildVersion']}"
        )
        if process.run(
            [self.context.data["python"]["builder"], "--version"]
        ) != (expected):
            raise BootstrapError(
                f"Python recovery requires immutable {expected}"
            )

    def preflight(self, missing):
        process.checksum_support()
        self.check_builder()

    def install(self, row):
        self.check_builder()
        declaration = self.context.data["python"]
        source_cache = Path(declaration["sourceCache"])
        for source in declaration.get("sources", []):
            with (source_cache / source["name"]).open("rb") as file:
                if (
                    hashlib.file_digest(file, "sha256").hexdigest()
                    != source["sha256"]
                ):
                    raise BootstrapError(
                        f"Python source checksum mismatch: {source['name']}"
                    )
        target = self.root / "versions" / row["version"]
        if os.path.lexists(target):
            raise BootstrapError("Python target appeared; refusing overwrite")
        writable_directory(self.context.cache)
        writable_directory(self.root)
        writable_directory(self.root / "versions")
        process.run(
            [
                declaration["builder"],
                *self.context.arguments(
                    "pythonBuild",
                    definition=str(Path(declaration["definition"])),
                    target=str(target),
                ),
            ],
            env={
                **self.recipe.get("buildEnvironment", {}),
                "PYENV_ROOT": str(self.root),
                "PYTHON_BUILD_CACHE_PATH": declaration["sourceCache"],
            },
            source_build=True,
            timeout=self.context.data["policy"]["timeouts"]["python"],
            cwd=str(self.context.cache),
        )
        self.rehash()
