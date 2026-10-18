"""Work with PDF documents: ``pdf-tools``.

``documents`` opens and saves PDFs safely and parses page selections;
``pages``, ``outline``, ``metadata``, ``passwords``, ``compression``,
``djvu`` and ``watermarks`` implement the subcommands; ``output`` draws
their results and ``cli`` ties them together. Every output is written to a
temporary file and renamed into place, so a failure never leaves half a
PDF, and nothing is overwritten unless asked.
"""

import importlib.util
import sys
from pathlib import Path

__version__ = "1.0.0"

PROG = "pdf-tools"
"""The command name."""


def _load_terminal_style() -> None:
    """Make ``import terminal_style`` find the shared terminal style.

    The package installs a copy next to this package; a repository checkout
    reads home/shells/terminal-style. The module is loaded from its file, so
    no directory joins the import path.

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
