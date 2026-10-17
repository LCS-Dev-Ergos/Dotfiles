"""Text edits on the settings source and the layout they must match."""

import json
from collections.abc import Iterable
from dataclasses import dataclass

from .errors import SettingsError
from .jsonc import Document

_DEFAULT_INDENT = "  "


@dataclass(frozen=True, slots=True)
class Edit:
    """Replace ``source[start:end]`` with ``text``; ``start == end`` inserts."""

    start: int
    end: int
    text: str


def apply_edits(source: str, edits: Iterable[Edit]) -> str:
    """Apply non-overlapping edits to ``source``.

    Edits at the same position keep the order they were given in, so an
    insertion planned after a replacement lands after it.

    Raises:
        SettingsError: If two edits overlap, which would mean a planning bug.
    """
    ordered = sorted(
        enumerate(edits),
        key=lambda pair: (pair[1].start, pair[1].end, pair[0]),
    )
    out: list[str] = []
    cursor = 0
    for _, edit in ordered:
        if edit.start < cursor or edit.end < edit.start:
            raise SettingsError("internal error: overlapping edits")
        out += (source[cursor : edit.start], edit.text)
        cursor = edit.end
    out.append(source[cursor:])
    return "".join(out)


def line_start(text: str, offset: int) -> int:
    """The offset of the first character of the line holding ``offset``."""
    return text.rfind("\n", 0, offset) + 1


def json_string(value: str) -> str:
    """``value`` as a JSON string literal, with non-ASCII text kept as is."""
    return json.dumps(value, ensure_ascii=False)


@dataclass(frozen=True, slots=True)
class Layout:
    """The line ending and indentation that inserted text must use."""

    newline: str
    indent: str

    @classmethod
    def detect(cls, doc: Document) -> "Layout":
        """Read the layout of a document.

        The newline is CRLF when most line breaks are. The indent is the
        leading whitespace of the first top-level key that starts its own
        line, or two spaces when there is none.
        """
        crlf = doc.text.count("\r\n")
        lone = doc.text.count("\n") - crlf
        newline = "\r\n" if crlf and crlf >= lone else "\n"
        indent = _DEFAULT_INDENT
        for member in doc.root.members:
            prefix = doc.text[
                line_start(doc.text, member.start) : member.start
            ]
            if prefix and not prefix.strip():
                indent = prefix
                break
        return cls(newline, indent)
