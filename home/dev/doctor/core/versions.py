"""Version strings: the token a banner reports, and their order."""

import re

_LEADING = re.compile(r"^[^0-9]+")
_TRAILING = re.compile(r"[,;)]+$")
_NUMERIC = re.compile(r"\d+(\.\d+)*")
_NUMBERS = re.compile(r"\d+")


def first_line(text: str) -> str:
    """The first line of ``text`` with any text on it, stripped."""
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def token(text: str) -> str:
    """The version a banner reports, or its first line when none is numeric.

    The first word of the first line that starts with a number, once a
    leading marker such as ``v`` or ``go`` is dropped, is the version:
    ``go version go1.27.1 darwin/arm64`` gives ``1.27.1`` and
    ``clang version 23.1.3`` gives ``23.1.3``. A suffix stays, so
    ``7.0.9-152-geb42c7b`` is kept whole.
    """
    line = first_line(text)
    for word in line.split():
        candidate = _TRAILING.sub("", _LEADING.sub("", word))
        if _NUMERIC.match(candidate):
            return candidate
    return line


def numbers(version: str) -> tuple[int, ...]:
    """The numeric components of a version, in order."""
    return tuple(int(part) for part in _NUMBERS.findall(version))


def at_least(version: str, minimum: str) -> bool:
    """Whether ``version`` is ``minimum`` or newer, by numeric components."""
    return numbers(version) >= numbers(minimum)
