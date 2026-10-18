"""VS Code's own command line: extension updates and downloads.

``code --update-extensions`` updates an edition's extensions the way the
editor would, against the marketplace, and leaves its lists consistent;
``--install-extension`` downloads a build a repair needs. The tool only runs
them, with the extensions directory named explicitly and without the
variables that would hand the command to a running editor, and passes on
what they print.
"""

import os
import re
import selectors
import signal
import shutil
import subprocess
import time
from collections.abc import Callable, Mapping
from pathlib import Path

from .errors import SyncError
from .host import Edition, Host
from .inventory import servers
from .storage import reason

UPDATE_TIMEOUT = 900
"""How many seconds one edition's update may take."""

_UPDATED = re.compile(r"Extension '([^']+)'.* was successfully updated")
_DETACHED = ("VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "VSCODE_PID")
_NODE_DEPRECATION = re.compile(
    r"\(node:\d+\) \[DEP\d+\] DeprecationWarning: "
    r"|\(Use `.+ --trace-deprecation \.\.\.` to show where the warning was"
)
"""Node's warning about VS Code's own code, and the hint that follows it.

Electron ignores ``NODE_OPTIONS`` when another program starts it, so the
lines are dropped instead of silenced with ``--no-deprecation``.
"""


def find_command(host: Host, edition: Edition) -> Path | None:
    """The edition's command line.

    A desktop edition's is looked up on the host's PATH; a server's is the
    one inside its newest build, which matches the clients that use it.
    """
    if edition.is_server:
        builds = servers(host.server_builds(edition))
        return builds[0].command if builds else None
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
    updated: list[str] = []

    def line(text: str) -> None:
        """Pass on one printed line and note an updated extension."""
        found = _UPDATED.search(text)
        if found and found[1] not in updated:
            updated.append(found[1])
        on_line(text)

    _run(
        command,
        ["--extensions-dir", str(extensions_dir), "--update-extensions"],
        environ,
        line,
        timeout,
        "--update-extensions",
    )
    return tuple(updated)


def install_extension(
    command: Path,
    edition: Edition,
    stage: Path,
    spec: str,
    environ: Mapping[str, str],
    on_line: Callable[[str], None],
    *,
    pre_release: bool = False,
    timeout: float = UPDATE_TIMEOUT,
) -> Path:
    """Download one extension into ``stage``, apart from every real profile.

    VS Code's command line refuses to install an extension a profile lists
    even when its folder is gone, so the build is installed into a scratch
    extensions directory with a scratch data directory, and adopted from
    there. A server names its data directory with its own option.

    Returns:
        The scratch extensions directory, whose ``extensions.json`` lists
        what was installed.

    Raises:
        SyncError: If it cannot start, fails or runs out of time.
    """
    extensions = stage / "extensions"
    data = "--server-data-dir" if edition.is_server else "--user-data-dir"
    arguments = [
        data,
        str(stage / "user"),
        "--extensions-dir",
        str(extensions),
        "--install-extension",
        spec,
    ]
    if pre_release:
        arguments.append("--pre-release")
    _run(
        command,
        arguments,
        environ,
        on_line,
        timeout,
        f"--install-extension {spec}",
    )
    return extensions


def _run(
    command: Path,
    arguments: list[str],
    environ: Mapping[str, str],
    on_line: Callable[[str], None],
    timeout: float,
    what: str,
) -> None:
    """Run VS Code's command line detached from any running editor.

    Every non-empty line it prints reaches ``on_line``, stripped; ``what``
    names the run in an error. The command runs in a session of its own and
    the whole session is killed when it fails, times out or is interrupted:
    ``code`` is a launcher whose Electron child would otherwise go on
    changing the extensions directory after the lock is released.

    Raises:
        SyncError: If it cannot start, fails or runs out of time.
    """
    env = {
        key: value for key, value in environ.items() if key not in _DETACHED
    }
    try:
        process = subprocess.Popen(
            [str(command), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
    except OSError as error:
        raise SyncError(f"Cannot run {command}: {reason(error)}") from None

    def line(text: str) -> None:
        """Pass on one printed line, unless it is empty or Node's noise."""
        text = text.strip()
        if text and not _NODE_DEPRECATION.match(text):
            on_line(text)

    try:
        _pump(process, line, timeout, f"{command.name} {what}")
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        process.wait()
        if process.stdout is not None:
            process.stdout.close()
    if process.returncode != 0:
        raise SyncError(f"{command.name} {what} exited {process.returncode}")


def _pump(
    process: subprocess.Popen[bytes],
    line: Callable[[str], None],
    timeout: float,
    what: str,
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
                    f"{what} took longer than {timeout:.0f} seconds"
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
            f"{what} took longer than {timeout:.0f} seconds"
        ) from None
