"""Release arithmetic shared by every resolver."""

import re
from collections.abc import Iterable

STABLE = re.compile(r"[0-9]+(?:\.[0-9]+)*")


def numeric(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"[0-9]+", version))


def stable(version: str) -> bool:
    return STABLE.fullmatch(version) is not None


def same_line(version: str, pinned: str, depth: int) -> bool:
    return numeric(version)[:depth] == numeric(pinned)[:depth]


def line(version: str, depth: int) -> str:
    """The leading `depth` components that name a release's line."""
    return ".".join(map(str, numeric(version)[:depth]))


def newer(candidates: Iterable[str], pinned: str) -> list[str]:
    """Candidates above the pinned release, newest first."""
    return sorted(
        {v for v in candidates if numeric(v) > numeric(pinned)},
        key=numeric,
        reverse=True,
    )
