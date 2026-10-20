"""Running child processes: literal arguments, bounded in time, no shell.

Every probe goes through ``run``. A child gets an empty standard input, so
nothing can wait for a person, and a session of its own, so a timeout ends
the whole group, including whatever a shim or launcher started, instead of
only the process that was spawned.
"""

import os
import signal
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

TIMED_OUT = 124
"""The status of a child that ran out of time, as coreutils' timeout uses."""

NOT_RUNNABLE = 127
"""The status of a child that could not be started."""

_GRACE = 1.0
"""Seconds between asking a timed-out group to stop and killing it."""

QUIET = {
    "RUSTUP_AUTO_INSTALL": "0",
    "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
    "DOTNET_NOLOGO": "1",
    "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1",
}
"""Variables that disable known automatic installs and .NET telemetry.

rustup otherwise installs a missing toolchain the moment a proxy such as
``rustc`` runs; the .NET muxer otherwise prints a banner and sends
telemetry on its first start.
Selected programs still retain the caller's filesystem and network authority.
"""


@dataclass(frozen=True)
class Outcome:
    """What a child did.

    Attributes:
        status: Its exit status; ``TIMED_OUT`` or ``NOT_RUNNABLE`` when it
            did not finish or never started.
        output: What it printed on standard output, decoded; standard error
            too when the caller asked for it.
    """

    status: int
    output: str

    @property
    def ok(self) -> bool:
        """Whether it finished with status 0."""
        return self.status == 0

    @property
    def timed_out(self) -> bool:
        """Whether it ran out of time."""
        return self.status == TIMED_OUT


def run(
    argv: Sequence[str],
    env: Mapping[str, str],
    timeout: float,
    *,
    errors: bool = False,
    cwd: Path | None = None,
) -> Outcome:
    """Run ``argv`` and collect what it prints.

    Args:
        argv: The program and its arguments, used as they are.
        env: The environment; only absolute PATH entries reach children.
        timeout: Seconds before the child's group is stopped.
        errors: Whether standard error joins the output instead of being
            discarded.
        cwd: The working directory, by default the caller's.
    """
    if not argv:
        return Outcome(NOT_RUNNABLE, "")
    path = (
        os.pathsep.join(
            entry
            for entry in env.get("PATH", "").split(os.pathsep)
            if os.path.isabs(entry)
        )
        or os.devnull
    )
    try:
        child = subprocess.Popen(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if errors else subprocess.DEVNULL,
            env={**env, **QUIET, "PATH": path},
            cwd=cwd,
            start_new_session=True,
        )
    except OSError:
        return Outcome(NOT_RUNNABLE, "")
    try:
        output, _ = child.communicate(timeout=max(timeout, 0.1))
    except subprocess.TimeoutExpired:
        _stop(child)
        return Outcome(TIMED_OUT, "")
    finally:
        if child.poll() is None:
            _stop(child)
    return Outcome(child.returncode, output.decode("utf-8", "replace"))


def _stop(child: subprocess.Popen[bytes]) -> None:
    """End a child's whole process group: TERM, then KILL after a grace.

    The KILL goes to the group even when the child itself has exited, since
    whatever it started may have ignored the TERM.
    """
    for sent in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sent)
        except (ProcessLookupError, PermissionError):
            break
        if sent == signal.SIGTERM:
            try:
                child.wait(timeout=_GRACE)
            except subprocess.TimeoutExpired:
                pass
    try:
        child.communicate(timeout=_GRACE)
    except subprocess.TimeoutExpired:
        if child.stdout is not None:
            child.stdout.close()
