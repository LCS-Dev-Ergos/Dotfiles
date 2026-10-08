"""Conda through the Miniforge3 installer, never selected implicitly.

Miniforge3 installs conda and its base environment in one batch run, which is
the manager acquisition: there is no separate runtime installation, and the
base environment is the runtime. `conda init` never runs; the shell's own
integration activates conda. Its installer is a hash-verified release asset.
"""

from pathlib import Path

from .. import process
from ..errors import BootstrapError
from .toolchain import ToolchainAdapter


class CondaAdapter(ToolchainAdapter):
    language = "conda"
    manager_name = "conda"
    # Conda environments shadow interpreters and libraries; only an explicit
    # `--only conda` installs it.
    default_selected = False

    def resolve_roots(self):
        # conda reads CONDA_ROOT_PREFIX as its base prefix, which is the
        # Miniforge installation prefix.
        return {
            "CONDA_ROOT_PREFIX": self.locate(
                "CONDA_ROOT_PREFIX", Path.home() / ".miniforge3"
            )
        }

    def manager_candidates(self):
        return [self.root / "bin/conda"]

    # Declared baseline -------------------------------------------------------

    def binary(self, selection=None):
        """The base environment's interpreter."""
        return self.root / "bin/python"

    def install(self, row):
        # Unreachable: acquisition installs the base environment, and a
        # prefix without its interpreter plans as a conflict.
        raise BootstrapError(
            f"Miniforge installs its base environment only through its "
            f"installer; inspect {self.root}"
        )

    # Verification ------------------------------------------------------------

    def identity(self, row, path):
        # The base interpreter reports the conda release installed into it,
        # without running the conda CLI.
        return self.parse_identity(
            process.run(
                [
                    str(path),
                    "-I",
                    "-c",
                    "import conda; print(conda.__version__)",
                ],
                env=self.runtime_environment(),
                source_build=True,
                cwd="/",
            )
        )

    def exercise(self, executable, work, call):
        return call(
            [
                executable,
                "-I",
                "-c",
                'import conda, ssl, sqlite3; print("bootstrap-ok")',
            ]
        )

    # Global selection --------------------------------------------------------

    def read_selection(self):
        """The base environment is the only global environment."""
        return None

    def selected_runtime(self):
        return self.binary()

    def initialize_default(self):
        """Miniforge's base environment needs no selection."""
