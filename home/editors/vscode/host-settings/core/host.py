"""The facts about a machine that resolution depends on.

Locations are pure paths of the host's own flavor, POSIX or Windows, so either
kind of host can be described, and tested, on the other. ``Host.concrete`` is
the only way from a location to the filesystem, and it refuses a flavor that
is not the running system's.
"""

import getpass
import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path, PurePath, PurePosixPath, PureWindowsPath

from .errors import SettingsError

_NATIVE_FLAVOR = type(PurePath())


class Platform(Enum):
    """An operating system family the tool knows the conventions of."""

    DARWIN = "darwin"
    LINUX = "linux"
    WINDOWS = "windows"

    @classmethod
    def current(cls) -> "Platform":
        """The running system; any POSIX system that is not macOS is Linux."""
        if sys.platform == "darwin":
            return cls.DARWIN
        if sys.platform.startswith("win"):
            return cls.WINDOWS
        return cls.LINUX

    @property
    def path_type(self) -> type[PurePath]:
        """The pure path flavor of this platform."""
        if self is Platform.WINDOWS:
            return PureWindowsPath
        return PurePosixPath

    @property
    def path_separator(self) -> str:
        """The separator of PATH entries."""
        return ";" if self is Platform.WINDOWS else ":"

    @property
    def shared_library_suffix(self) -> str | None:
        """The suffix of a shared library, or None where none is looked up."""
        if self is Platform.DARWIN:
            return ".dylib"
        if self is Platform.LINUX:
            return ".so"
        return None

    def executable(self, name: str) -> str:
        """The file name of the executable ``name``.

        On Windows only ``.exe`` counts: a ``.bat`` or ``.cmd`` of the same
        name is a script, and a script is not what a tool setting expects.
        """
        return f"{name}.exe" if self is Platform.WINDOWS else name


class Edition(Enum):
    """A VS Code release channel, which has its own user data directory."""

    STABLE = "stable"
    INSIDERS = "insiders"

    @property
    def directory_name(self) -> str:
        """The name of the edition's directory below the config home."""
        return "Code - Insiders" if self is Edition.INSIDERS else "Code"


@dataclass(frozen=True, slots=True)
class Host:
    """A machine: its platform, home directory, user and environment.

    Tests build one by hand; ``Host.detect`` reads the running one.

    Raises:
        ValueError: If ``home`` is not an absolute path of the platform's
            flavor.
    """

    platform: Platform
    home: PurePath
    user: str
    env: Mapping[str, str] = field(default_factory=dict[str, str])

    def __post_init__(self) -> None:
        flavor = self.platform.path_type
        if not isinstance(self.home, flavor) or not self.home.is_absolute():
            raise ValueError(
                f"home must be an absolute {flavor.__name__}: {self.home!r}"
            )

    @classmethod
    def detect(cls) -> "Host":
        """The machine this process runs on."""
        return cls(Platform.current(), Path.home(), _user(), dict(os.environ))

    def path(self, spelling: str) -> PurePath:
        """``spelling`` as a path of this host's flavor."""
        return self.platform.path_type(spelling)

    def concrete(self, location: PurePath) -> Path:
        """The filesystem path of a location on this host.

        Raises:
            SettingsError: If the host is not of the running system's flavor,
                so its locations cannot be looked at from here.
        """
        if self.platform.path_type is not _NATIVE_FLAVOR:
            raise SettingsError(
                f"a {self.platform.value} host cannot be inspected from here"
            )
        return Path(location)

    def env_directory(self, name: str) -> PurePath | None:
        """The directory an environment variable names, if it is absolute.

        A relative value is ignored, as the XDG specification requires: it
        would make the result depend on the working directory.
        """
        value = self.env.get(name, "")
        if not value:
            return None
        directory = self.path(value)
        return directory if directory.is_absolute() else None

    def config_home(self) -> PurePath:
        """Where applications keep their configuration."""
        if self.platform is Platform.DARWIN:
            return self.home / "Library" / "Application Support"
        if self.platform is Platform.WINDOWS:
            fallback = self.home / "AppData" / "Roaming"
            return self.env_directory("APPDATA") or fallback
        return self.env_directory("XDG_CONFIG_HOME") or self.home / ".config"

    def state_home(self) -> PurePath:
        """Where applications keep state that must survive a reboot."""
        if self.platform is Platform.WINDOWS:
            fallback = self.home / "AppData" / "Local"
            return self.env_directory("LOCALAPPDATA") or fallback
        fallback = self.home / ".local" / "state"
        return self.env_directory("XDG_STATE_HOME") or fallback

    def cache_home(self) -> PurePath | None:
        """Where applications keep disposable data.

        None on Windows, where no convention is assumed, so values below it
        stay unresolved there.
        """
        if self.platform is Platform.DARWIN:
            return self.home / "Library" / "Caches"
        if self.platform is Platform.LINUX:
            fallback = self.home / ".cache"
            return self.env_directory("XDG_CACHE_HOME") or fallback
        return None

    def user_data_dir(self, edition: Edition) -> PurePath:
        """The directory holding an edition's user ``settings.json``."""
        return self.config_home() / edition.directory_name / "User"

    def profile_roots(self, *, gcroot_first: bool = False) -> list[PurePath]:
        """The Nix profiles that can own a tool, most specific first.

        Args:
            gcroot_first: Put the Home Manager gcroot first. Every switch
                repoints it, so it names the current generation whatever
                the profile layout is.
        """
        if self.platform is Platform.WINDOWS:
            return []
        state = self.state_home()
        gcroot = state / "home-manager" / "gcroots" / "current-home"
        roots: list[PurePath] = []
        if self.user:
            roots.append(self.path("/etc/profiles/per-user") / self.user)
        roots += [
            self.home / ".nix-profile",
            state / "nix" / "profiles" / "profile",
        ]
        home_path = gcroot / "home-path"
        return [home_path, *roots] if gcroot_first else [*roots, home_path]

    def profile_bin_dirs(self) -> list[PurePath]:
        """The bin directories of the Nix profiles.

        On Windows, which has no Nix profiles, these are the bin directories
        of the usual LLVM, CMake and Scoop installations instead.
        """
        directories = [root / "bin" for root in self.profile_roots()]
        if self.platform is Platform.WINDOWS:
            program_files = self.env_directory("ProgramFiles") or self.path(
                "C:/Program Files"
            )
            directories += [
                program_files / "LLVM" / "bin",
                program_files / "CMake" / "bin",
                self.home / "scoop" / "shims",
            ]
        return directories

    def search_dirs(self) -> list[PurePath]:
        """Where tools are searched: the profiles first, then PATH.

        Relative and empty PATH entries are dropped; they would make the
        result depend on the working directory.
        """
        found: list[PurePath] = []
        entries = self.env.get("PATH", "").split(self.platform.path_separator)
        candidates = [
            *self.profile_bin_dirs(),
            *(self.path(entry) for entry in entries if entry),
        ]
        for directory in candidates:
            if directory.is_absolute() and directory not in found:
                found.append(directory)
        return found


def _user() -> str:
    """The login name, or the environment's idea of it.

    ``getpass.getuser`` fails without a passwd entry, as in some containers.
    """
    try:
        return getpass.getuser()
    except (OSError, KeyError, ImportError):
        return os.environ.get("USER") or os.environ.get("USERNAME") or ""
