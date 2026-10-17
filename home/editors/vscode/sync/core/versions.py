"""Extension versions and their order.

Marketplace versions are semantic versions, usually three numbers. They are
ordered by precedence: numbers compare as numbers, a missing number counts
as zero, and a pre-release sorts before its release. Anything else is not a
version, and a decision that depends on it is not taken.
"""

import re
from dataclasses import dataclass

_VERSION = re.compile(
    r"(?P<release>\d+(?:\.\d+)*)"
    r"(?:-(?P<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z.-]+)?"
)

_Identifier = tuple[int, int, str]


@dataclass(frozen=True, slots=True, eq=False)
class Version:
    """A parsed version; ``text`` is its spelling.

    Two versions are equal when they have the same precedence, so ``1.0``
    equals ``1.0.0``, and build metadata after ``+`` is ignored.
    """

    text: str
    release: tuple[int, ...]
    prerelease: tuple[_Identifier, ...]

    @property
    def key(self) -> tuple[tuple[int, ...], int, tuple[_Identifier, ...]]:
        """What versions are ordered by."""
        release = self.release
        while len(release) > 1 and release[-1] == 0:
            release = release[:-1]
        return release, 0 if self.prerelease else 1, self.prerelease

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Version):
            return NotImplemented
        return self.key == other.key

    def __hash__(self) -> int:
        return hash(self.key)

    def __lt__(self, other: "Version") -> bool:
        return self.key < other.key

    def __le__(self, other: "Version") -> bool:
        return self.key <= other.key

    def __gt__(self, other: "Version") -> bool:
        return self.key > other.key

    def __ge__(self, other: "Version") -> bool:
        return self.key >= other.key

    def __str__(self) -> str:
        return self.text


def parse_version(text: str | None) -> Version | None:
    """``text`` as a version, or None when it is not one."""
    if not text:
        return None
    found = _VERSION.fullmatch(text.strip())
    if found is None:
        return None
    release = tuple(int(part) for part in found["release"].split("."))
    identifiers: list[_Identifier] = []
    for part in (found["prerelease"] or "").split("."):
        if not part:
            continue
        if part.isdigit():
            identifiers.append((0, int(part), ""))
        else:
            identifiers.append((1, 0, part))
    return Version(text.strip(), release, tuple(identifiers))
