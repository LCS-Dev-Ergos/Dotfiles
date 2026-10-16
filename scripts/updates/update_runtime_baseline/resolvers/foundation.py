"""The installers dev-bootstrap.sh runs for a missing Homebrew or Nix.

scripts/bootstrap/foundation.nix pins both by SHA-256. Homebrew's installer
moves with Homebrew/install's commits: when the newest commit that touched
install.sh serves other bytes, that is drift, saved for review like any
installer script, and --accept-foundation homebrew records the reviewed
commit and its hash. A pinned commit that only touched other files serves the
same bytes and stays current. Nix's installer follows the release the locked
nixpkgs carries, so a lock update that moves Nix is an update --apply makes;
the same release serving other bytes is drift, accepted the same way.
"""

import hashlib
import re
import subprocess

from .. import declarations
from ..declarations import ROOT, release_identifier
from ..model import Edit, Finding, Kind, SourceError
from ..upstream import Source
from . import installers

FOUNDATION = ROOT / "scripts/bootstrap/foundation.nix"
HOMEBREW_COMMITS = "repos/Homebrew/install/commits?path=install.sh&per_page=1"
HOMEBREW_URL = (
    "https://raw.githubusercontent.com/Homebrew/install/{revision}/install.sh"
)
NIX_URL = "https://releases.nixos.org/nix/nix-{version}/install"
# The release the bootstrap expression's locked nixpkgs builds.
LOCKED_NIX = (
    "(builtins.head (import ./scripts/bootstrap/development-bootstrap.nix "
    '{ target = "nix"; })).version'
)
REVISION = re.compile(r"[0-9a-f]{40}")
NAMES = ("homebrew", "nix")


def locked_nix() -> str:
    """The Nix release in the locked nixpkgs, which nix-darwin starts from."""
    try:
        output = subprocess.run(
            [
                "nix",
                "--extra-experimental-features",
                "nix-command flakes",
                "eval",
                "--raw",
                "--impure",
                "--expr",
                LOCKED_NIX,
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise SourceError(
            f"cannot read the locked Nix release: {error}"
        ) from error
    return release_identifier(output)


def homebrew_revision(upstream: Source) -> str:
    """The newest Homebrew/install commit that changed install.sh."""
    commits = upstream.github(HOMEBREW_COMMITS)
    revision = commits[0]["sha"] if commits else None
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        raise SourceError(f"Homebrew/install: not a commit: {revision!r}")
    return revision


def target(name: str, upstream: Source) -> tuple[str, str]:
    """Where the installer `name` should be pinned now, and its URL."""
    if name == "homebrew":
        revision = homebrew_revision(upstream)
        return revision, HOMEBREW_URL.format(revision=revision)
    version = locked_nix()
    return version, NIX_URL.format(version=version)


def pinned(name: str, pins: dict) -> tuple[str, str]:
    """The pinned identity (commit or release) and hash of `name`."""
    if name == "homebrew":
        return pins["homebrewRevision"], pins["homebrewSha256"]
    return pins["nixVersion"], pins["nixSha256"]


def edits(name: str, pins: dict, identity: str, digest: str) -> list[Edit]:
    """Rewrite one installer's pins; nothing else in the file may change."""
    key = "homebrewRevision" if name == "homebrew" else "nixVersion"
    hash_key = "homebrewSha256" if name == "homebrew" else "nixSha256"
    result = [
        Edit(FOUNDATION, f'"{pins[hash_key]}"', f'"{digest}"', (hash_key,))
    ]
    if identity != pins[key]:
        result.append(
            Edit(
                FOUNDATION,
                f'"{pins[key]}"',
                f'"{release_identifier(identity)}"',
                (key,),
            )
        )
    return result


def resolve(upstream: Source, baseline: dict, managers: dict) -> list:
    pins = declarations.evaluate(FOUNDATION)
    found = []
    for name in NAMES:
        label = f"foundation {name} installer"
        identity, digest = pinned(name, pins)
        current, url = target(name, upstream)
        if name == "nix" and current != identity:
            # The release follows the lock; its installer comes from the
            # release's own immutable directory.
            def build(current=current, url=url):
                data = upstream.fetch(url, limit=installers.INSTALLER_LIMIT)
                new = hashlib.sha256(data).hexdigest()
                return edits("nix", pins, current, new)

            found.append(
                Finding(
                    "foundation",
                    label,
                    identity,
                    current,
                    Kind.UPDATE,
                    "the locked nixpkgs moved Nix",
                    build,
                )
            )
            continue
        data = upstream.fetch(url, limit=installers.INSTALLER_LIMIT)
        new = hashlib.sha256(data).hexdigest()
        if new == digest:
            found.append(Finding("foundation", label, identity[:12]))
            continue
        _, path = installers.save_for_review(f"foundation-{name}", data)
        found.append(
            Finding(
                "foundation",
                label,
                identity[:12],
                current[:12],
                Kind.DRIFT,
                f"review {path}, then --accept-foundation {name}",
            )
        )
    return found


def accept(names: list[str], upstream: Source) -> None:
    """Record the reviewed installer bytes; refuse bytes nobody reviewed."""
    pins = declarations.evaluate(FOUNDATION)
    changes, accepted = [], []
    for name in names:
        if name not in NAMES:
            raise SourceError(
                f"no foundation installer named {name}; choose from {', '.join(NAMES)}"
            )
        identity, digest = pinned(name, pins)
        current, url = target(name, upstream)
        data = upstream.fetch(url, limit=installers.INSTALLER_LIMIT)
        new = hashlib.sha256(data).hexdigest()
        if new == digest:
            print(f"foundation {name}: unchanged")
            continue
        path = installers.review_path(f"foundation-{name}", new)
        if not path.exists() or path.read_bytes() != data:
            _, path = installers.save_for_review(f"foundation-{name}", data)
            raise SourceError(
                f"foundation {name}: read {path} first; upstream serves "
                "bytes nobody reviewed yet"
            )
        changes += edits(name, pins, current, new)
        accepted.append(name)
    if changes:
        declarations.apply_edits(changes)
    for name in accepted:
        print(f"foundation {name}: recorded the reviewed installer")
