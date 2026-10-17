"""The folders of an extensions directory, as they are on disk.

VS Code names an extension's folder ``<publisher>.<name>-<version>``, with
``-<platform>`` appended for a platform-specific build. A folder counts as an
extension only when its ``package.json`` names that same extension and
version; anything else is never touched. Symlinks are read, not followed,
and their targets are compared as written.
"""

import json
import os
import stat
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from .jsondata import as_object
from .versions import Version, parse_version

TARGET_PLATFORMS = frozenset(
    {
        "alpine-arm64",
        "alpine-x64",
        "darwin-arm64",
        "darwin-x64",
        "linux-arm64",
        "linux-armhf",
        "linux-x64",
        "web",
        "win32-arm64",
        "win32-x64",
    }
)
"""The platform suffixes VS Code appends to a platform-specific folder."""

MAX_PACKAGE_BYTES = 4 * 1024 * 1024
"""The largest package.json read; a larger one is not an extension's."""


class Kind(Enum):
    """What a name in an extensions directory is."""

    DIRECTORY = "directory"
    LINK = "link"
    MISSING = "missing"
    OTHER = "other"


@dataclass(frozen=True, slots=True)
class Package:
    """The extension a folder holds, from its ``package.json``.

    ``extension_id`` is ``publisher.name`` in lower case, as VS Code compares
    it; ``platform`` is the folder name's platform suffix, if any.
    """

    extension_id: str
    version: Version
    platform: str | None


@dataclass(frozen=True, slots=True)
class Folder:
    """One name in an extensions directory.

    ``link`` is a symlink's text and ``target`` where it points, made
    absolute and normalized without touching the filesystem. ``package`` is
    set for a real directory that holds a recognizable extension.
    """

    name: str
    path: Path
    kind: Kind
    link: str | None = None
    target: Path | None = None
    package: Package | None = None

    def links_into(self, *directories: Path) -> bool:
        """Whether this is a symlink to a direct child of a directory."""
        if self.kind is not Kind.LINK or self.target is None:
            return False
        return self.target.name != "" and self.target.parent in directories

    def target_exists(self) -> bool:
        """Whether a symlink's target, or the directory itself, exists."""
        return self.path.exists()


def folder_name(extension_id: str, version: str, platform: str | None) -> str:
    """The folder name VS Code gives an extension build."""
    suffix = f"-{platform}" if platform else ""
    return f"{extension_id}-{version}{suffix}"


def inspect(root: Path, name: str) -> Folder:
    """What ``name`` in ``root`` is, without following a symlink."""
    path = root / name
    try:
        status = path.lstat()
    except FileNotFoundError:
        return Folder(name, path, Kind.MISSING)
    except OSError:
        return Folder(name, path, Kind.OTHER)
    if stat.S_ISLNK(status.st_mode):
        try:
            link = os.readlink(path)
        except OSError:
            return Folder(name, path, Kind.OTHER)
        target = Path(os.path.normpath(os.path.join(root, link)))
        return Folder(name, path, Kind.LINK, link, target)
    if stat.S_ISDIR(status.st_mode):
        return Folder(name, path, Kind.DIRECTORY, package=_package(path))
    return Folder(name, path, Kind.OTHER)


def scan(root: Path) -> dict[str, Folder]:
    """Every directory and symlink in ``root``, by name.

    Hidden names (``.obsolete`` and VS Code's temporary folders) and plain
    files are left out. A missing directory is empty.
    """
    try:
        names = sorted(entry.name for entry in os.scandir(root))
    except FileNotFoundError:
        return {}
    folders: dict[str, Folder] = {}
    for name in names:
        if name.startswith("."):
            continue
        folder = inspect(root, name)
        if folder.kind in (Kind.DIRECTORY, Kind.LINK):
            folders[name] = folder
    return folders


def _package(directory: Path) -> Package | None:
    """The extension in ``directory``, if its name and package agree."""
    manifest = directory / "package.json"
    try:
        if manifest.stat().st_size > MAX_PACKAGE_BYTES:
            return None
        data: object = json.loads(manifest.read_bytes().decode("utf-8-sig"))
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    fields = as_object(data)
    if fields is None:
        return None
    publisher = fields.get("publisher")
    name = fields.get("name")
    text = fields.get("version")
    if not (
        isinstance(publisher, str)
        and isinstance(name, str)
        and isinstance(text, str)
    ):
        return None
    version = parse_version(text)
    if version is None:
        return None
    extension_id = f"{publisher}.{name}".lower()
    base = folder_name(extension_id, version.text, None)
    if directory.name == base:
        return Package(extension_id, version, None)
    platform = directory.name.removeprefix(f"{base}-")
    if directory.name.startswith(f"{base}-") and platform in TARGET_PLATFORMS:
        return Package(extension_id, version, platform)
    return None
