"""The machine: where each VS Code edition keeps its files.

Besides the desktop editions, a host can hold VS Code Server, which a remote
client (Remote - SSH, Remote - Tunnels) installs for itself: Stable's below
``~/.vscode-server`` and Insiders' below ``~/.vscode-server-insiders``. A
server keeps its extensions in ``extensions`` and its profiles in
``data/User``, as a desktop edition does, and its builds in
``cli/servers/<Quality>-<commit>/server`` or, from older clients,
``bin/<commit>``.

Only macOS and Linux are supported. Sharing works through symlinks, which
Windows grants only to privileged or developer-mode accounts, so the tool
refuses to run there rather than half work.
"""

import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from . import PROG
from .errors import SyncError


class Platform(Enum):
    """An operating system the tool knows the conventions of."""

    DARWIN = "darwin"
    LINUX = "linux"

    @classmethod
    def current(cls) -> "Platform":
        """The running system.

        Raises:
            SyncError: On Windows and on systems that are not POSIX.
        """
        if sys.platform == "darwin":
            return cls.DARWIN
        if sys.platform.startswith("win") or os.name != "posix":
            raise SyncError(f"{PROG} supports macOS and Linux only")
        return cls.LINUX


class Edition(Enum):
    """A VS Code installation with its own folders and command line."""

    STABLE = "stable"
    INSIDERS = "insiders"
    SERVER = "server"
    SERVER_INSIDERS = "server-insiders"

    @property
    def label(self) -> str:
        """The name the edition is shown with."""
        return {
            Edition.STABLE: "Stable",
            Edition.INSIDERS: "Insiders",
            Edition.SERVER: "Server",
            Edition.SERVER_INSIDERS: "Server Insiders",
        }[self]

    @property
    def is_server(self) -> bool:
        """Whether this is VS Code Server, installed by remote clients."""
        return self in (Edition.SERVER, Edition.SERVER_INSIDERS)

    @property
    def quality(self) -> str:
        """The release channel, as server build directories are named."""
        insiders = self in (Edition.INSIDERS, Edition.SERVER_INSIDERS)
        return "Insiders" if insiders else "Stable"

    @property
    def directory_name(self) -> str:
        """The name of a desktop edition's directory below the config home."""
        return "Code - Insiders" if self is Edition.INSIDERS else "Code"

    @property
    def dot_directory(self) -> str:
        """The directory below the home that holds the extensions."""
        return {
            Edition.STABLE: ".vscode",
            Edition.INSIDERS: ".vscode-insiders",
            Edition.SERVER: ".vscode-server",
            Edition.SERVER_INSIDERS: ".vscode-server-insiders",
        }[self]

    @property
    def command(self) -> str:
        """The edition's command line program.

        A server's lives inside each of its builds; see ``Host.server_builds``.
        """
        if self.is_server:
            return "code-server"
        return "code-insiders" if self is Edition.INSIDERS else "code"

    @property
    def application(self) -> str:
        """A desktop edition's macOS application bundle."""
        if self is Edition.INSIDERS:
            return "Visual Studio Code - Insiders.app"
        return "Visual Studio Code.app"


TARGETS = (Edition.INSIDERS, Edition.SERVER, Edition.SERVER_INSIDERS)
"""The editions that share Stable's extensions, in the order reports show."""


@dataclass(frozen=True, slots=True)
class Host:
    """A machine: its platform, home directory and environment.

    Tests build one by hand; ``Host.detect`` reads the running one.

    Raises:
        ValueError: If ``home`` is not absolute.
    """

    platform: Platform
    home: Path
    env: Mapping[str, str] = field(default_factory=dict[str, str])

    def __post_init__(self) -> None:
        if not self.home.is_absolute():
            raise ValueError(f"Home must be absolute: {self.home}")

    @classmethod
    def detect(cls) -> "Host":
        """The machine this process runs on.

        Raises:
            SyncError: If the platform is not supported.
        """
        return cls(Platform.current(), Path.home(), dict(os.environ))

    def env_directory(self, name: str) -> Path | None:
        """The directory an environment variable names, if it is absolute.

        A relative value is ignored, as the XDG specification requires: it
        would make the result depend on the working directory.
        """
        value = self.env.get(name, "")
        if not value:
            return None
        directory = Path(value)
        return directory if directory.is_absolute() else None

    def config_home(self) -> Path:
        """Where applications keep their configuration."""
        if self.platform is Platform.DARWIN:
            return self.home / "Library" / "Application Support"
        return self.env_directory("XDG_CONFIG_HOME") or self.home / ".config"

    def state_home(self) -> Path:
        """Where applications keep state that must survive a reboot."""
        fallback = self.home / ".local" / "state"
        return self.env_directory("XDG_STATE_HOME") or fallback

    def state_dir(self) -> Path:
        """The tool's own state: lock, run workspaces, backups."""
        return self.state_home() / PROG

    def user_dir(self, edition: Edition) -> Path:
        """The directory of an edition's settings, snippets and profiles."""
        if edition.is_server:
            return self.home / edition.dot_directory / "data" / "User"
        return self.config_home() / edition.directory_name / "User"

    def extensions_dir(self, edition: Edition) -> Path:
        """The directory an edition installs its extensions into."""
        return self.home / edition.dot_directory / "extensions"

    def server_builds(self, edition: Edition) -> list[Path]:
        """The directories of a server's installed builds, unordered.

        Each holds ``product.json`` and ``bin/code-server``.
        """
        root = self.home / edition.dot_directory
        servers = root / "cli" / "servers"
        found = list(servers.glob(f"{edition.quality}-*/server"))
        found += [path for path in (root / "bin").glob("*") if path.is_dir()]
        return found

    def search_path(self) -> str:
        """The PATH the edition commands and helpers are looked up in."""
        return self.env.get("PATH", os.defpath)
