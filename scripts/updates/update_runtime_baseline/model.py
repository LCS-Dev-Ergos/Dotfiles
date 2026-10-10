"""Findings, the edits that apply them, and how a pin is classified."""

import enum
import functools
import re
from collections.abc import Callable, Collection
from dataclasses import dataclass
from pathlib import Path

from .versions import newer, same_line

# A new line of these needs more than a version: a second declared release
# (Node, OCaml) or a nixpkgs attribute named after the line (Python).
MANUAL_LINES = {
    "node": "edit node.versions and the nodejs_<major> runtimes by hand",
    "python": "the nixpkgs backend names python3<minor>; edit by hand",
    "ocaml": "edit ocaml.versions by hand",
}
# How many in-line releases we try, newest first, before reporting pending.
ATTEMPTS = 3


class SourceError(Exception):
    """An upstream or a declaration could not be read as expected."""


class Kind(enum.StrEnum):
    CURRENT = "current"
    UPDATE = "update"
    PENDING = "pending"
    LINE = "line"
    DRIFT = "drift"


@dataclass(frozen=True, slots=True)
class Edit:
    """Replace every occurrence of `old` in `path` with `new`.

    `scopes` are the evaluated attribute paths allowed to change; after the
    rewrite, anything else that changed restores the files.
    """

    path: Path
    old: str
    new: str
    scopes: tuple[str, ...]

    def apply(self, text: str) -> str:
        if self.old not in text:
            raise SourceError(f"{self.path.name}: {self.old} not found")
        return text.replace(self.old, self.new)


@dataclass(frozen=True, slots=True)
class BlockEdit:
    """Replace the one region of `path` that `pattern` matches with `new`.

    Block edits apply after every exact replacement, so a value that an
    `Edit` also matched inside the region is overwritten by the rendering.
    """

    path: Path
    pattern: re.Pattern[str]
    new: str
    scopes: tuple[str, ...]

    def apply(self, text: str) -> str:
        matches = list(self.pattern.finditer(text))
        if len(matches) != 1:
            raise SourceError(
                f"{self.path.name}: expected one block matching "
                f"{self.pattern.pattern!r}, found {len(matches)}"
            )
        start, end = matches[0].span()
        return text[:start] + self.new + text[end:]


Edits = Callable[[], list[Edit]]
# (declaration path, release) pairs that a rewrite stops declaring.
Retired = tuple[tuple[str, str], ...]


@dataclass(slots=True)
class Finding:
    """One pin compared with its upstream.

    `edits` builds the rewrite only when applied: for release assets it
    downloads them to record their hash. `retires` names what the rewrite
    replaces, which the baseline then lists under `retired`.
    """

    ecosystem: str
    name: str
    pinned: str
    available: str = ""
    kind: Kind = Kind.CURRENT
    note: str = ""
    edits: Edits | None = None
    retires: Retired = ()

    @property
    def actionable(self) -> bool:
        return self.kind in (Kind.UPDATE, Kind.DRIFT)


def classify(
    ecosystem: str,
    name: str,
    pinned: str,
    candidates: Collection[str],
    depth: int,
    installable: Callable[[str], str | None] | None = None,
    edits: Callable[[str], list[Edit]] | None = None,
    line_edits: Callable[[str], list[Edit]] | None = None,
    lines: bool = True,
    retires: Retired = (),
) -> list[Finding]:
    """Findings for one pinned release among an upstream's stable releases.

    `depth` is how many leading components name the line: 1 for a major,
    2 for major.minor, 0 when any newer release is an update. `installable`
    returns None when the manager can install a release, or why not; we try
    at most three releases, newest first. With several declared lines, only
    the newest reports `lines`; the others are covered by it.
    """
    found = []
    candidates = newer(candidates, pinned)
    in_line = [v for v in candidates if same_line(v, pinned, depth)]
    blocked = []
    for version in in_line[:ATTEMPTS]:
        reason = installable(version) if installable else None
        if reason is None:
            found.append(
                Finding(
                    ecosystem,
                    name,
                    pinned,
                    version,
                    Kind.UPDATE,
                    edits=functools.partial(edits, version) if edits else None,
                    retires=retires,
                )
            )
            break
        blocked.append(f"{version}: {reason}")
    if blocked:
        found.append(
            Finding(
                ecosystem,
                name,
                pinned,
                in_line[0],
                Kind.PENDING,
                "; ".join(blocked),
            )
        )
    newer_lines = [v for v in candidates if not same_line(v, pinned, depth)]
    if newer_lines and lines and depth:
        version = newer_lines[0]
        manual = MANUAL_LINES.get(ecosystem)
        reason = None if manual or not installable else installable(version)
        move = None
        if line_edits and not manual and reason is None:
            move = functools.partial(line_edits, version)
        found.append(
            Finding(
                ecosystem,
                name,
                pinned,
                version,
                Kind.LINE,
                manual or (f"not installable yet: {reason}" if reason else ""),
                edits=move,
                retires=retires if move else (),
            )
        )
    return found or [Finding(ecosystem, name, pinned)]
