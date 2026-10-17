"""A strict reader for VS Code's JSONC that keeps every node's position.

settings.json is JSON with comments and trailing commas. Each node records its
span in the source, so an edit can replace exactly one literal and leave the
rest of the text alone. The reader is strict on purpose: anything it does not
fully understand is an error, because the alternative is editing blind.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import NamedTuple, TypeAlias

from .errors import SettingsError

MAX_NESTING = 64
"""Deepest container nesting accepted, a bound on the reader's recursion."""

Scalar: TypeAlias = bool | int | float | None
NodePath: TypeAlias = tuple[str | int, ...]

_LITERAL_END = re.compile(r'[\s,\]\}\[\{:"/]')
_NON_FINITE = frozenset({"NaN", "Infinity", "-Infinity"})


class Span(NamedTuple):
    """A half-open range of offsets into the source text."""

    start: int
    end: int


@dataclass(frozen=True, slots=True)
class StringNode:
    """A string literal; ``value`` is the decoded text."""

    start: int
    end: int
    value: str


@dataclass(frozen=True, slots=True)
class ScalarNode:
    """A number, ``true``, ``false`` or ``null``."""

    start: int
    end: int
    value: Scalar


@dataclass(frozen=True, slots=True)
class Member:
    """A ``"key": value`` pair of an object.

    ``start`` is the first character of the key literal and ``comma`` the
    offset of the comma that follows the value, if there is one.
    """

    key: str
    start: int
    value: JsonNode
    comma: int | None

    @property
    def end(self) -> int:
        """The offset just past the value."""
        return self.value.end


@dataclass(frozen=True, slots=True)
class ObjectNode:
    """An object; ``close`` is the offset of its closing brace."""

    start: int
    end: int
    close: int
    members: tuple[Member, ...]

    def named(self, key: str) -> tuple[Member, ...]:
        """Every member called ``key``, in source order."""
        return tuple(member for member in self.members if member.key == key)


@dataclass(frozen=True, slots=True)
class ArrayNode:
    """An array; ``close`` is the offset of its closing bracket."""

    start: int
    end: int
    close: int
    items: tuple[JsonNode, ...]


JsonNode: TypeAlias = ObjectNode | ArrayNode | StringNode | ScalarNode


@dataclass(frozen=True, slots=True)
class Document:
    """A parsed settings file and the spans of its ``//`` comments."""

    text: str
    root: ObjectNode
    comments: tuple[Span, ...]


class _Parser:
    """A recursive descent over the text that records offsets as it goes."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.offset = 0
        self.comments: list[Span] = []

    def fail(self, message: str, at: int | None = None) -> SettingsError:
        """An error that names the line and column of ``at``."""
        offset = self.offset if at is None else at
        line = self.text.count("\n", 0, offset) + 1
        column = offset - (self.text.rfind("\n", 0, offset) + 1) + 1
        return SettingsError(
            f"settings are not valid JSONC ({line}:{column}): {message}"
        )

    def skip(self) -> None:
        """Advance past whitespace and comments, recording line comments."""
        text, length, offset = self.text, len(self.text), self.offset
        while offset < length:
            if text[offset] in " \t\r\n":
                offset += 1
            elif text.startswith("//", offset):
                newline = text.find("\n", offset)
                end = length if newline < 0 else newline
                self.comments.append(Span(offset, end))
                offset = end
            elif text.startswith("/*", offset):
                close = text.find("*/", offset + 2)
                if close < 0:
                    raise self.fail("unterminated block comment", offset)
                offset = close + 2
            else:
                break
        self.offset = offset

    def peek(self) -> str:
        """The character at the cursor, or an empty string at the end."""
        if self.offset < len(self.text):
            return self.text[self.offset]
        return ""

    def document(self) -> Document:
        """Parse the whole text as one top-level object."""
        self.skip()
        if self.offset >= len(self.text):
            raise self.fail("the file is empty")
        root = self.value(0)
        self.skip()
        if self.offset != len(self.text):
            raise self.fail("unexpected content after the closing brace")
        if not isinstance(root, ObjectNode):
            raise self.fail("the top level must be an object", root.start)
        return Document(self.text, root, tuple(self.comments))

    def value(self, depth: int) -> JsonNode:
        """Parse the value at the cursor."""
        if depth > MAX_NESTING:
            raise self.fail("nesting is too deep")
        char = self.peek()
        if char == "{":
            return self.object(depth)
        if char == "[":
            return self.array(depth)
        if char == '"':
            return self.string()
        if not char:
            raise self.fail("unexpected end of file")
        return self.scalar()

    def object(self, depth: int) -> ObjectNode:
        """Parse an object, allowing a trailing comma."""
        start = self.offset
        self.offset += 1
        members: list[Member] = []
        while True:
            self.skip()
            char = self.peek()
            if char == "}":
                close = self.offset
                self.offset += 1
                return ObjectNode(start, self.offset, close, tuple(members))
            if char != '"':
                raise self.fail("expected a string key or '}'")
            key = self.string()
            self.skip()
            if self.peek() != ":":
                raise self.fail("expected ':' after the key")
            self.offset += 1
            self.skip()
            value = self.value(depth + 1)
            self.skip()
            comma: int | None = None
            char = self.peek()
            if char == ",":
                comma = self.offset
                self.offset += 1
            elif char != "}":
                raise self.fail("expected ',' or '}'")
            members.append(Member(key.value, key.start, value, comma))

    def array(self, depth: int) -> ArrayNode:
        """Parse an array, allowing a trailing comma."""
        start = self.offset
        self.offset += 1
        items: list[JsonNode] = []
        while True:
            self.skip()
            char = self.peek()
            if char == "]":
                close = self.offset
                self.offset += 1
                return ArrayNode(start, self.offset, close, tuple(items))
            items.append(self.value(depth + 1))
            self.skip()
            char = self.peek()
            if char == ",":
                self.offset += 1
            elif char != "]":
                raise self.fail("expected ',' or ']'")

    def string(self) -> StringNode:
        """Parse a string literal and decode it with the JSON rules."""
        text, start = self.text, self.offset
        offset, length = start + 1, len(text)
        while True:
            if offset >= length:
                raise self.fail("unterminated string", start)
            char = text[offset]
            if char == "\\":
                offset += 2
                continue
            if char == '"':
                break
            if ord(char) < 0x20:
                raise self.fail("control character inside a string", offset)
            offset += 1
        try:
            decoded = json.loads(text[start : offset + 1])
        except ValueError as error:
            raise self.fail(f"invalid string ({error})", start) from None
        if not isinstance(decoded, str):
            raise self.fail("invalid string", start)
        self.offset = offset + 1
        return StringNode(start, self.offset, decoded)

    def scalar(self) -> ScalarNode:
        """Parse a number or keyword; non-finite numbers are not JSON."""
        text, start = self.text, self.offset
        match = _LITERAL_END.search(text, start)
        end = match.start() if match else len(text)
        raw = text[start:end]
        if not raw or raw in _NON_FINITE:
            raise self.fail("unexpected character")
        try:
            decoded = json.loads(raw)
        except ValueError:
            raise self.fail(f"invalid value {raw!r}", start) from None
        if decoded is not None and not isinstance(decoded, bool | int | float):
            raise self.fail(f"invalid value {raw!r}", start)
        self.offset = end
        return ScalarNode(start, end, decoded)


def parse(text: str) -> Document:
    """Parse settings text.

    Args:
        text: The file content without a byte order mark.

    Returns:
        The parsed document.

    Raises:
        SettingsError: If the text is not valid JSONC.
    """
    return _Parser(text).document()


def diff_paths(
    before: JsonNode, after: JsonNode, path: NodePath = ()
) -> set[NodePath]:
    """Return the paths at which two values differ.

    Layout, comments and trailing commas are ignored. A change in the shape of
    an object (its keys or their order) or of an array (its length) is
    reported at that container rather than below it.
    """
    match before, after:
        case ObjectNode() as left, ObjectNode() as right:
            keys = [member.key for member in left.members]
            if keys != [member.key for member in right.members]:
                return {path}
            found: set[NodePath] = set()
            for old, new in zip(left.members, right.members, strict=True):
                found |= diff_paths(old.value, new.value, (*path, old.key))
            return found
        case ArrayNode() as left, ArrayNode() as right:
            if len(left.items) != len(right.items):
                return {path}
            found = set()
            for index, (old, new) in enumerate(
                zip(left.items, right.items, strict=True)
            ):
                found |= diff_paths(old, new, (*path, index))
            return found
        case StringNode() as left, StringNode() as right:
            return set() if left.value == right.value else {path}
        case ScalarNode() as left, ScalarNode() as right:
            same_type = type(left.value) is type(right.value)
            return set() if same_type and left.value == right.value else {path}
        case _:
            return {path}


def describe_path(path: NodePath) -> str:
    """Format a node path the way the Settings editor spells it."""
    out = ""
    for part in path:
        if isinstance(part, int):
            out += f"[{part}]"
        else:
            out += f".{part}" if out else part
    return out
