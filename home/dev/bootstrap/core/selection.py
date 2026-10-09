"""The machine's saved ecosystem selection, which runs without --only use."""

import json
import os
from pathlib import Path

from .adapters import ADAPTERS
from .errors import BootstrapError
from .paths import read_json_object, writable_directory

SCHEMA = 1


def selection_path():
    """$XDG_CONFIG_HOME/dev-bootstrap/selection.json.

    A choice, not state: it belongs with configuration, and a Home Manager
    link there declares it for the host.
    """
    raw = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    if not Path(raw).is_absolute():
        raise BootstrapError("XDG_CONFIG_HOME must be absolute")
    return Path(raw) / "dev-bootstrap" / "selection.json"


def load_selection(path):
    """The saved ecosystems, or None when nothing is saved."""
    if not os.path.lexists(path):
        return None
    data = read_json_object(path)
    ecosystems = data.get("ecosystems")
    if (
        data.get("schema") != SCHEMA
        or not isinstance(ecosystems, list)
        or not ecosystems
        or not all(isinstance(name, str) for name in ecosystems)
    ):
        raise BootstrapError(
            f"Selection file {path} needs schema {SCHEMA} and a non-empty "
            "ecosystems list; rewrite it with --only ... --save-selection"
        )
    unknown = sorted(set(ecosystems) - set(ADAPTERS))
    if unknown:
        raise BootstrapError(
            f"Selection file {path} names unknown ecosystems "
            f"{', '.join(unknown)}; rewrite it with --only ... "
            "--save-selection"
        )
    return ecosystems


def save_selection(path, ecosystems):
    """Record the ecosystems, or forget the selection when given None.

    A symlinked file is declared elsewhere (Home Manager); replacing it here
    would only be undone, so we refuse and name it.
    """
    if path.is_symlink():
        raise BootstrapError(
            f"Selection file {path} is a link to {os.readlink(path)}; "
            "change the selection where it is declared"
        )
    if ecosystems is None:
        path.unlink(missing_ok=True)
        return
    writable_directory(path.parent)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps({"schema": SCHEMA, "ecosystems": list(ecosystems)}) + "\n"
    )
    os.replace(temporary, path)
