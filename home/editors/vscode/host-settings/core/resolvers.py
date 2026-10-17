"""How each managed value is found on a host.

A resolver returns the value a setting should hold, or None when its target is
not on the machine; nothing is guessed and nothing found is executed. Paths
are handled as paths throughout and become setting text only on return.
"""

import os
import re
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path, PurePath, PurePosixPath
from typing import Protocol

from .host import Host, Platform

_WIDENING = re.compile(r"[,*?\[\]{}]")
_DIGITS = re.compile(r"\d+")


class Resolver(Protocol):
    """Finds one value on a host."""

    @property
    def hint(self) -> str:
        """Why nothing was found, for the report."""
        ...

    def resolve(self, host: Host) -> str | None:
        """The value for ``host``, or None when its target is missing."""
        ...


def find_executable(
    name: str, directories: Iterable[Path], platform: Platform
) -> Path | None:
    """The first executable called ``name`` in ``directories``, unresolved.

    Symlinks are kept as they are: a profile path survives rebuilds and
    garbage collection, the store path behind it does not. Unlike
    ``shutil.which``, the working directory is never searched, on Windows
    included.
    """
    file_name = platform.executable(name)
    for directory in directories:
        candidate = directory / file_name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def home_relative(path: PurePath, home: PurePath) -> str:
    """``path`` spelled with ``~`` for the home directory when below it."""
    try:
        relative = path.relative_to(home)
    except ValueError:
        return str(path)
    return f"~/{relative.as_posix()}" if relative.parts else "~"


def _numbers(text: str) -> tuple[int, ...]:
    """The decimal numbers in ``text``, for comparing versions."""
    return tuple(int(digits) for digits in _DIGITS.findall(text))


@dataclass(frozen=True, slots=True)
class Executable:
    """An executable looked up in the Nix profiles and then on PATH."""

    name: str
    alternatives: tuple[str, ...] = ()

    @property
    def names(self) -> tuple[str, ...]:
        """Every name tried, in order."""
        return (self.name, *self.alternatives)

    @property
    def hint(self) -> str:
        """See ``Resolver.hint``."""
        names = " or ".join(self.names)
        return f"no {names} in the Nix profiles or on PATH"

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        directories = [host.concrete(d) for d in host.search_dirs()]
        for name in self.names:
            found = find_executable(name, directories, host.platform)
            if found is not None:
                return str(found)
        return None


@dataclass(frozen=True, slots=True)
class SharedLibrary:
    """A shared library in the lib directory of a Nix profile.

    The Home Manager gcroot is searched first, and an unversioned file beats
    the newest versioned one (``libfoo.so.22`` beats ``libfoo.so.9``).
    """

    stem: str

    @property
    def hint(self) -> str:
        """See ``Resolver.hint``."""
        return f"no lib{self.stem} in the Nix profiles"

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        suffix = host.platform.shared_library_suffix
        if suffix is None:
            return None
        file_name = f"lib{self.stem}{suffix}"
        for root in host.profile_roots(gcroot_first=True):
            directory = host.concrete(root / "lib")
            candidate = directory / file_name
            if candidate.is_file():
                return str(candidate)
            versioned = sorted(
                directory.glob(f"{file_name}.*"),
                key=lambda path: (_numbers(path.name[len(file_name) :]), path),
                reverse=True,
            )
            for found in versioned:
                if found.is_file():
                    return str(found)
        return None


@dataclass(frozen=True, slots=True)
class FirstExisting:
    """The first existing path of a list, on the platforms it applies to.

    Candidates are POSIX spellings, so they suit macOS and Linux only; a
    leading ``~`` stands for the host's home directory.
    """

    hint: str
    platforms: frozenset[Platform]
    candidates: tuple[str, ...]

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        if host.platform not in self.platforms:
            return None
        for spelling in self.candidates:
            parts = PurePosixPath(spelling).parts
            if parts[:1] == ("~",):
                location = host.home.joinpath(*parts[1:])
            else:
                location = host.path(spelling)
            path = host.concrete(location)
            if path.exists():
                return str(path)
        return None


@dataclass(frozen=True, slots=True)
class FirstOf:
    """The value of the first resolver that finds one."""

    resolvers: tuple[Resolver, ...]

    @property
    def hint(self) -> str:
        """See ``Resolver.hint``."""
        return " / ".join(resolver.hint for resolver in self.resolvers)

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        for resolver in self.resolvers:
            found = resolver.resolve(host)
            if found is not None:
                return found
        return None


@dataclass(frozen=True, slots=True)
class SdkmanJdk:
    """The newest SDKMAN JDK of a major release.

    Choosing by major release instead of by directory name keeps the setting
    valid after ``sdk install`` brings a newer patch release.
    """

    major: int

    @property
    def hint(self) -> str:
        """See ``Resolver.hint``."""
        return f"no JDK {self.major} under the SDKMAN candidates"

    def candidates_dir(self, host: Host) -> PurePath:
        """Where SDKMAN keeps its candidates on ``host``."""
        configured = host.env_directory("SDKMAN_CANDIDATES_DIR")
        if configured is not None:
            return configured
        sdkman = host.env_directory("SDKMAN_DIR")
        if sdkman is not None:
            return sdkman / "candidates"
        return host.home / ".sdkman" / "candidates"

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        root = host.concrete(self.candidates_dir(host) / "java")
        try:
            entries = list(root.iterdir())
        except OSError:
            return None
        java = host.platform.executable("java")
        best: tuple[tuple[int, ...], str] | None = None
        for entry in entries:
            release = _numbers(entry.name.partition("-")[0])
            if entry.name == "current" or release[:1] != (self.major,):
                continue
            if not (entry / "bin" / java).is_file():
                continue
            if best is None or (release, entry.name) > best:
                best = (release, entry.name)
        return str(root / best[1]) if best else None


@dataclass(frozen=True, slots=True)
class CacheDirectory:
    """A directory below the platform cache directory, existing or not.

    The value is spelled with ``~`` when it lies below the home directory,
    like the values it replaces, so a machine that is already right is left
    untouched.
    """

    subdirectory: str

    @property
    def hint(self) -> str:
        """See ``Resolver.hint``."""
        return "no known cache directory for this system"

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        cache = host.cache_home()
        if cache is None:
            return None
        parts = PurePosixPath(self.subdirectory).parts
        return home_relative(cache.joinpath(*parts), host.home)


@dataclass(frozen=True, slots=True)
class CompilerAllowList:
    """Comma-separated compiler drivers clangd may run for include paths.

    This is a security boundary: clangd executes whatever driver a project's
    compile_commands.json names if it matches the list. So the list holds
    exact files from the Nix profiles and ``/usr/bin``, never PATH entries;
    a path that could widen the match (a comma or a glob character) is left
    out, and a profile and its gcroot list the same real file once.
    """

    drivers: tuple[str, ...]

    @property
    def hint(self) -> str:
        """See ``Resolver.hint``."""
        return "no compiler drivers in the Nix profiles or /usr/bin"

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        directories = host.profile_bin_dirs()
        if host.platform is not Platform.WINDOWS:
            directories.append(host.path("/usr/bin"))
        listed: list[str] = []
        covered: set[Path] = set()
        for directory in directories:
            concrete = [host.concrete(directory)]
            for name in self.drivers:
                found = find_executable(name, concrete, host.platform)
                if found is None or _WIDENING.search(str(found)):
                    continue
                real = found.resolve()
                if real not in covered:
                    covered.add(real)
                    listed.append(str(found))
        return ",".join(listed) or None


@dataclass(frozen=True, slots=True)
class Fixed:
    """A value that is the same on every machine."""

    value: str

    @property
    def hint(self) -> str:
        """See ``Resolver.hint``."""
        return "fixed"

    def resolve(self, host: Host) -> str | None:
        """See ``Resolver.resolve``."""
        return self.value
