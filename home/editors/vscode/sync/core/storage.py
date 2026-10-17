"""The state directory, and files and folders replaced without a torn state.

Everything the tool keeps lives below ``$XDG_STATE_HOME/vscode-sync``,
readable by its owner only:

- ``lock``: held for the whole of a run that changes anything.
- ``runs/``: one workspace per running change, with its journal and
  whatever the run moved aside, so it can be put back. A successful run
  removes its workspace; one left behind belongs to an interrupted run,
  which the next changing run undoes.
- ``backups/``: before a run changes anything, a copy of every extension
  list and deletion list of both editions and of Insiders' own user files.
  Only the newest ``BACKUP_RUNS`` are kept, and a file that did not change
  since the previous backup is a hard link to it, not another copy.
- ``downloads/``: builds being downloaded for a repair; removed afterwards,
  and by the next run if one was interrupted.
- ``quarantine/``: folders ``clean`` moved out of an extensions directory,
  and originals a recovery found their place taken for. Only the newest
  ``QUARANTINE_RUNS`` are kept.
"""

import errno
import filecmp
import os
import re
import shutil
import tempfile
from collections.abc import Iterable
from datetime import datetime, timezone
from pathlib import Path

from .errors import SyncError

BACKUP_RUNS = 5
"""How many runs' backups survive; older ones are pruned."""

QUARANTINE_RUNS = 5
"""How many ``clean`` runs' quarantined folders survive."""

_STAMPED = re.compile(r"\d{8}T\d{6}Z-\d+(-[a-z]+)?")


def stamp(label: str) -> str:
    """A name that sorts by time and is unique to this process."""
    now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{now}-{os.getpid()}-{label}"


def private_dir(path: Path) -> Path:
    """Create ``path`` and its parents, restricted to the owner.

    Raises:
        SyncError: If it cannot be created or restricted.
    """
    try:
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o700)
    except OSError as error:
        raise SyncError(f"cannot prepare {path}: {reason(error)}") from None
    return path


def new_workspace(state_dir: Path, label: str) -> Path:
    """A fresh run workspace below ``runs/``.

    Raises:
        SyncError: If it cannot be created.
    """
    runs = private_dir(state_dir / "runs")
    workspace = runs / stamp(label)
    try:
        workspace.mkdir(mode=0o700)
    except OSError as error:
        raise SyncError(
            f"cannot create {workspace}: {reason(error)}"
        ) from None
    return workspace


def backup(
    state_dir: Path, home: Path, label: str, paths: Iterable[Path]
) -> tuple[Path | None, list[str]]:
    """Copy ``paths`` into a fresh directory below ``backups/``.

    Each path is stored under its place relative to ``home``, or under
    ``_root`` for one outside it. Symlinks are not followed: a link is no
    file of its own. A file identical to the same file in the newest
    earlier backup becomes a hard link to it.

    Returns:
        The backup directory, None if there was nothing to copy, and
        warnings for older backups that could not be pruned.

    Raises:
        SyncError: If a file cannot be copied.
    """
    root = private_dir(state_dir / "backups")
    earlier = _newest_stamped(root)
    directory = root / stamp(label)
    copied = 0
    for path in paths:
        if path.is_symlink() or not path.exists():
            continue
        relative = _relative(path, home)
        destination = directory / relative
        previous = earlier / relative if earlier else None
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if path.is_dir():
                shutil.copytree(path, destination, symlinks=True)
            elif previous is not None and _same_file(path, previous):
                os.link(previous, destination)
            else:
                shutil.copy2(path, destination)
        except OSError as error:
            raise SyncError(
                f"cannot back up {path}: {reason(error)}"
            ) from None
        copied += 1
    if not copied:
        return None, []
    return directory, prune(root, BACKUP_RUNS)


def count_stamped(directory: Path) -> int:
    """How many stamped entries ``directory`` holds."""
    try:
        return sum(
            1
            for entry in os.scandir(directory)
            if _STAMPED.fullmatch(entry.name)
        )
    except FileNotFoundError:
        return 0


def _newest_stamped(directory: Path) -> Path | None:
    """The newest stamped entry of ``directory``."""
    names = sorted(
        entry.name
        for entry in os.scandir(directory)
        if _STAMPED.fullmatch(entry.name)
    )
    return directory / names[-1] if names else None


def _relative(path: Path, home: Path) -> Path:
    """Where a backed-up path is stored inside a backup."""
    try:
        return path.relative_to(home)
    except ValueError:
        return Path("_root") / path.relative_to(path.anchor)


def _same_file(path: Path, previous: Path) -> bool:
    """Whether ``previous`` is a regular file with ``path``'s bytes."""
    if previous.is_symlink() or not previous.is_file():
        return False
    return filecmp.cmp(path, previous, shallow=False)


def prune(directory: Path, keep: int) -> list[str]:
    """Remove all but the newest ``keep`` stamped entries of ``directory``.

    Returns:
        Warnings for entries that could not be removed.
    """
    try:
        names = sorted(
            entry.name
            for entry in os.scandir(directory)
            if _STAMPED.fullmatch(entry.name)
        )
    except FileNotFoundError:
        return []
    warnings: list[str] = []
    for name in names[: max(len(names) - keep, 0)]:
        try:
            remove_tree(directory / name)
        except OSError as error:
            warnings.append(
                f"cannot remove {directory / name}: {reason(error)}"
            )
    return warnings


def remove_tree(path: Path) -> None:
    """Remove a file, a symlink or a directory tree; never a link's target."""
    if path.is_symlink() or not path.is_dir():
        path.unlink(missing_ok=True)
    else:
        shutil.rmtree(path)


def move(source: Path, destination: Path) -> None:
    """Move ``source`` to ``destination``, which must not exist.

    A rename when both are on one filesystem, so it is atomic; otherwise a
    copy that keeps symlinks as they are, then the removal of the source.
    """
    if os.path.lexists(destination):
        raise FileExistsError(errno.EEXIST, "exists", str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.rename(source, destination)
        return
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
    if source.is_symlink() or not source.is_dir():
        shutil.copy2(source, destination, follow_symlinks=False)
    else:
        shutil.copytree(source, destination, symlinks=True)
    remove_tree(source)


def copy(source: Path, destination: Path) -> None:
    """Copy a file or a directory tree; symlinks inside stay symlinks."""
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination)


def sibling(path: Path, label: str) -> Path:
    """An unused hidden name next to ``path``, for staging a replacement."""
    for attempt in range(1000):
        candidate = (
            path.parent / f".{path.name}.{label}-{os.getpid()}-{attempt}"
        )
        if not os.path.lexists(candidate):
            return candidate
    raise SyncError(f"no free name next to {path}")


def write_atomically(path: Path, expected: bytes | None, data: bytes) -> None:
    """Replace a file with ``data`` unless it no longer holds ``expected``.

    ``expected`` None means the file must not exist yet. A symlinked file is
    written through its link, so the link stays a link. The new file keeps
    the old one's permissions.

    Raises:
        SyncError: If the file changed, or cannot be written.
    """
    real = ensure_unchanged(path, expected)
    current = expected
    try:
        descriptor, name = tempfile.mkstemp(
            prefix=f".{real.name}.", dir=real.parent
        )
    except OSError as error:
        raise SyncError(
            f"cannot write next to {real}: {reason(error)}"
        ) from None
    temp = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        if current is None:
            temp.chmod(0o644 & ~_umask())
        else:
            shutil.copymode(real, temp)
        temp.replace(real)
    except OSError as error:
        raise SyncError(f"cannot replace {real}: {reason(error)}") from None
    finally:
        temp.unlink(missing_ok=True)
    sync_directory(real.parent)


def ensure_unchanged(path: Path, expected: bytes | None) -> Path:
    """The file ``path`` names, after checking it still holds ``expected``.

    Raises:
        SyncError: If it changed, or cannot be read.
    """
    real = Path(os.path.realpath(path))
    try:
        current = real.read_bytes()
    except FileNotFoundError:
        current = None
    except OSError as error:
        raise SyncError(f"cannot read {real}: {reason(error)}") from None
    if current != expected:
        raise SyncError(f"{real} changed while it was being processed")
    return real


def sync_directory(directory: Path) -> None:
    """Flush renames in ``directory`` to disk, as far as the system allows."""
    try:
        descriptor = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


def reason(error: BaseException) -> str:
    """The short reason of an operating system error."""
    if isinstance(error, OSError) and error.strerror:
        return error.strerror
    return str(error)


def _umask() -> int:
    """The process umask, read without changing it for long."""
    mask = os.umask(0o022)
    os.umask(mask)
    return mask
