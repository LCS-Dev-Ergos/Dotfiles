"""The guards around a run that changes anything.

A changing run holds an exclusive lock, so two runs never interleave; it
refuses while either edition of VS Code is running, because VS Code rewrites
its extension lists while it runs; and it asks before it starts. Without a
terminal to ask on, only ``--yes`` lets it go ahead.
"""

import fcntl
import os
import shutil
import subprocess
import sys
from collections.abc import Generator, Iterable, Mapping
from contextlib import contextmanager
from pathlib import Path

import terminal_style as ui

from . import PROG
from .errors import SyncError
from .host import Edition, Host, Platform
from .storage import private_dir, reason

GUM_DECLINED = 1
GUM_INTERRUPTED = 130


@contextmanager
def locked(state_dir: Path) -> Generator[None, None, None]:
    """Hold the state directory's lock for the duration of the block.

    Raises:
        SyncError: If another run holds it, or it cannot be taken.
    """
    path = private_dir(state_dir) / "lock"
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as error:
        raise SyncError(f"cannot open {path}: {reason(error)}") from None
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SyncError(f"another {PROG} run is in progress") from None
        except OSError as error:
            raise SyncError(f"cannot lock {path}: {reason(error)}") from None
        yield
    finally:
        os.close(descriptor)


def running_editions(
    host: Host, processes: Iterable[str] | None = None
) -> set[Edition]:
    """The editions of VS Code that have a process running.

    Args:
        host: The machine, whose platform decides how processes look.
        processes: Command lines to inspect; default: every process's.

    Raises:
        SyncError: If the process list cannot be read; not knowing counts
            as running.
    """
    lines = list(processes) if processes is not None else _process_list(host)
    found: set[Edition] = set()
    for line in lines:
        for edition in Edition:
            if _belongs_to(host, edition, line):
                found.add(edition)
    return found


def confirm(
    question: str,
    style: ui.Style,
    environ: Mapping[str, str],
    *,
    stdin_is_terminal: bool | None = None,
) -> bool:
    """Ask a yes-or-no question, defaulting to no.

    Gum asks on a styled terminal when it is installed, themed like every
    shell tool; otherwise a line prompt does.

    Raises:
        SyncError: Without a terminal on stdin, or if Gum fails.
    """
    if stdin_is_terminal is None:
        stdin_is_terminal = sys.stdin.isatty()
    if not stdin_is_terminal:
        raise SyncError(
            "nothing is changed without a terminal to confirm on; "
            "pass --yes to go ahead"
        )
    gum = shutil.which("gum", path=environ.get("PATH", os.defpath))
    if style.styled and gum:
        command = [gum, "confirm", "--default=false", "--", question]
        status = subprocess.run(
            command, env={**environ, **ui.GUM_THEME}, check=False
        ).returncode
        if status in (0, GUM_DECLINED, GUM_INTERRUPTED):
            return status == 0
        raise SyncError(f"gum confirm exited {status}")
    try:
        answer = input(f"{question} [y/N] ")
    except EOFError:
        return False
    return answer.strip().lower() in ("y", "yes")


def _process_list(host: Host) -> list[str]:
    """Every process's command line, from ``ps``.

    Raises:
        SyncError: If ``ps`` cannot be run.
    """
    ps = shutil.which("ps", path=host.search_path()) or "/bin/ps"
    try:
        completed = subprocess.run(
            [ps, "-A", "-o", "args="],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise SyncError(
            f"cannot tell whether VS Code is running: {reason(error)}"
        ) from None
    return completed.stdout.splitlines()


def _belongs_to(host: Host, edition: Edition, line: str) -> bool:
    """Whether a command line is one of an edition's processes.

    A server runs the programs of one of its builds, below ``cli/servers``
    or ``bin``; the tunnel service next to them only relays connections and
    does not count. On macOS every process of a desktop edition runs from
    inside its application bundle. On Linux the editor and its helpers run
    its own binary, which the packages install under the command's name.
    """
    executable = line.split(" ", 1)[0]
    if edition.is_server:
        root = host.home / edition.dot_directory
        return any(
            executable.startswith(f"{root / part}/")
            for part in ("cli/servers", "bin")
        )
    if host.platform is Platform.DARWIN:
        return f"/{edition.application}/Contents/" in line
    return os.path.basename(executable) == edition.command
