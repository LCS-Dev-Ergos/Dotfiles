"""Homebrew's installed packages and the disk they take.

A report never mixes two moments: the inventory is read once, every entry is
resolved to its canonical directory inside the Cellar or the Caskroom, and
the inventory is read again after measuring; a change in between fails the
report. Sizes are what ``du -sk`` allocates, so a file several formulae
share through hard links counts once.

A cask's Caskroom entry links to the artifacts it installed, such as an app
in /Applications. Only the outermost link targets are measured, and only
inside the install roots the cask recorded in ``.metadata/config.json``, so
an app bundle's own links, which can cycle, are never followed. A link that
is broken or points elsewhere is left out and named instead.
"""

import json
import os
import re
import subprocess
from collections.abc import Iterable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import cast

TIMEOUT = 300.0
"""Seconds one ``brew`` or ``du`` may take."""

_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_KINDS = {
    "formula": ("formula", "--cellar", "Cellar"),
    "cask": ("cask", "--caskroom", "Caskroom"),
}


class BrewError(Exception):
    """Something makes a trustworthy report impossible."""


@dataclass(frozen=True)
class Package:
    """One installed package.

    Attributes:
        name: Its directory name in the Cellar or Caskroom.
        kind: ``formula`` or ``cask``.
        kb: The kilobytes it takes.
        unmeasured: Artifacts left out, and why.
    """

    name: str
    kind: str
    kb: int
    unmeasured: tuple[str, ...] = ()


@dataclass(frozen=True)
class Inventory:
    """What ``brew list`` said, and where each entry lives.

    Attributes:
        kind: ``formula`` or ``cask``.
        listing: The listing as printed, to compare with later.
        directories: The canonical package directories.
        root: The canonical Cellar or Caskroom.
    """

    kind: str
    listing: str
    directories: tuple[Path, ...] = ()
    root: Path | None = None


@dataclass
class Homebrew:
    """The ``brew`` command and the environment it and ``du`` run with."""

    brew: str
    env: Mapping[str, str] = field(default_factory=dict[str, str])

    def run(self, *arguments: str) -> str:
        """Run ``brew``; what it printed.

        Raises:
            BrewError: If it cannot run, fails or runs out of time.
        """
        return _run([self.brew, *arguments], self.env)

    def inventory(self, kind: str) -> Inventory:
        """The installed formulae or casks, each resolved and checked.

        Raises:
            BrewError: If the listing cannot be read, an entry's directory
                is missing, or one resolves outside its root.
        """
        noun, option, label = _KINDS[kind]
        try:
            listing = self.run("list", f"--{kind}")
        except BrewError:
            raise BrewError(
                f"Could not read the installed {noun} inventory"
            ) from None
        names = [line for line in listing.splitlines() if line]
        if not names:
            return Inventory(kind, listing)
        root = _directory(self.run(option).strip(), f"Homebrew {label}")
        found: dict[Path, None] = {}
        for name in names:
            if "/" in name or name in (".", "..") or _CONTROL.search(name):
                raise BrewError(f"Invalid {noun} name in the inventory")
            entry = root / name
            if not (entry.is_dir() if kind == "formula" else entry.exists()):
                raise BrewError(f"The {noun} directory is missing: {name}")
            real = Path(os.path.realpath(entry))
            if not real.is_dir():
                raise BrewError(f"Invalid {noun} directory: {name}")
            if not real.is_relative_to(root) or real == root:
                raise BrewError(f"The {noun} {name} escapes the {label}")
            found.setdefault(real)
        return Inventory(kind, listing, tuple(found), root)

    def recheck(self, inventory: Inventory) -> None:
        """Fail if the inventory changed since it was read.

        Raises:
            BrewError: If it cannot be read again or is different now.
        """
        try:
            current = self.run("list", f"--{inventory.kind}")
        except BrewError:
            raise BrewError(
                f"Could not read the {inventory.kind} inventory again"
            ) from None
        if current != inventory.listing:
            raise BrewError(
                f"The installed {inventory.kind} inventory changed; "
                "run the report again"
            )

    def cache(self) -> tuple[Path, int]:
        """The download cache and the kilobytes it takes.

        Raises:
            BrewError: If its path is unusable or it cannot be measured.
        """
        try:
            text = self.run("--cache").strip()
        except BrewError:
            raise BrewError("Could not resolve the Homebrew cache") from None
        if not text.startswith("/") or _CONTROL.search(text):
            raise BrewError("Invalid Homebrew cache path")
        path = Path(text)
        if path.is_symlink() and not path.exists():
            raise BrewError("The Homebrew cache path is a broken symlink")
        real = Path(os.path.realpath(path))
        if real == Path("/"):
            raise BrewError("Refusing to use / as the Homebrew cache")
        if not real.exists():
            return real, 0
        if not real.is_dir():
            raise BrewError("The Homebrew cache path is not a directory")
        return real, du([real], self.env, "the Homebrew cache")[real]

    def formulae(self, inventory: Inventory) -> list[Package]:
        """Every formula measured in one ``du``, so shared links count once.

        Raises:
            BrewError: If a directory cannot be measured.
        """
        sizes = du(inventory.directories, self.env, "formula")
        return [
            Package(path.name, "formula", sizes[path])
            for path in inventory.directories
        ]

    def casks(self, inventory: Inventory) -> list[Package]:
        """Every cask with its outermost linked artifacts, side by side.

        Raises:
            BrewError: If a directory cannot be measured.
        """
        with ThreadPoolExecutor(max_workers=8) as pool:
            return list(pool.map(self._cask, inventory.directories))

    def _cask(self, directory: Path) -> Package:
        """One cask: its Caskroom entry and the artifacts it may claim."""
        targets, unmeasured = artifacts(directory)
        sizes = du([directory, *targets], self.env, f"cask {directory.name}")
        return Package(
            directory.name, "cask", sum(sizes.values()), tuple(unmeasured)
        )


def artifacts(directory: Path) -> tuple[list[Path], list[str]]:
    """A cask's outermost artifact targets, and the links left out.

    The links are found without following any; a target inside the cask's
    own directory is already measured.
    """
    targets: set[Path] = set()
    unmeasured: list[str] = []
    roots: list[Path] | None = None
    for link in _links(directory):
        shown = link.relative_to(directory)
        if not link.exists():
            unmeasured.append(f"{shown}: broken link")
            continue
        target = Path(os.path.realpath(link))
        if target.is_relative_to(directory):
            continue
        if roots is None:
            roots = artifact_roots(directory)
        if not any(target.is_relative_to(root) for root in roots):
            unmeasured.append(f"{shown}: outside the recorded install roots")
            continue
        targets.add(target)
    outermost = [
        target
        for target in targets
        if not any(parent in targets for parent in target.parents)
    ]
    return sorted(outermost), unmeasured


def _links(directory: Path) -> Iterable[Path]:
    """Every symlink below ``directory``, without following any."""
    for parent, directories, files in os.walk(directory):
        for name in (*directories, *files):
            path = Path(parent) / name
            if path.is_symlink():
                yield path


def artifact_roots(directory: Path) -> list[Path]:
    """The absolute install roots a cask recorded, if its record is safe.

    The record is ``.metadata/config.json``: it must be a regular file, not
    a link, owned by this user and writable by nobody else. Its ``default``
    and ``explicit`` objects map artifact kinds to roots, explicit winning.
    """
    record = directory / ".metadata" / "config.json"
    try:
        status = record.lstat()
    except OSError:
        return []
    insecure = status.st_uid != os.geteuid() or status.st_mode & 0o022
    if not record.is_file() or record.is_symlink() or insecure:
        return []
    try:
        data: object = json.loads(record.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    merged: dict[str, object] = {}
    for key in ("default", "explicit"):
        merged.update(_object(_object(data).get(key)))
    roots: list[Path] = []
    for value in merged.values():
        if isinstance(value, str) and value.startswith("/"):
            if not _CONTROL.search(value):
                real = Path(os.path.realpath(value))
                if real != Path("/"):
                    roots.append(real)
    return roots


def _object(value: object) -> dict[str, object]:
    """A JSON object as a dictionary; anything else as an empty one.

    JSON object keys are always strings, so the cast only names what the
    parser produced.
    """
    if isinstance(value, dict):
        return cast("dict[str, object]", value)
    return {}


def du(
    paths: Sequence[Path], env: Mapping[str, str], what: str
) -> dict[Path, int]:
    """The kilobytes ``du -sk`` allocates for each path, in one call.

    Raises:
        BrewError: If ``du`` fails or prints something unexpected; a
            failure names the first path that cannot be measured.
    """
    if not paths:
        return {}
    try:
        output = _run(["du", "-sk", "--", *map(str, paths)], env)
    except BrewError:
        for path in paths:
            try:
                _run(["du", "-sk", "--", str(path)], env)
            except BrewError:
                raise BrewError(
                    f"Could not measure {what}: {path.name}"
                ) from None
        raise BrewError(f"Could not measure {what}") from None
    sizes: dict[Path, int] = {}
    for line in output.splitlines():
        kb, tab, measured = line.partition("\t")
        if not tab or not kb.isdigit():
            raise BrewError(f"Unexpected du output for {what}")
        sizes[Path(measured)] = int(kb)
    missing = [path for path in paths if path not in sizes]
    if missing:
        raise BrewError(f"Unexpected du output for {what}: {missing[0].name}")
    return sizes


def _directory(text: str, label: str) -> Path:
    """A canonical directory a ``brew`` option printed.

    Raises:
        BrewError: If it is not an absolute directory, or is ``/``.
    """
    if not text.startswith("/") or _CONTROL.search(text):
        raise BrewError(f"Invalid {label} path")
    real = Path(os.path.realpath(text))
    if real == Path("/"):
        raise BrewError(f"Refusing to use / as the {label}")
    if not real.is_dir():
        raise BrewError(f"Could not resolve the {label}")
    return real


def _run(argv: Sequence[str], env: Mapping[str, str]) -> str:
    """Run a command with literal arguments and no input; its output.

    Raises:
        BrewError: If it cannot run, fails or runs out of time.
    """
    try:
        done = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            env=dict(env),
            timeout=TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BrewError(f"Cannot run {argv[0]}: {error}") from None
    if done.returncode != 0:
        raise BrewError(f"{argv[0]} exited {done.returncode}")
    return done.stdout.decode("utf-8", "replace")


def human(kb: int) -> str:
    """A size for people: ``3.4 GB``."""
    value = float(kb)
    units = ("KB", "MB", "GB", "TB", "PB")
    index = 0
    while value >= 1024 and index < len(units) - 1:
        value /= 1024
        index += 1
    return f"{value:.1f} {units[index]}"
