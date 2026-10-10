"""Hash-pinned installer scripts served from mutable URLs.

Drifted bytes are saved for review under their hash; --accept-installer
records the hash of those reviewed bytes, and refuses if upstream changed
again since.
"""

import hashlib
import os
from pathlib import Path

from .. import declarations
from ..model import Edit, Finding, Kind, SourceError
from ..upstream import Source
from .assets import installer_scopes

INSTALLER_LIMIT = 1024 * 1024


def review_directory() -> Path:
    cache = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(cache) / "update-runtime-baseline" / "installers"


def review_path(name: str, digest: str) -> Path:
    return review_directory() / f"{name}-{digest[:16]}"


def mutable_installers(managers: dict) -> dict[str, dict]:
    """Hash-pinned scripts at mutable URLs; release assets carry a size."""
    installers = managers["bootstrap"][declarations.PLATFORMS[0]]["installers"]
    return {
        name: installer
        for name, installer in sorted(installers.items())
        if "size" not in installer
    }


def save_for_review(name: str, data: bytes) -> tuple[str, Path]:
    digest = hashlib.sha256(data).hexdigest()
    path = review_path(name, digest)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.exists():
        path.write_bytes(data)
    return digest, path


def resolve(upstream: Source, baseline: dict, managers: dict) -> list:
    found = []
    for name, installer in mutable_installers(managers).items():
        pinned = installer["sha256"]
        data = upstream.fetch(installer["url"], limit=INSTALLER_LIMIT)
        digest = hashlib.sha256(data).hexdigest()
        if digest == pinned:
            found.append(
                Finding("installers", f"installer {name}", pinned[:12])
            )
            continue
        _, path = save_for_review(name, data)
        note = f"review {path}"
        previous = review_path(name, pinned)
        if previous.exists():
            note += f" (diff against {previous})"
        found.append(
            Finding(
                "installers",
                f"installer {name}",
                pinned[:12],
                digest[:12],
                Kind.DRIFT,
                f"{note}, then --accept-installer {name}",
            )
        )
    return found


def accept(names: list[str], upstream: Source, managers: dict) -> None:
    installers = mutable_installers(managers)
    edits, accepted = [], []
    for name in names:
        if name not in installers:
            raise SourceError(
                f"no mutable installer named {name}; "
                f"choose from {', '.join(installers)}"
            )
        pinned = installers[name]["sha256"]
        data = upstream.fetch(installers[name]["url"], limit=INSTALLER_LIMIT)
        digest = hashlib.sha256(data).hexdigest()
        if digest == pinned:
            print(f"installer {name}: unchanged")
            continue
        path = review_path(name, digest)
        if not path.exists() or path.read_bytes() != data:
            _, path = save_for_review(name, data)
            raise SourceError(
                f"installer {name}: read {path} first; upstream serves bytes "
                "nobody reviewed yet"
            )
        edits.append(
            Edit(
                declarations.MANAGERS,
                f'"{pinned}"',
                f'"{digest}"',
                installer_scopes(name),
            )
        )
        accepted.append(name)
    # The reviewed bytes stay in the review directory under their hash, so
    # the next drift report can name them for a diff.
    if edits:
        declarations.apply_edits(edits)
    for name in accepted:
        print(f"installer {name}: recorded the reviewed hash")
