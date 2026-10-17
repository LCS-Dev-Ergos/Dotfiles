"""Read a settings file and replace it atomically, backed up while it runs.

A replacement is written next to the file and renamed over it, so VS Code
never sees a half-written settings.json, and it is refused when the file
changed after it was read. A symlink is followed to the real file, so the
link stays a link. The backup taken before a write is removed when the write
succeeds; only a failed run leaves one behind.
"""

import hashlib
import os
import shutil
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from . import PROG
from .errors import SettingsError
from .host import Host

MAX_SETTINGS_BYTES = 8 * 1024 * 1024
"""The largest settings file accepted."""

BACKUPS_KEPT = 20
"""How many backups left by failed runs are kept; older ones are pruned."""

_BOM = b"\xef\xbb\xbf"
_BACKUP_GLOB = "settings-*.json"


@dataclass(frozen=True, slots=True)
class SettingsFile:
    """A settings file as it was read.

    ``path`` is the real file behind any symlink, ``raw`` its bytes, ``text``
    the decoded content and ``bom`` whether a byte order mark preceded it.
    """

    path: Path
    raw: bytes
    text: str
    bom: bool

    def encode(self, text: str) -> bytes:
        """``text`` as bytes in this file's encoding."""
        return (_BOM if self.bom else b"") + text.encode("utf-8")


@dataclass(frozen=True, slots=True)
class WriteResult:
    """The outcome of a write.

    ``written`` tells whether the file changed. ``backup`` is set only when
    the backup of a successful write could not be removed; ``warnings`` say
    why, and report anything else that did not stop the write.
    """

    written: bool
    backup: Path | None = None
    warnings: tuple[str, ...] = ()


def load(path: Path) -> SettingsFile:
    """Read and decode a settings file.

    Raises:
        SettingsError: If the file is missing, not a regular file, larger
            than ``MAX_SETTINGS_BYTES`` or not UTF-8.
    """
    try:
        real = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SettingsError(f"cannot open {path}: {_reason(error)}") from None
    if not real.is_file():
        raise SettingsError(f"{real} is not a regular file")
    try:
        if real.stat().st_size > MAX_SETTINGS_BYTES:
            raise SettingsError(
                f"{real} is larger than {MAX_SETTINGS_BYTES} bytes"
            )
        raw = real.read_bytes()
    except OSError as error:
        raise SettingsError(f"cannot read {real}: {_reason(error)}") from None
    bom = raw.startswith(_BOM)
    try:
        text = raw[len(_BOM) :].decode("utf-8") if bom else raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SettingsError(
            f"the settings are not valid UTF-8 ({error})"
        ) from None
    return SettingsFile(real, raw, text, bom)


@dataclass(frozen=True, slots=True)
class Backups:
    """Copies of settings files as they were before a write.

    They live in the state directory, outside VS Code's own directories,
    readable by their owner only. A successful write discards its backup,
    so the directory only accumulates the backups of failed runs, and only
    up to ``keep`` of them.

    Raises:
        ValueError: If ``keep`` is smaller than one.
    """

    directory: Path
    keep: int = BACKUPS_KEPT

    def __post_init__(self) -> None:
        if self.keep < 1:
            raise ValueError(f"at least one backup must be kept: {self.keep}")

    @classmethod
    def for_host(cls, host: Host) -> "Backups":
        """The backup directory below the host's state directory."""
        return cls(host.concrete(host.state_home() / PROG / "backups"))

    def save(self, raw: bytes) -> tuple[Path, list[str]]:
        """Store ``raw`` as a new backup and prune the oldest.

        Returns:
            The backup and warnings about permissions or pruning, which do
            not stop the write.

        Raises:
            SettingsError: If the backup cannot be written.
        """
        warnings: list[str] = []
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise SettingsError(
                f"cannot create {self.directory}: {_reason(error)}"
            ) from None
        try:
            self.directory.chmod(0o700)
        except OSError as error:
            warnings.append(
                f"cannot restrict {self.directory} to its owner: "
                f"{_reason(error)}"
            )
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        digest = hashlib.sha256(raw).hexdigest()[:8]
        target = self.directory / f"settings-{stamp}-{digest}.json"
        flags = (
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
        )
        try:
            descriptor = os.open(target, flags, 0o600)
        except OSError as error:
            raise SettingsError(
                f"cannot create the backup {target}: {_reason(error)}"
            ) from None
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(raw)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as error:
            target.unlink(missing_ok=True)
            raise SettingsError(
                f"cannot write the backup {target}: {_reason(error)}"
            ) from None
        warnings += self._prune()
        return target, warnings

    def discard(self, backup: Path) -> list[str]:
        """Remove a backup that is no longer needed.

        Returns:
            A warning when it cannot be removed, which leaves it in place.
        """
        try:
            backup.unlink()
        except OSError as error:
            return [f"cannot remove the backup {backup}: {_reason(error)}"]
        return []

    def _prune(self) -> list[str]:
        """Remove all but the newest ``keep`` backups."""
        warnings: list[str] = []
        stale = sorted(self.directory.glob(_BACKUP_GLOB))[: -self.keep]
        for path in stale:
            try:
                path.unlink()
            except OSError as error:
                warnings.append(f"cannot remove {path}: {_reason(error)}")
        return warnings


def replace_atomically(
    target: Path, expected: bytes, data: bytes
) -> list[str]:
    """Replace ``target`` with ``data`` unless it no longer holds ``expected``.

    Returns:
        Warnings that do not undo the replacement.

    Raises:
        SettingsError: If the file changed in the meantime or cannot be
            written.
    """
    try:
        descriptor, name = tempfile.mkstemp(
            prefix=f".{target.name}.", dir=target.parent
        )
    except OSError as error:
        raise SettingsError(
            f"cannot write next to {target}: {_reason(error)}"
        ) from None
    temp = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        shutil.copymode(target, temp)
        if target.read_bytes() != expected:
            raise SettingsError(
                f"{target} changed while it was being processed; run again"
            )
        temp.replace(target)
    except OSError as error:
        raise SettingsError(
            f"cannot replace {target}: {_reason(error)}"
        ) from None
    finally:
        temp.unlink(missing_ok=True)
    return sync_directory(target.parent)


def commit(file: SettingsFile, text: str, backups: Backups) -> WriteResult:
    """Write ``text`` over ``file``, holding a backup while it runs.

    The previous content is backed up first, and the backup is removed once
    the new file has been read back and matches. It outlives the run only
    when the run fails, and the error names it. Nothing is written, and no
    backup made, when the content is unchanged.

    Raises:
        SettingsError: If the backup, the write or the read-back fails.
    """
    data = file.encode(text)
    if data == file.raw:
        return WriteResult(written=False)
    backup, warnings = backups.save(file.raw)
    try:
        warnings += replace_atomically(file.path, file.raw, data)
        _confirm(file, data)
    except SettingsError as error:
        raise SettingsError(
            f"{error}; the previous file is kept at {backup}"
        ) from None
    leftover = backups.discard(backup)
    kept = backup if leftover else None
    return WriteResult(True, kept, tuple(warnings + leftover))


def _confirm(file: SettingsFile, data: bytes) -> None:
    """Read the written file back; on a mismatch, put the original back.

    Raises:
        SettingsError: If the file cannot be read or does not hold ``data``.
    """
    try:
        written = file.path.read_bytes()
    except OSError as error:
        raise SettingsError(
            f"cannot read back {file.path}: {_reason(error)}"
        ) from None
    if written != data:
        replace_atomically(file.path, written, file.raw)
        raise SettingsError(
            "verification after writing failed; the original is back"
        )


def sync_directory(directory: Path) -> list[str]:
    """Flush a rename to disk on POSIX, where it lives in the directory."""
    if os.name != "posix":
        return []
    try:
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        warning = (
            f"cannot flush {directory}, so the change may not survive a "
            f"crash: {_reason(error)}"
        )
        return [warning]
    return []


def _reason(error: BaseException) -> str:
    """The short reason of an operating system error."""
    if isinstance(error, OSError) and error.strerror:
        return error.strerror
    return str(error)
