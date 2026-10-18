"""Scan files and folders for hidden threats: ``security-scan``.

``files`` finds what to scan and opens it safely; ``structural``, ``yara``
and ``clamav`` are the three layers; ``findings`` holds what they report,
``report`` draws it and ``cli`` runs a scan. Nothing scanned is ever
written: files are opened read-only, and the external scanner runs with
literal arguments.
"""

import importlib.util
import sys
from pathlib import Path

__version__ = "2.0.0"

PROG = "security-scan"
"""The command name."""

RULES = Path(__file__).resolve().parent.parent / "rules"
"""The bundled YARA rules, next to the package in both layouts."""


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
