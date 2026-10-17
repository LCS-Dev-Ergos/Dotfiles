"""The machine: its platform, environment, PATH and where binaries come from.

Everything the tools look up goes through a ``Host``, built once from the
running process or, in tests, from a temporary home and environment, so no
check reads ``os.environ`` behind the caller's back.
"""

import os
import platform as system
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from .errors import DoctorError


class Platform(Enum):
    """An operating system the tools know the conventions of."""

    MACOS = "macOS"
    LINUX = "Linux"

    @classmethod
    def current(cls) -> "Platform":
        """The running system.

        Raises:
            DoctorError: On anything but macOS and Linux.
        """
        if sys.platform == "darwin":
            return cls.MACOS
        if sys.platform.startswith("linux"):
            return cls.LINUX
        raise DoctorError("Only macOS and Linux are supported")


class Origin(Enum):
    """Who put a binary where PATH finds it."""

    MANAGER = "manager"
    NIX = "nix"
    BREW = "brew"
    SYSTEM = "system"
    OTHER = "other"


_NIX_PREFIXES = ("/nix/store/", "/run/current-system/sw/", "/etc/profiles/")
_BREW_PREFIXES = ("/opt/homebrew/", "/usr/local/Cellar/", "/home/linuxbrew/")
_SYSTEM_PREFIXES = (
    "/usr/bin/",
    "/bin/",
    "/usr/sbin/",
    "/sbin/",
    "/Library/",
    "/System/",
)


@dataclass(frozen=True)
class Host:
    """A machine as the tools see it.

    Attributes:
        platform: The operating system.
        home: The home directory, absolute.
        env: The environment every lookup and child process uses.
        machine: The hardware name, such as ``arm64``.
        release: The macOS version, or the Linux distribution.
    """

    platform: Platform
    home: Path
    env: Mapping[str, str] = field(default_factory=dict[str, str])
    machine: str = ""
    release: str = ""

    def __post_init__(self) -> None:
        if not self.home.is_absolute():
            raise ValueError(f"Home must be absolute: {self.home}")

    @classmethod
    def detect(cls) -> "Host":
        """The running machine and the process environment.

        Raises:
            DoctorError: On an unsupported system or without a home.
        """
        current = Platform.current()
        home = os.environ.get("HOME", "")
        if not home or not os.path.isabs(home):
            raise DoctorError("HOME is not set to an absolute path")
        if current is Platform.MACOS:
            release = system.mac_ver()[0]
        else:
            release = _distribution(Path("/etc"))
        return cls(
            current, Path(home), dict(os.environ), system.machine(), release
        )

    @property
    def label(self) -> str:
        """The platform as people read it: ``macOS`` or ``Linux (Arch)``."""
        if self.platform is Platform.LINUX and self.release:
            return f"Linux ({self.release})"
        return self.platform.value

    @property
    def description(self) -> str:
        """The platform, its version and the hardware, for a masthead."""
        name = self.label
        if self.platform is Platform.MACOS and self.release:
            name = f"{name} {self.release}"
        return " · ".join(part for part in (name, self.machine) if part)

    def get(self, name: str) -> str:
        """An environment variable, or an empty string."""
        return self.env.get(name, "")

    def expand(self, text: str) -> Path:
        """A path with a leading ``~`` read as the home directory."""
        if text == "~":
            return self.home
        if text.startswith("~/"):
            return self.home / text[2:]
        return Path(text)

    def config_home(self) -> Path:
        """``$XDG_CONFIG_HOME``, by default ``~/.config``."""
        return self._xdg("XDG_CONFIG_HOME", ".config")

    def cache_home(self) -> Path:
        """``$XDG_CACHE_HOME``, by default ``~/.cache``."""
        return self._xdg("XDG_CACHE_HOME", ".cache")

    def _xdg(self, name: str, default: str) -> Path:
        """An XDG base directory; a relative value is ignored, as specified."""
        value = self.get(name)
        if value and os.path.isabs(value):
            return Path(value)
        return self.home / default

    def path_entries(self) -> list[str]:
        """PATH as written, empty entries included."""
        value = self.get("PATH")
        return value.split(os.pathsep) if value else []

    def search_path(self) -> list[Path]:
        """The directories PATH searches, in order, each once."""
        seen: dict[str, None] = {}
        for entry in self.path_entries():
            if entry and os.path.isabs(entry):
                seen.setdefault(entry)
        return [Path(entry) for entry in seen]

    def which(
        self, name: str, directories: Iterable[Path] | None = None
    ) -> Path | None:
        """The first executable called ``name``, or ``name`` itself if a path.

        Args:
            name: A command name, or a path (``~`` allowed).
            directories: Where to look instead of PATH.
        """
        if "/" in name:
            path = self.expand(name)
            return path if _executable(path) else None
        found = self.which_all(name, directories)
        return found[0] if found else None

    def which_all(
        self, name: str, directories: Iterable[Path] | None = None
    ) -> list[Path]:
        """Every executable called ``name`` on PATH, in order, each once."""
        if not name or "/" in name or name in (".", ".."):
            return []
        searched = self.search_path() if directories is None else directories
        found = [directory / name for directory in searched]
        return [path for path in found if _executable(path)]

    def brew_prefix(self) -> str:
        """Homebrew's prefix: ``$HOMEBREW_PREFIX`` or the Apple silicon one."""
        return self.get("HOMEBREW_PREFIX").rstrip("/") or "/opt/homebrew"

    def origin(self, path: Path, roots: Iterable[Path] = ()) -> Origin:
        """Who put ``path`` there: a manager root, Nix, Homebrew or the OS.

        The path is compared as written and resolved, so a profile link
        into the store counts as Nix and a shim inside a root as the
        manager's.
        """
        written = str(path)
        resolved = os.path.realpath(path)
        for root in roots:
            prefix = f"{str(root).rstrip('/')}/"
            if written.startswith(prefix) or resolved.startswith(prefix):
                return Origin.MANAGER
        brew = (f"{self.brew_prefix()}/", *_BREW_PREFIXES)
        for prefixes, origin in (
            (_NIX_PREFIXES, Origin.NIX),
            (brew, Origin.BREW),
            (_SYSTEM_PREFIXES, Origin.SYSTEM),
        ):
            if resolved.startswith(prefixes):
                return origin
        return Origin.OTHER

    def shorten(self, text: str) -> str:
        """``text`` with the home directory written as ``~``."""
        home = f"{str(self.home).rstrip('/')}/"
        return text.replace(home, "~/") if home != "/" else text


def _executable(path: Path) -> bool:
    """Whether ``path`` is a file this process may execute."""
    try:
        return path.is_file() and os.access(path, os.X_OK)
    except OSError:
        return False


def _distribution(etc: Path) -> str:
    """The Linux distribution's short name, or an empty string.

    Arch and its derivatives (CachyOS, EndeavourOS) are Arch here, as they
    share its packages; others are read from ``os-release``.
    """
    if (etc / "arch-release").exists():
        return "Arch"
    try:
        text = (etc / "os-release").read_text(encoding="utf-8")
    except OSError:
        return ""
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key == "NAME":
            return value.strip().strip("\"'")
    return ""
