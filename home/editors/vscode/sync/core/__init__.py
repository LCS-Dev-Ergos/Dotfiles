"""Share VS Code Stable's extensions and user files with VS Code Insiders.

Insiders keeps its own list of extensions, per profile, and Stable stays the
owner of every folder they share. Where both editions use the same extension,
Insiders' folder becomes a symlink to Stable's, so an extension is
downloaded, updated and stored once. Insiders' settings, keybindings,
snippets and MCP servers become links to Stable's files.

- Stable is never changed, except by VS Code's own ``code`` command during
  ``update`` and by ``clean``, which quarantines unused duplicate folders.
- Only links this tool made are ever replaced or removed. A link that points
  anywhere else is reported and left alone.
- Every change is planned from a read-only snapshot first, backed up,
  applied inside a transaction whose journal can undo it, and checked by
  planning again: a run that leaves anything to do is rolled back, and one
  an interruption cut short is undone by the next run.
- Problems are repaired, not only reported: a folder that is gone is
  replaced by another build or downloaded again, and a link to a folder
  Stable dropped becomes Insiders' own copy.
- Nothing changes while VS Code runs, without a terminal to confirm on or
  ``--yes``, or while another run holds the lock.

Modules, in dependency order: ``host`` describes the machine, ``versions``
compares extension versions, ``inventory`` reads extension folders,
``jsondata`` narrows parsed JSON, ``manifest`` reads and writes VS Code's
extension lists, ``plan`` works out the changes, ``storage`` keeps the state
directory and writes files atomically, ``transaction`` applies a plan and
can undo it, ``safety`` guards a run, ``update`` drives VS Code's command
line, ``report`` draws the results and ``cli`` ties them together.
"""

import importlib.util
import sys
from pathlib import Path

__version__ = "1.0.0"

PROG = "vscode-sync"
"""The command name, also the name of the state directory."""


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
    for directory in (root, root.parents[2] / "shells" / "terminal-style"):
        path = directory / "terminal_style.py"
        if path.is_file():
            break
    else:
        raise ImportError(f"terminal_style.py is missing next to {root}")
    spec = importlib.util.spec_from_file_location("terminal_style", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["terminal_style"] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules["terminal_style"]
        raise


_load_terminal_style()
