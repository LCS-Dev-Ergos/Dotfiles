"""Extension versions and their order.

Marketplace versions are semantic versions, usually three numbers. They are
ordered by precedence: numbers compare as numbers, a missing number counts
as zero, and a pre-release sorts before its release. Anything else is not a
version, and a decision that depends on it is not taken.

An extension's ``engines.vscode`` names the oldest VS Code it runs on, as
``^1.90.0``, ``>=1.90.0``, ``1.90.x`` or ``*``. ``engine_allows`` checks it
against a VS Code version the way VS Code does for these forms; a form it
does not know counts as not allowed.
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


_ENGINE = re.compile(
    r"(?:\^|>=)?\s*(?P<major>\d+)\.(?P<minor>\d+|x)\.(?P<patch>\d+|x)"
    r"(?P<suffix>-[0-9A-Za-z.-]+)?"
)


def engine_allows(requirement: object, version: Version) -> bool:
    """Whether an extension with ``engines.vscode`` runs on ``version``.

    A requirement with a suffix such as ``-20251020`` asks for a build of
    that date or later, which the version alone cannot show; it is allowed
    only from the next minor release on.
    """
    if requirement is None or requirement == "*":
        return True
    if not isinstance(requirement, str):
        return False
    found = _ENGINE.fullmatch(requirement.strip())
    if found is None:
        return False
    floor = tuple(
        0 if found[part] == "x" else int(found[part])
        for part in ("major", "minor", "patch")
    )
    current = (*version.release, 0, 0)[:3]
    if found["suffix"]:
        return current[:2] > floor[:2]
    return current >= floor
