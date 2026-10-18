"""Which files a scan covers, and opening them without surprises.

A folder is walked without following symbolic links, and only regular files
are scanned: a link could lead the scan out of the folder, and reading a
named pipe or a device could block it or never end. Links and special files
inside a folder are counted, not scanned. A path named on the command line
is followed even when it is a link, since it was asked for by name.
"""

import errno
import hashlib
import io
import os
import stat
from collections import Counter
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Selection:
    """The files to scan, what could not be read, and what was left out.

    ``problems`` are paths the scan was meant to cover but cannot: they make
    the scan incomplete. ``skipped`` counts entries left out on purpose, by
    kind (``link``, ``special``).
    """

    files: list[Path] = field(default_factory=list[Path])
    problems: list[tuple[Path, str]] = field(
        default_factory=list[tuple[Path, str]]
    )
    skipped: Counter[str] = field(default_factory=Counter[str])


def select(paths: Iterable[Path], *, recursive: bool = True) -> Selection:
    """The regular files under the paths, each once, in a stable order.

    Paths are made absolute but not resolved, so they read as given; a file
    reached twice, through a hard link or two arguments, is scanned once.
    """
    selection = Selection()
    seen: set[tuple[int, int]] = set()

    def add(path: Path, status: os.stat_result) -> None:
        """Add a file unless it was already reached."""
        key = (status.st_dev, status.st_ino)
        if key not in seen:
            seen.add(key)
            selection.files.append(path)

    for raw in paths:
        path = Path(os.path.abspath(raw))
        try:
            status = path.stat()
        except OSError as error:
            selection.problems.append((path, _reason(error)))
            continue
        if stat.S_ISREG(status.st_mode):
            add(path, status)
        elif stat.S_ISDIR(status.st_mode):
            _walk(path, recursive, selection, add)
        else:
            selection.problems.append((path, "Not a regular file"))
    return selection


def _walk(
    top: Path,
    recursive: bool,
    selection: Selection,
    add: Callable[[Path, os.stat_result], None],
) -> None:
    """Add the regular files in a folder; count links and special files.

    A folder that cannot be listed is a problem, not a silent gap.
    """

    def failed(error: OSError) -> None:
        """Note a folder that could not be listed."""
        where = Path(error.filename) if error.filename else top
        selection.problems.append((where, _reason(error)))

    for directory, folders, names in os.walk(top, onerror=failed):
        base = Path(directory)
        folders.sort()
        links = [name for name in folders if (base / name).is_symlink()]
        selection.skipped["link"] += len(links)
        folders[:] = [name for name in folders if name not in links]
        if not recursive:
            folders.clear()
        for name in sorted(names):
            path = base / name
            try:
                status = path.lstat()
            except OSError as error:
                selection.problems.append((path, _reason(error)))
                continue
            if stat.S_ISREG(status.st_mode):
                add(path, status)
            elif stat.S_ISLNK(status.st_mode):
                selection.skipped["link"] += 1
            else:
                selection.skipped["special"] += 1


def _reason(error: OSError) -> str:
    """An OS error as a short sentence, without the path."""
    if error.errno == errno.ENOENT:
        return "Not found"
    if error.errno in (errno.EACCES, errno.EPERM):
        return "Permission denied"
    return error.strerror or str(error)


def open_regular(path: Path) -> io.BufferedReader:
    """Open a regular file for reading; refuse anything else at once.

    O_NONBLOCK keeps the open itself from waiting on a named pipe that
    replaced the file since it was listed; the check after it refuses one.

    Raises:
        OSError: If the file cannot be opened or is not a regular file.
    """
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OSError(errno.EINVAL, "Not a regular file", str(path))
        os.set_blocking(descriptor, True)
        return os.fdopen(descriptor, "rb")
    except BaseException:
        os.close(descriptor)
        raise


def sha256(path: Path) -> str:
    """The SHA-256 digest of a file, in hexadecimal.

    Raises:
        OSError: If the file cannot be read.
    """
    with open_regular(path) as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()
