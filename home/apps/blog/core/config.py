"""Where the vault and the site are, read from a TOML file.

The file names the Hugo site, and the vault's posts and images folders::

    site = "/Volumes/Data/Blog/site"
    posts = "/Users/me/Vault/Blog/posts"
    images = "/Users/me/Vault/Blog/images"

``branch`` (default ``main``) and ``remote`` (default ``origin``) name what
``publish`` pushes, and ``backups`` (default 5) how many runs of replaced
posts are kept. An unknown key is an error, so a typo cannot pass for a
default. Posts land in the site's ``content/posts`` and images in its
``static/images``.
"""

import os
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


class ToolError(Exception):
    """A failure the user can act on; the command exits with ``status``."""

    status = 1


class UsageError(ToolError):
    """Arguments or settings that cannot work."""

    status = 2


_PATHS = ("site", "posts", "images")
_DEFAULTS = {"branch": "main", "remote": "origin", "backups": 5}


@dataclass(frozen=True)
class Config:
    """The blog's folders and where it is published."""

    site: Path
    posts: Path
    images: Path
    branch: str = "main"
    remote: str = "origin"
    backups: int = 5

    @property
    def content(self) -> Path:
        """The site's folder of posts, which mirrors the vault's."""
        return self.site / "content" / "posts"

    @property
    def static(self) -> Path:
        """The site's folder of images the posts show."""
        return self.site / "static" / "images"


def default_path(environ: Mapping[str, str]) -> Path:
    """``$XDG_CONFIG_HOME/blog/config.toml``."""
    base = environ.get("XDG_CONFIG_HOME") or Path(
        environ.get("HOME", "~"), ".config"
    )
    return Path(base, "blog", "config.toml").expanduser()


def state_path(environ: Mapping[str, str]) -> Path:
    """``$XDG_STATE_HOME/blog``: the lock and the backups."""
    base = environ.get("XDG_STATE_HOME") or Path(
        environ.get("HOME", "~"), ".local", "state"
    )
    return Path(base, "blog").expanduser()


def load(path: Path) -> Config:
    """Read and check a configuration file.

    Raises:
        ToolError: If the file is missing or not valid TOML.
        UsageError: If a key is unknown, missing or of the wrong kind.
    """
    try:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
    except FileNotFoundError as error:
        raise ToolError(
            f"No configuration at {path}; it names the site and the vault"
        ) from error
    except OSError as error:
        raise ToolError(f"Cannot read {path}: {error.strerror}") from error
    except tomllib.TOMLDecodeError as error:
        raise ToolError(f"{path} is not valid TOML: {error}") from error
    unknown = sorted(set(data) - set(_PATHS) - set(_DEFAULTS))
    if unknown:
        raise UsageError(f"Unknown setting in {path}: {', '.join(unknown)}")
    backups = _setting(data, "backups", int, path)
    if backups < 0:
        raise UsageError(f"backups in {path} cannot be negative")
    return Config(
        site=_folder(data, "site", path),
        posts=_folder(data, "posts", path),
        images=_folder(data, "images", path),
        branch=_name(data, "branch", path),
        remote=_name(data, "remote", path),
        backups=backups,
    )


def _setting[T](
    data: Mapping[str, object], key: str, kind: type[T], source: Path
) -> T:
    """An optional setting of one exact type, or its default.

    Raises:
        UsageError: If it has another type (``true`` is not a number).
    """
    value = data.get(key, _DEFAULTS[key])
    if type(value) is not kind:
        raise UsageError(f"{key} in {source} must be a {kind.__name__}")
    return value


def _name(data: Mapping[str, object], key: str, source: Path) -> str:
    """A branch or remote name that Git cannot take for an option.

    Raises:
        UsageError: If it is empty or starts with a dash.
    """
    value = _setting(data, key, str, source)
    if not value or value.startswith("-"):
        raise UsageError(f"{key} in {source} is not a valid name")
    return value


def _folder(data: Mapping[str, object], key: str, source: Path) -> Path:
    """An absolute folder from the configuration, with ``~`` expanded.

    Raises:
        UsageError: If it is missing, not text or relative.
    """
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise UsageError(f"{source} does not name the {key} folder")
    folder = Path(os.path.expanduser(value))
    if not folder.is_absolute():
        raise UsageError(f"{key} in {source} must be an absolute path")
    return folder
