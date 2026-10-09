"""CPython through pyenv's own python-build, from python.org sources."""

import os
import re
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import writable_directory
from .base import SELECTION_NAME, SYSTEM_SELECTION, Adapter

# The declared prerequisites must provide every extension module python-build
# compiles, including 3.14's Zstandard support.
BUILD_CANARY = (
    "import ssl, sqlite3, bz2, lzma, ctypes, readline, tkinter, venv; "
    "import zlib, compression.zstd as zstd; "
    "assert zstd.decompress(zstd.compress(b'bootstrap')) == b'bootstrap'; "
    "db = sqlite3.connect(':memory:'); "
    "assert db.execute('select 2').fetchone() == (2,)"
)
# A selected Python, of any release, must still load every extension module
# that links a host library, so a native library upgrade that breaks one shows
# up in health. Tk stays out: a headless build may omit it on purpose.
HEALTH_CANARY = "import ssl, sqlite3, ctypes, readline, lzma, bz2, zlib, venv"


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

    def remediation(self, row):
        if row.get("owner") != self.manager_name:
            return None
        release = Path(row["path"]).parent.parent.name
        return ["pyenv", "install", "--force", release]

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

    def definitions(self):
        """The CPython releases the native python-build knows how to build."""
        output = process.run(
            [
                str(self.manager()),
                *self.context.arguments("pythonDefinitions"),
            ],
            env={"PYENV_ROOT": str(self.root)},
            cwd=str(self.context.state),
        )
        return {line.strip() for line in output.splitlines()}

    def preflight(self, missing):
        # python-build skips its embedded checksums without a SHA256 utility.
        process.checksum_support()
        available = self.definitions()
        unknown = sorted(
            row["version"]
            for row in missing
            if row["version"] not in available
        )
        if unknown:
            raise BootstrapError(
                "Native pyenv has no definition for Python "
                f"{', '.join(unknown)}; upgrade pyenv and retry"
            )

    def install(self, row):
        target = self.root / "versions" / row["version"]
        if os.path.lexists(target):
            raise BootstrapError("Python target appeared; refusing overwrite")
        writable_directory(self.context.cache)
        writable_directory(self.root)
        writable_directory(self.root / "versions")
        process.run(
            [
                str(self.manager()),
                *self.context.arguments(
                    "pythonInstall", version=row["version"]
                ),
            ],
            env={
                **self.recipe.get("buildEnvironment", {}),
                "PYENV_ROOT": str(self.root),
            },
            source_build=True,
            timeout=self.context.data["policy"]["timeouts"]["python"],
            cwd=str(self.context.cache),
        )
        self.rehash()
