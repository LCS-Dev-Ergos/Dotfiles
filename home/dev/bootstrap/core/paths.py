"""Writable roots, owned directories and manager state files."""

import json
import os
import re
import shutil
import stat
from pathlib import Path

from .errors import BootstrapError

NIX_STORE = Path("/nix/store")


def root_path(key, default, *, from_environment=True):
    """Keep writable roots outside the checkout and immutable store."""
    raw = (os.environ.get(key) if from_environment else None) or str(default)
    path = Path(raw)
    if not path.is_absolute():
        raise BootstrapError(f"{key} must be absolute")
    resolved = path.resolve()
    repositories = [
        parent
        for parent in (resolved, *resolved.parents)
        if (parent / ".git").exists()
    ]
    # The canonical Git-installed pyenv stores its ignored versions beneath
    # its own checkout. Allow that manager root, never an enclosing project.
    pyenv_checkout = False
    if key == "PYENV_ROOT" and repositories == [resolved]:
        config = resolved / ".git/config"
        if config.is_file() and (resolved / "bin/pyenv").is_file():
            pyenv_checkout = bool(
                re.search(
                    r"url\s*=\s*(?:https://github.com/pyenv/pyenv(?:\.git)?|git@github.com:pyenv/pyenv\.git)\s*$",
                    config.read_text(),
                    re.MULTILINE,
                )
            )
    if resolved.is_relative_to(NIX_STORE) or (
        repositories and not pyenv_checkout
    ):
        raise BootstrapError(
            f"{key} must stay outside the checkout and Nix store"
        )
    if resolved == Path("/") or resolved == Path.home().resolve():
        raise BootstrapError(f"{key} cannot be the filesystem or home root")
    return resolved


def writable_directory(path, *, create=True):
    """Reject redirected or shared writable recovery state before mutation."""
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise BootstrapError(f"Recovery directory is a symlink: {parent}")
        if parent.exists():
            info = parent.stat()
            if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
                raise BootstrapError(
                    f"Recovery ancestor permits shared writes: {parent}"
                )
    if create:
        path.mkdir(parents=True, mode=0o700, exist_ok=True)
    elif not path.exists():
        return
    info = path.stat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o022
    ):
        raise BootstrapError(
            "Recovery directory must be owned and writable only by this account: "
            f"{path}"
        )


def renamed_directory(parent, name, legacy):
    """The directory that holds ``name``'s content until apply moves it.

    Reads find an earlier release's ``legacy`` directory in place, so a plan
    sees its journal without writing anything.
    """
    if not os.path.lexists(parent / name) and os.path.lexists(parent / legacy):
        return parent / legacy
    return parent / name


def migrate_directory(parent, name, legacy):
    """Rename ``legacy`` to ``name`` once, while only ``legacy`` exists.

    The directory keeps its inodes, so a lock an earlier release still holds
    in it keeps excluding us. Once ``name`` exists we leave a ``legacy``
    directory alone: only an earlier release recreates it.
    """
    current, previous = parent / name, parent / legacy
    if os.path.lexists(current) or not os.path.lexists(previous):
        return
    writable_directory(previous, create=False)
    try:
        os.rename(previous, current)
    except FileNotFoundError:
        # A concurrent apply moved it first.
        if not current.is_dir():
            raise


def read_json_object(path):
    """Treat damaged manager state as an operational error, never as empty state."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise BootstrapError(
            f"Cannot read JSON state {path}: {error}"
        ) from error
    if not isinstance(data, dict):
        raise BootstrapError(f"JSON state must be an object: {path}")
    return data


def native_command(name):
    executable = shutil.which(name)
    if not executable:
        raise BootstrapError(
            f"Install native {name} first; see home/dev/native-managers.nix"
        )
    if Path(executable).resolve().is_relative_to(NIX_STORE):
        raise BootstrapError(
            f"{name} still uses the Nix bridge; provision its native replacement first"
        )
    return executable
