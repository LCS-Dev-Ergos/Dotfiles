"""Read-only views of the development environment, and compiler selection.

Two commands share this package. ``dev-doctor`` reports what the current
shell resolves for every runtime and tool in the registry: whether it is
installed, which version is active, whether it starts, where its binary
comes from and what on PATH competes with it. ``toolchain`` explains the
C/C++ compilers (``info``), tests which SDK headers the active compiler
reaches (``sdk``), and works out the shell code that selects a compiler pair
for one shell (``env``), which a Zsh function evaluates.

- Nothing here installs, downloads or changes a file outside a private
  temporary directory, except the update cache of ``dev-doctor --updates``.
- Every child process gets literal arguments, an empty standard input, a
  process group of its own and a timeout; none goes through a shell.
- Shell code is only ever printed for the caller to evaluate, built from a
  fixed set of variable names with every value quoted.

Modules, in dependency order: ``host`` describes the machine, ``process``
runs children, ``versions`` reads and compares version strings,
``compilers`` identifies C/C++ compilers, ``registry`` declares what
dev-doctor checks, ``doctor`` checks it, ``deep`` reads dev-bootstrap's
health report, ``sdk`` probes headers, ``selection`` chooses a compiler
pair, ``report`` draws everything and ``cli`` ties it together.
"""

import importlib.util
import sys
from pathlib import Path

__version__ = "1.0.0"

DOCTOR = "dev-doctor"
"""The health command, also the name of its cache directory."""

TOOLCHAIN = "toolchain"
"""The compiler command."""


def _load_terminal_style() -> None:
    """Make ``import terminal_style`` find the shared terminal style.

    The package installs a copy next to this package; a repository checkout
    reads home/shells/terminal-style. The module is loaded from its file, so
    no directory joins the import path and nothing there can shadow a module
    of this package.

    Raises:
        ImportError: If neither copy exists.
    """
    if "terminal_style" in sys.modules:
        return
    root = Path(__file__).resolve().parent.parent
    for directory in (root, root.parents[1] / "shells" / "terminal-style"):
        path = directory / "terminal_style.py"
        if path.is_file():
            break
    else:
        raise ImportError(f"terminal_style.py is missing next to {root}")
    spec = importlib.util.spec_from_file_location("terminal_style", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["terminal_style"] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules["terminal_style"]
        raise


_load_terminal_style()
