"""The state directory, and files and folders replaced without a torn state.

Everything the tool keeps lives below ``$XDG_STATE_HOME/vscode-sync``,
readable by its owner only:

- ``lock``: held for the whole of a run that changes anything.
- ``runs/``: one workspace per running change, holding whatever the run
  moved aside, so it can be put back. A successful run removes its
  workspace; one left behind belongs to an interrupted run.
- ``kept/``: Insiders user files a run replaced although they differed from
  Stable's. Only the newest ``KEPT_RUNS`` are kept.
- ``quarantine/``: folders ``clean`` moved out of an extensions directory.
  Only the newest ``QUARANTINE_RUNS`` are kept.
"""

import errno
import filecmp
import os
import re
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from .errors import SyncError

KEPT_RUNS = 10
"""How many runs' kept user files survive; older ones are pruned."""

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


def same_content(left: Path, right: Path) -> bool:
    """Whether two files, or two directory trees, hold the same bytes."""
    if left.is_dir() != right.is_dir():
        return False
    if not left.is_dir():
        return filecmp.cmp(left, right, shallow=False)
    comparison = filecmp.dircmp(left, right)
    if comparison.left_only or comparison.right_only:
        return False
    if comparison.funny_files or comparison.common_funny:
        return False
    _, mismatch, errors = filecmp.cmpfiles(
        left, right, comparison.common_files, shallow=False
    )
    if mismatch or errors:
        return False
    return all(
        same_content(left / name, right / name)
        for name in comparison.common_dirs
    )


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
    real = Path(os.path.realpath(path))
    try:
        current = real.read_bytes()
    except FileNotFoundError:
        current = None
    except OSError as error:
        raise SyncError(f"cannot read {real}: {reason(error)}") from None
    if current != expected:
        raise SyncError(f"{real} changed while it was being processed")
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
