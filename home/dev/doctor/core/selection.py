"""Choosing a C/C++ compiler pair for one shell, and undoing the choice.

``toolchain env llvm|gnu|system`` works out the change and prints it as
shell code; the ``use_llvm``, ``use_gnu`` and ``use_system`` functions
evaluate it, since no child process can change its parent's environment.
The shell keeps what the next call needs in ``_TOOLCHAIN_STATE``, an
unexported variable it hands back with ``--state``.

- A pair is a C and a C++ compiler from the same directory, both reporting
  the family asked for: Clang for ``llvm``, a GNU compiler (whose banner
  credits the Free Software Foundation) for ``gnu``. Inside a directory the
  highest versioned pair (``gcc-16``/``g++-16``) wins over unversioned
  names, as Homebrew's GCC only installs versioned ones.
- On macOS the first such pair on PATH wins: the Nix host drivers, built
  against the host SDK, come first by design; Homebrew's GCC keg is the
  last resort for ``gnu``. On Linux the distribution's compilers win, as
  only they search its headers; versioned LLVM directories
  (``/usr/lib/llvm-18/bin``) come first, and PATH is the last resort.
- ``CC`` and ``CXX`` become absolute paths. PATH gains the pair's directory
  only when it lacks it, and loses only a directory a switch added, so any
  other change to PATH survives every switch.
- The first switch away from the system remembers ``CC`` and ``CXX``;
  ``system`` restores them. Nothing else is touched.
- Both compilers are started before anything is printed, so a pair that
  does not run leaves the shell exactly as it was.
"""

import json
import re
import shlex
from collections.abc import Iterable
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from .compilers import Identity, Kind, identify
from .host import Host, Platform
from .jsondata import as_object

STATE_VERSION = 1
"""The version of the ``--state`` document."""

_VARIABLES = ("CC", "CXX")
_LLVM_DIRECTORIES = ("/usr/lib", "/usr/lib64", "/usr/local", "/opt")
_LLVM_NAME = re.compile(r"llvm-?(\d+)?")


class Toolchain(Enum):
    """What a shell can select."""

    LLVM = "llvm"
    GNU = "gnu"
    SYSTEM = "system"

    @property
    def title(self) -> str:
        """How the report names it."""
        return {
            Toolchain.LLVM: "LLVM/Clang",
            Toolchain.GNU: "GNU GCC",
            Toolchain.SYSTEM: "System",
        }[self]

    @property
    def names(self) -> tuple[str, str]:
        """The C and C++ compiler names."""
        if self is Toolchain.GNU:
            return "gcc", "g++"
        return "clang", "clang++"


@dataclass(frozen=True)
class State:
    """What the shell remembers between switches.

    Attributes:
        active: The selected toolchain.
        added: The directory a switch put on PATH, if any.
        baseline: ``CC`` and ``CXX`` before the first switch; ``None`` for
            a variable that was unset. Empty once back on the system.
    """

    active: Toolchain
    added: str | None = None
    baseline: dict[str, str | None] = field(
        default_factory=dict[str, str | None]
    )

    def encode(self) -> str:
        """The state as the shell keeps it."""
        return json.dumps(
            {
                "version": STATE_VERSION,
                "active": self.active.value,
                "added": self.added,
                "baseline": self.baseline,
            },
            separators=(",", ":"),
        )

    @classmethod
    def decode(cls, text: str) -> "State | None":
        """The state a previous switch printed, or ``None`` if unusable."""
        try:
            data = as_object(json.loads(text))
        except ValueError:
            return None
        if data is None or data.get("version") != STATE_VERSION:
            return None
        try:
            active = Toolchain(data.get("active"))
        except ValueError:
            return None
        added = data.get("added")
        baseline = as_object(data.get("baseline")) or {}
        values: dict[str, str | None] = {}
        for name in _VARIABLES:
            value = baseline.get(name)
            if name in baseline and not isinstance(value, str | None):
                return None
            if name in baseline:
                values[name] = value if isinstance(value, str) else None
        if not isinstance(added, str | None):
            return None
        return cls(active, added, values)


@dataclass(frozen=True)
class Pair:
    """A C and a C++ compiler of one installation, and what they said."""

    c: Path
    cxx: Path
    c_identity: Identity
    cxx_identity: Identity


@dataclass(frozen=True)
class Switch:
    """The change a selection makes.

    Attributes:
        toolchain: What is selected.
        environment: The exported variables to set, ``None`` to unset.
        state: What the shell keeps for the next switch.
    """

    toolchain: Toolchain
    environment: dict[str, str | None]
    state: State

    def shell(self) -> str:
        """The change as code for zsh or bash to evaluate.

        Only ``PATH``, ``CC``, ``CXX``, ``TOOLCHAIN_ACTIVE`` and
        ``_TOOLCHAIN_STATE`` are named, and every value is quoted.
        """
        lines: list[str] = []
        for name, value in self.environment.items():
            if name not in ("PATH", *_VARIABLES):
                raise ValueError(f"Refusing to set {name}")
            if value is None:
                lines.append(f"unset {name}")
            else:
                lines.append(f"export {name}={shlex.quote(value)}")
        active = shlex.quote(self.toolchain.value)
        lines.append(f"typeset -g TOOLCHAIN_ACTIVE={active}")
        state = shlex.quote(self.state.encode())
        lines.append(f"typeset -g _TOOLCHAIN_STATE={state}")
        lines.append("hash -r")
        return "\n".join(lines) + "\n"


def candidates(host: Host, toolchain: Toolchain) -> list[Path]:
    """The directories to look for a pair in, in order, each once."""
    path = host.search_path()
    found: list[Path]
    if host.platform is Platform.MACOS:
        found = list(path)
        if toolchain is Toolchain.GNU:
            found.append(Path(host.brew_prefix()) / "opt" / "gcc" / "bin")
    else:
        found = []
        if toolchain is Toolchain.LLVM:
            found += _llvm_directories()
        found += [Path("/usr/bin"), Path("/usr/local/bin"), *path]
    return list(dict.fromkeys(found))


def _llvm_directories() -> list[Path]:
    """Versioned LLVM installations' bin directories, newest first."""
    found: list[tuple[int, Path]] = []
    for parent in _LLVM_DIRECTORIES:
        try:
            entries = list(Path(parent).iterdir())
        except OSError:
            continue
        for entry in entries:
            matched = _LLVM_NAME.fullmatch(entry.name)
            if matched and (entry / "bin").is_dir():
                found.append((int(matched[1] or 0), entry / "bin"))
    return [directory for _, directory in sorted(found, reverse=True)]


def find(host: Host, toolchain: Toolchain, timeout: float) -> Pair | None:
    """The first pair of the toolchain's family in its candidates."""
    c_name, cxx_name = toolchain.names
    for directory in candidates(host, toolchain):
        for c, cxx in _pairs(directory, c_name, cxx_name):
            pair = _verified(host, toolchain, c, cxx, timeout)
            if pair is not None:
                return pair
    return None


def _pairs(
    directory: Path, c_name: str, cxx_name: str
) -> Iterable[tuple[Path, Path]]:
    """A directory's pairs: versioned ones, newest first, then plain names."""
    try:
        entries = {entry.name for entry in directory.iterdir()}
    except OSError:
        return []
    versions = sorted(
        (
            int(name.removeprefix(f"{c_name}-"))
            for name in entries
            if re.fullmatch(rf"{re.escape(c_name)}-\d+", name)
        ),
        reverse=True,
    )
    named = [(f"{c_name}-{n}", f"{cxx_name}-{n}") for n in versions]
    named.append((c_name, cxx_name))
    return [
        (directory / c, directory / cxx)
        for c, cxx in named
        if c in entries and cxx in entries
    ]


def _verified(
    host: Host, toolchain: Toolchain, c: Path, cxx: Path, timeout: float
) -> Pair | None:
    """The pair, if both compilers run and are of the toolchain's family."""
    identities: list[Identity] = []
    for compiler in (c, cxx):
        identity = identify(host, (str(compiler),), timeout)
        if toolchain is Toolchain.GNU:
            right = identity.gnu
        else:
            right = identity.kind is Kind.CLANG
        if not right:
            return None
        identities.append(identity)
    return Pair(c, cxx, identities[0], identities[1])


def switch(
    host: Host, toolchain: Toolchain, state: State | None, pair: Pair | None
) -> Switch:
    """The change that selects ``toolchain``, given what the shell kept.

    Args:
        host: The shell's machine and environment.
        toolchain: What to select.
        state: What the previous switch left, if anything.
        pair: The compilers to select; ``None`` for ``system``.
    """
    previous = (
        state if state and state.active is not Toolchain.SYSTEM else None
    )
    entries = host.path_entries()
    if previous is not None and previous.added:
        entries = [entry for entry in entries if entry != previous.added]
    environment: dict[str, str | None] = {}
    if toolchain is Toolchain.SYSTEM or pair is None:
        if previous is not None:
            environment.update(previous.baseline)
        new = State(Toolchain.SYSTEM)
    else:
        if previous is not None:
            baseline = dict(previous.baseline)
        else:
            baseline = {name: host.env.get(name) for name in _VARIABLES}
        directory = str(pair.c.parent)
        added = None
        if directory not in entries:
            entries.insert(0, directory)
            added = directory
        environment.update(CC=str(pair.c), CXX=str(pair.cxx))
        new = State(toolchain, added, baseline)
    if entries != host.path_entries():
        environment = {"PATH": ":".join(entries), **environment}
    return Switch(toolchain, environment, new)
