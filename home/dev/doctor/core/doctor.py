"""Checking the registry: one record per runtime, then PATH and updates.

A check reads files and starts the runtime's own version and startup
commands; it never initializes a manager, installs a runtime or reaches the
network. The remote tier, ``updates``, is separate, opt-in and cached.
"""

import dataclasses
import json
import os
import re
import tempfile
import time
from collections.abc import Callable, Iterable, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from . import DOCTOR, process
from .compilers import selected
from .host import Host, Origin
from .jsondata import as_array, as_object
from .registry import (
    EMPTY,
    STARTS_WITH_VERSION,
    Group,
    InRoot,
    Managed,
    OnPath,
    Presence,
    Probe,
    Run,
    Runtime,
    Version,
)
from .versions import first_line, token

MAX_JOBS = 16
"""The most checks that run at once."""


class State(Enum):
    """What a check concluded, in the order the summary counts them."""

    OK = "ok"
    OUTDATED = "outdated"
    DORMANT = "dormant"
    UNUSED = "unused"
    SHADOWED = "shadowed"
    UNKNOWN = "unknown"
    BROKEN = "broken"
    ABSENT = "absent"

    @property
    def rank(self) -> int:
        """Its share of the exit status: 2 broken, 1 doubtful, 0 fine."""
        if self is State.BROKEN:
            return 2
        return 1 if self in (State.SHADOWED, State.UNKNOWN) else 0

    @property
    def tone(self) -> str:
        """The terminal style tone of its marker."""
        return {
            State.OK: "ok",
            State.OUTDATED: "pending",
            State.SHADOWED: "warn",
            State.UNKNOWN: "warn",
            State.BROKEN: "error",
        }.get(self, "muted")


@dataclass(frozen=True)
class Record:
    """The outcome of one check.

    Attributes:
        runtime: What was checked.
        state: The conclusion.
        active: The active version, or ``-``.
        origin: Where the runtime's binary comes from, or ``-``.
        detail: Why, or what was found, in one line.
    """

    runtime: Runtime
    state: State
    active: str = "-"
    origin: str = "-"
    detail: str = ""


@dataclass(frozen=True)
class Conflict:
    """Something on PATH that makes the answers less trustworthy.

    Attributes:
        kind: ``stale entry``, ``empty shims``, ``shim priority``,
            ``shadowed binary`` or ``npm globals``.
        subject: The directory, binary or prefix concerned.
        detail: What is wrong with it.
    """

    kind: str
    subject: str
    detail: str

    @property
    def rank(self) -> int:
        """A shadowed binary is how this machine normally looks; 0."""
        return 0 if self.kind == "shadowed binary" else 1


# Checks -----------------------------------------------------------------------


def check_all(
    runtimes: Sequence[Runtime], host: Host, timeout: float, jobs: int
) -> list[Record]:
    """Check every runtime, several at once, in the order given.

    A check that raises becomes an ``unknown`` record naming the error,
    so one faulty probe cannot hide the others.
    """
    workers = max(1, min(jobs or len(runtimes), MAX_JOBS))

    def guarded(runtime: Runtime) -> Record:
        """One check, whatever it raises."""
        try:
            return check(runtime, host, timeout)
        except Exception as error:  # noqa: BLE001
            return Record(
                runtime, State.UNKNOWN, detail=f"Check failed: {error}"
            )

    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(guarded, runtimes))


def check(runtime: Runtime, host: Host, timeout: float) -> Record:
    """Check one runtime: presence, root, versions, startup and origin."""
    roots = runtime.resolve_roots(host)
    root = roots[0] if roots else None
    present, root = _present(runtime.presence, Probe(host, root, timeout))
    if not present:
        return Record(runtime, State.ABSENT)
    if root is not None:
        roots[:1] = [root]
        if not root.is_dir():
            missing = host.shorten(str(root))
            return Record(
                runtime, State.BROKEN, detail=f"Root missing: {missing}"
            )
    probe = Probe(host, root, timeout)

    binary = binary_of(runtime, host)
    managed = _managed(runtime.managed, probe)
    dormant = runtime.activated is not None and not runtime.activated(host)
    state, active, detail = State.OK, "-", ""

    status = 0
    if runtime.startup == STARTS_WITH_VERSION and (dormant or managed == 0):
        pass
    elif runtime.version is not None:
        status, found = _version(runtime.version, probe)
        if status == 0:
            active = found
        elif not dormant and managed != 0:
            state, detail = State.UNKNOWN, "Version probe failed or timed out"

    if runtime.startup is not None and not dormant and managed != 0:
        started = status
        if isinstance(runtime.startup, Run):
            started, found = _version(runtime.startup, probe)
            if started == 0:
                active = found
        if started == 0:
            detail = detail or "Runtime starts"
        else:
            active = "-"
            if started == process.TIMED_OUT:
                state, detail = State.UNKNOWN, "Runtime probe timed out"
            elif started == EMPTY:
                state, detail = (
                    State.UNKNOWN,
                    "Runtime probe returned no version",
                )
            else:
                state = State.BROKEN
                detail = (
                    f"Runtime probe failed (exit {started}): {binary or '-'}"
                )

    path = host.which(binary) if binary else None
    origin = "-"
    if binary and path is not None:
        found_origin = host.origin(path, roots)
        origin = found_origin.value
        if found_origin is not Origin.MANAGER and state is State.OK:
            if managed and dormant:
                state = State.DORMANT
                detail = f"Not activated here; {binary} comes from {origin}"
            elif managed:
                state = State.SHADOWED
                where = host.shorten(str(path))
                detail = f"{binary} resolves to {origin}: {where}"
            elif managed == 0:
                state = State.UNUSED
                detail = f"No managed versions; {binary} comes from {origin}"
    elif managed == 0 and state is State.OK:
        state, detail = State.UNUSED, "No managed versions installed"

    if not detail and managed is not None:
        detail = f"{managed} managed"
    if dormant and state is State.OK:
        state, detail = (
            State.DORMANT,
            "Not activated here; runtime probe skipped",
        )
    if state is State.OK and runtime.compiler is not None:
        shown = str(path) if path is not None else (binary or "")
        detail = host.shorten(shown)
        if shown.startswith("/nix/store/"):
            detail += " (store-pinned)"
    elif state is State.OK and runtime.healthy:
        detail = runtime.healthy

    if state is State.OK and runtime.verdict is not None:
        verdict = runtime.verdict(probe)
        if verdict.level == 1:
            state = State.UNKNOWN
        elif verdict.level > 1:
            state = State.BROKEN
        detail = verdict.text or detail
    return Record(
        runtime, state, _field(active) or "-", origin, _field(detail)
    )


def binary_of(runtime: Runtime, host: Host) -> str | None:
    """The command PATH should resolve to the runtime, if any.

    For the compiler rows it is the first word of ``CC`` or ``CXX``: the
    compiler itself, or a launcher such as ccache.
    """
    if runtime.compiler is not None:
        return selected(host, runtime.compiler)[0]
    return runtime.binary


def _present(spec: Presence, probe: Probe) -> tuple[bool, Path | None]:
    """Whether the runtime is installed, and its root once known."""
    host, root = probe.host, probe.root
    match spec:
        case OnPath(name=name):
            return host.which(name) is not None, root
        case InRoot(relative=relative):
            if root is None:
                return False, root
            target = root / relative if relative else root
            usable = target.is_dir() if not relative else target.exists()
            return usable and os.access(target, os.R_OK), root
        case _:
            answer = spec(probe)
            if isinstance(answer, Path):
                return True, answer
            return answer, root


def _version(spec: Version | Run, probe: Probe) -> tuple[int, str]:
    """Run a version or startup probe; its status and the version it read.

    A command whose program is missing is ``NOT_RUNNABLE``; one that prints
    no version is ``EMPTY``.
    """
    match spec:
        case Run(argv=argv):
            program = probe.host.which(argv[0])
            if program is None:
                return process.NOT_RUNNABLE, ""
            outcome = probe.run(str(program), *argv[1:])
        case _:
            outcome = spec(probe)
    if not outcome.ok:
        return outcome.status or 1, ""
    found = token(outcome.output)
    return (0, found) if found else (EMPTY, "")


def _managed(spec: Managed | None, probe: Probe) -> int | None:
    """How many versions the manager keeps; ``None`` when it cannot say.

    Managers mark the active entry with a leading ``*`` or indent it; it
    still counts.
    """
    match spec:
        case None:
            return None
        case Run(argv=argv):
            program = probe.host.which(argv[0])
            if program is None:
                return None
            outcome = probe.run(str(program), *argv[1:])
            if not outcome.ok:
                return None
            lines = outcome.output.splitlines()
        case _:
            listed = spec(probe)
            if listed is None:
                return None
            lines = listed
    entries = (line.strip().removeprefix("*").strip() for line in lines)
    return sum(1 for entry in entries if entry)


def _field(text: str) -> str:
    """Text on one line, whatever a probe printed."""
    return re.sub(r"[\t\r\n]+", " ", text).strip()


def order(records: Iterable[Record]) -> list[Record]:
    """Records by group, in report order, then by label."""
    groups = list(Group)
    return sorted(
        records,
        key=lambda r: (
            groups.index(r.runtime.group),
            r.runtime.label.casefold(),
        ),
    )


# PATH -------------------------------------------------------------------------


def path_conflicts(
    host: Host, binaries: Iterable[str], managed: Iterable[str]
) -> list[Conflict]:
    """What PATH itself gets wrong.

    Reports entries that do not exist, shim directories without shims,
    shims that come after a package manager's directory (lib/90-path.zsh
    puts them first on purpose; losing that order is how rbenv and pyenv
    silently stop answering), and binaries several origins provide. A
    binary a manager already answers for, or one the system also ships
    behind a chosen toolchain, is not a conflict.

    Args:
        host: The machine.
        binaries: The runtimes' binaries.
        managed: The binaries that resolve to their manager.
    """
    conflicts: list[Conflict] = []
    first_shim = first_package = 0
    entries = host.path_entries()
    packages = _package_directories(host)
    for index, entry in enumerate(entries, 1):
        if not entry:
            continue
        shown = host.shorten(entry)
        if not os.path.isdir(entry):
            conflicts.append(
                Conflict("stale entry", shown, "Directory does not exist")
            )
            continue
        if entry.endswith("/shims"):
            first_shim = first_shim or index
            if not any(Path(entry).iterdir()):
                conflicts.append(
                    Conflict(
                        "empty shims",
                        shown,
                        "On PATH but the manager installed no shims",
                    )
                )
        if not first_package and (
            entry.startswith(packages[0]) or entry in packages[1]
        ):
            first_package = index
    if first_shim and first_package and first_shim > first_package:
        conflicts.append(
            Conflict(
                "shim priority",
                host.shorten(entries[first_shim - 1]),
                f"Resolved after {host.shorten(entries[first_package - 1])}",
            )
        )
    winners = set(managed)
    for binary in dict.fromkeys(binaries):
        if binary in winners or "/" in binary:
            continue
        matches = host.which_all(binary)
        if len(matches) < 2:
            continue
        system_wins = host.origin(matches[0]) is Origin.SYSTEM
        resolved: dict[str, None] = {}
        for match in matches:
            if not system_wins and host.origin(match) is Origin.SYSTEM:
                continue
            resolved.setdefault(os.path.realpath(match))
        if len(resolved) > 1:
            winner = host.shorten(str(matches[0]))
            conflicts.append(
                Conflict(
                    "shadowed binary",
                    binary,
                    f"{len(resolved)} origins, winner {winner}",
                )
            )
    return conflicts


def _package_directories(host: Host) -> tuple[tuple[str, ...], set[str]]:
    """Where a package manager's binaries live: prefixes, then directories."""
    prefixes = (
        "/nix/store/",
        "/etc/profiles/per-user/",
        "/run/current-system/sw/",
        f"{host.home}/.nix-profile/",
        f"{host.home}/.local/state/nix/profiles/",
    )
    brew = {f"{host.brew_prefix()}/bin", "/opt/homebrew/bin", "/usr/local/bin"}
    return prefixes, brew


def npm_conflict(
    host: Host, roots: Iterable[Path], timeout: float
) -> Conflict | None:
    """npm's global prefix, when it lies inside a managed Node version.

    npm installs global CLIs into the active Node version by default, so
    selecting another default or deleting that version takes every global
    tool with it; the shell setup pins NPM_CONFIG_PREFIX outside the tree.
    Only a shell without the pin pays for asking npm.
    """
    npm = host.which("npm")
    if npm is None:
        return None
    prefix = host.get("NPM_CONFIG_PREFIX")
    if not prefix:
        asked = process.run(
            (str(npm), "config", "get", "prefix"), host.env, timeout
        )
        prefix = first_line(asked.output) if asked.ok else ""
    if not prefix or prefix in ("undefined", "null"):
        return None
    for root in roots:
        if prefix.startswith(f"{str(root).rstrip('/')}/"):
            return Conflict(
                "npm globals",
                host.shorten(prefix),
                "Inside a managed version tree; they vanish with that version",
            )
    return None


# Updates ----------------------------------------------------------------------


@dataclass(frozen=True)
class Updates:
    """What the managers' own update checks reported.

    Attributes:
        formulas: Homebrew formulas with a newer release.
        managers: Registry ids whose manager has an update.
    """

    formulas: frozenset[str] = field(default_factory=frozenset[str])
    managers: frozenset[str] = field(default_factory=frozenset[str])


def updates(
    host: Host,
    *,
    refresh: bool,
    ttl: float,
    timeout: float,
    now: Callable[[], float] = time.time,
) -> Updates:
    """Ask the managers with a machine-readable check, or read the cache.

    Homebrew is asked once for every formula; rustup through ``rustup
    check``. Managers without such a check are left out deliberately. The
    answer is cached for ``ttl`` seconds in a file only the user can read.
    """
    cache = host.cache_home() / DOCTOR / "updates.json"
    if not refresh:
        cached = _read_cache(cache, ttl, now())
        if cached is not None:
            return cached
    formulas: set[str] = set()
    managers: set[str] = set()
    brew = host.which("brew")
    if brew is not None:
        outdated = process.run(
            (str(brew), "outdated", "--quiet"), host.env, timeout * 2
        )
        if outdated.ok:
            formulas = {
                line.strip().rsplit("/", 1)[-1]
                for line in outdated.output.splitlines()
                if line.strip()
            }
    rustup = host.which("rustup")
    if rustup is not None:
        checked = process.run((str(rustup), "check"), host.env, timeout)
        if checked.ok and "Update available" in checked.output:
            managers.add("rustup")
    found = Updates(frozenset(formulas), frozenset(managers))
    _write_cache(cache, found, now())
    return found


def _read_cache(path: Path, ttl: float, now: float) -> Updates | None:
    """A cached answer younger than ``ttl``, or ``None``."""
    try:
        data = as_object(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return None
    if data is None:
        return None
    stamp = data.get("time")
    if not isinstance(stamp, int | float) or not 0 <= now - stamp < ttl:
        return None
    lists: list[frozenset[str]] = []
    for key in ("formulas", "managers"):
        items = as_array(data.get(key))
        if items is None or not all(isinstance(i, str) for i in items):
            return None
        lists.append(frozenset(str(item) for item in items))
    return Updates(lists[0], lists[1])


def _write_cache(path: Path, found: Updates, now: float) -> None:
    """Replace the cache atomically; skip a cache that cannot be written."""
    data = {
        "time": now,
        "formulas": sorted(found.formulas),
        "managers": sorted(found.managers),
    }
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, name = tempfile.mkstemp(
            dir=path.parent, prefix=".updates."
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(data, stream)
        os.replace(name, path)
    except OSError:
        return


def apply_updates(records: Iterable[Record], found: Updates) -> list[Record]:
    """Mark healthy runtimes with an update as ``outdated``, with the fix."""
    marked: list[Record] = []
    for record in records:
        runtime = record.runtime
        due = runtime.id in found.managers or (
            runtime.formula is not None and runtime.formula in found.formulas
        )
        if record.state is State.OK and due:
            record = dataclasses.replace(
                record, state=State.OUTDATED, detail=runtime.hint or ""
            )
        marked.append(record)
    return marked
