"""VS Code's lists of installed extensions, and its list of folders to delete.

Each profile has an ``extensions.json``: the default profile's sits in the
extensions directory, the others' in ``User/profiles/<location>``, where the
locations come from ``User/globalStorage/storage.json``. A manifest is a JSON
array with one object per extension; its folder is ``relativeLocation``, or
the last component of ``location.path``.

``.obsolete`` in the extensions directory maps folder names to ``true``:
VS Code deletes those folders the next time it starts.

Files that cannot be parsed are refused, never rewritten. Edits keep every
entry and every field they do not change, and are written in VS Code's own
compact form.
"""

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

from .errors import SyncError
from .host import Edition, Host
from .jsondata import as_array, as_object

EXTENSION_ID = re.compile(r"[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*")
"""What VS Code accepts as ``publisher.name``, in lower case.

An entry whose identifier does not match is kept but never acted on; its
identifier never reaches a command line, where it could pass for an option.
"""

MAX_JSON_BYTES = 32 * 1024 * 1024
"""The largest manifest, storage or ``.obsolete`` file read."""

DEFAULT_SCOPE = "Default"
"""How the default profile is named in reports."""


@dataclass(frozen=True, slots=True)
class Reference:
    """One usable entry of a manifest.

    ``index`` is the entry's position in the array, ``extension_id`` its
    identifier in lower case and ``folder`` the folder it names. ``entry``
    is the entry itself.
    """

    index: int
    extension_id: str
    folder: str
    version: str | None
    location: str | None
    entry: Mapping[str, object]


@dataclass(frozen=True, slots=True)
class Manifest:
    """One profile's ``extensions.json`` as it was read.

    ``scope`` names the profile, ``raw`` holds the bytes read and
    ``entries`` the parsed array. ``skipped`` counts entries without an
    identifier or a usable folder, which are kept but never acted on.
    """

    path: Path
    scope: str
    raw: bytes
    entries: tuple[object, ...]
    references: tuple[Reference, ...]
    skipped: int = 0

    def folders(self) -> set[str]:
        """The folders the manifest names."""
        return {reference.folder for reference in self.references}

    def find(self, extension_id: str) -> Reference | None:
        """The entry of an extension, if the manifest has one."""
        for reference in self.references:
            if reference.extension_id == extension_id:
                return reference
        return None


@dataclass(frozen=True, slots=True)
class Profile:
    """A profile VS Code knows of: its name and directory."""

    name: str
    location: str


@dataclass(frozen=True, slots=True)
class Obsolete:
    """The ``.obsolete`` file of an extensions directory.

    ``raw`` is None when the file does not exist; ``data`` holds its object.
    """

    path: Path
    raw: bytes | None
    data: Mapping[str, object] = field(default_factory=dict[str, object])

    @property
    def names(self) -> frozenset[str]:
        """The folders VS Code will delete."""
        return frozenset(self.data)

    def without(self, names: set[str]) -> bytes | None:
        """The file's content with ``names`` dropped, or None if unchanged."""
        dropped = {key: value for key, value in self.data.items()}
        for name in names:
            dropped.pop(name, None)
        if len(dropped) == len(self.data):
            return None
        return encode(dropped)


def encode(value: object) -> bytes:
    """JSON as VS Code writes these files: compact, UTF-8, no newline."""
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return text.encode("utf-8")


def read_json(path: Path) -> tuple[bytes, object] | None:
    """The bytes and the parsed value of a JSON file; None if it is absent.

    Raises:
        SyncError: If the file cannot be read, is too large, is not UTF-8
            or is not JSON.
    """
    try:
        if path.stat().st_size > MAX_JSON_BYTES:
            raise SyncError(f"{path} is larger than {MAX_JSON_BYTES} bytes")
        raw = path.read_bytes()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise SyncError(f"Cannot read {path}: {error.strerror}") from None
    try:
        return raw, json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError) as error:
        raise SyncError(f"{path} is not valid JSON: {error}") from None


def read_manifest(path: Path, scope: str) -> Manifest | None:
    """Parse a manifest; None if the file does not exist.

    Raises:
        SyncError: If it cannot be read or is not a JSON array.
    """
    loaded = read_json(path)
    if loaded is None:
        return None
    raw, value = loaded
    array = as_array(value)
    if array is None:
        raise SyncError(f"{path} is not a JSON array")
    entries = tuple(array)
    references: list[Reference] = []
    skipped = 0
    for index, entry in enumerate(entries):
        reference = _reference(index, entry)
        if reference is None:
            skipped += 1
        else:
            references.append(reference)
    return Manifest(path, scope, raw, entries, tuple(references), skipped)


def read_profiles(user_dir: Path) -> list[Profile]:
    """The profiles of an edition, from its ``storage.json``.

    A missing file means no profiles beyond the default. Profiles whose
    location is not a plain relative path are left out.

    Raises:
        SyncError: If the file exists but cannot be parsed.
    """
    path = user_dir / "globalStorage" / "storage.json"
    loaded = read_json(path)
    if loaded is None:
        return []
    _, value = loaded
    data = as_object(value)
    if data is None:
        raise SyncError(f"{path} is not a JSON object")
    listed = as_array(data.get("userDataProfiles", []))
    if listed is None:
        raise SyncError(f"{path}: userDataProfiles is not a list")
    profiles: list[Profile] = []
    for item in listed:
        fields = as_object(item)
        if fields is None:
            continue
        name, location = fields.get("name"), fields.get("location")
        if not (isinstance(name, str) and isinstance(location, str)):
            continue
        if _plain_relative(location):
            profiles.append(Profile(name, location))
    return profiles


def read_manifests(host: Host, edition: Edition) -> tuple[Manifest, ...]:
    """Every manifest of an edition that exists, the default one first.

    Raises:
        SyncError: If one of them, or the profile list, cannot be parsed.
    """
    found: list[Manifest] = []
    default = host.extensions_dir(edition) / "extensions.json"
    manifest = read_manifest(default, DEFAULT_SCOPE)
    if manifest is not None:
        found.append(manifest)
    user_dir = host.user_dir(edition)
    for profile in read_profiles(user_dir):
        path = user_dir / "profiles" / profile.location / "extensions.json"
        manifest = read_manifest(path, profile.name)
        if manifest is not None:
            found.append(manifest)
    return tuple(found)


def read_obsolete(root: Path) -> Obsolete:
    """The ``.obsolete`` file of an extensions directory.

    Raises:
        SyncError: If it exists but is not a JSON object.
    """
    path = root / ".obsolete"
    loaded = read_json(path)
    if loaded is None:
        return Obsolete(path, None)
    raw, value = loaded
    data = as_object(value)
    if data is None:
        raise SyncError(f"{path} is not a JSON object")
    return Obsolete(path, raw, dict(data))


def location_payload(previous: object, path: Path) -> dict[str, object]:
    """A manifest ``location`` pointing at ``path``.

    The fields VS Code may have stored (``fsPath``, ``external``) follow the
    new path; anything else in the previous location is kept.
    """
    location = dict(as_object(previous) or {})
    location["$mid"] = location.get("$mid", 1)
    location["path"] = str(path)
    location["scheme"] = "file"
    if "fsPath" in location:
        location["fsPath"] = str(path)
    if "external" in location:
        location["external"] = path.as_uri()
    return location


def _plain_relative(text: str) -> bool:
    """Whether ``text`` is a relative path without ``.`` or ``..`` parts."""
    path = PurePosixPath(text)
    if not text or path.is_absolute():
        return False
    return all(part not in (".", "..") for part in path.parts)


def _reference(index: int, entry: object) -> Reference | None:
    """The usable reference an entry makes, if it makes one."""
    fields = as_object(entry)
    if fields is None:
        return None
    identifier = as_object(fields.get("identifier")) or {}
    value = identifier.get("id")
    extension_id = value.lower() if isinstance(value, str) else None
    location = as_object(fields.get("location")) or {}
    value = location.get("path")
    location_path = value if isinstance(value, str) else None
    folder = None
    relative = fields.get("relativeLocation")
    if isinstance(relative, str) and relative.strip("/ "):
        folder = relative.strip().strip("/")
    elif location_path:
        folder = PurePosixPath(location_path).name
    if not extension_id or not EXTENSION_ID.fullmatch(extension_id):
        return None
    if not folder or "/" in folder:
        return None
    if folder in (".", ".."):
        return None
    version = fields.get("version")
    return Reference(
        index,
        extension_id,
        folder,
        version if isinstance(version, str) else None,
        location_path,
        fields,
    )
