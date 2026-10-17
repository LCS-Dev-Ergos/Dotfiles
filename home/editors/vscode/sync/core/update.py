"""VS Code's own extension update, run through each edition's command.

``code --update-extensions`` updates an edition's extensions the way the
editor would, against the marketplace, and leaves its lists consistent. The
tool only runs it, with the edition's extensions directory named explicitly
and without the variables that would hand the command to a running editor,
and passes on what it prints.
"""

import os
import re
import selectors
import shutil
import subprocess
import time
from collections.abc import Callable, Mapping
from pathlib import Path

from .errors import SyncError
from .host import Edition, Host
from .storage import reason

UPDATE_TIMEOUT = 900
"""How many seconds one edition's update may take."""

_UPDATED = re.compile(r"Extension '([^']+)'.* was successfully updated")
_DETACHED = ("VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "VSCODE_PID")


def find_command(host: Host, edition: Edition) -> Path | None:
    """The edition's command on the host's PATH."""
    found = shutil.which(edition.command, path=host.search_path())
    return Path(found) if found else None


def update_extensions(
    command: Path,
    extensions_dir: Path,
    environ: Mapping[str, str],
    on_line: Callable[[str], None],
    timeout: float = UPDATE_TIMEOUT,
) -> tuple[str, ...]:
    """Run an edition's extension update, passing on each line it prints.

    Returns:
        The extensions it reported as updated, in order.

    Raises:
        SyncError: If it cannot start, fails or runs out of time.
    """
    env = {
        key: value for key, value in environ.items() if key not in _DETACHED
    }
    arguments = [
        str(command),
        "--extensions-dir",
        str(extensions_dir),
        "--update-extensions",
    ]
    try:
        process = subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
        )
    except OSError as error:
        raise SyncError(f"cannot run {command}: {reason(error)}") from None
    updated: list[str] = []

    def line(text: str) -> None:
        """Pass on one printed line and note an updated extension."""
        text = text.strip()
        if not text:
            return
        found = _UPDATED.search(text)
        if found and found[1] not in updated:
            updated.append(found[1])
        on_line(text)

    try:
        _pump(process, line, timeout)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if process.stdout is not None:
            process.stdout.close()
    if process.returncode != 0:
        raise SyncError(
            f"{command.name} --update-extensions exited {process.returncode}"
        )
    return tuple(updated)


def _pump(
    process: subprocess.Popen[bytes],
    line: Callable[[str], None],
    timeout: float,
) -> None:
    """Read the process's output into lines until it ends or time runs out.

    Output is read in chunks, so a line without an end never blocks the
    reading, and the deadline holds even when the process prints nothing.

    Raises:
        SyncError: When the deadline passes.
    """
    assert process.stdout is not None
    deadline = time.monotonic() + timeout
    pending = b""
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SyncError(
                    f"the update took longer than {timeout:.0f} seconds"
                )
            if not selector.select(timeout=min(remaining, 1.0)):
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            pending += chunk
            *complete, pending = pending.split(b"\n")
            for raw in complete:
                line(raw.decode("utf-8", "replace"))
    if pending:
        line(pending.decode("utf-8", "replace"))
    try:
        process.wait(timeout=max(deadline - time.monotonic(), 1.0))
    except subprocess.TimeoutExpired:
        raise SyncError(
            f"the update took longer than {timeout:.0f} seconds"
        ) from None
