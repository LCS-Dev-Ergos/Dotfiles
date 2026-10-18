"""Terminal drawing primitives: the Python twin of terminal-style.zsh.

The look is defined once, in terminal-style.zsh next to this module, and this
module mirrors its tokens (tests/test_terminal_style.py compares the two).
Python tools bundle it at build time; Terminal-Style.md describes the model.
The masthead sits in a
rounded frame drawn in a two-column margin, so its inside lines up with the
content below: section titles followed by a rule, borderless tables one
indent in with quiet column labels, one marker and state word per row, and a
summary under a rule across the content.

Plain output, chosen by NO_COLOR, a pipe or a dumb terminal, is never colored
or truncated: a captured report stays complete. Nothing here runs a process;
interactions (Gum) belong to the frontend, not to drawing.
"""

import argparse
import os
import re
import shutil
import sys
import unicodedata
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import NoReturn, TextIO

# Style tokens. Keep them identical to _ZSH_UI_SGR and _ZSH_UI_GLYPH in
# terminal-style.zsh; tests/test_terminal_style.py checks.
SGR = {
    "strong": "1",
    "accent": "36",
    "badge": "1;7;36",
    "heading": "1;34",
    "frame": "34",
    "rule": "2;34",
    "muted": "38;5;245",
    "faint": "38;5;240",
    "ok": "32",
    "warn": "33",
    "error": "31",
}
GLYPH = {
    "ok": "●",
    "pending": "▲",
    "warn": "◆",
    "error": "✖",
    "muted": "○",
    "info": "›",
    "done": "✓",
    "rule": "─",
    "bar": "┃",
    "side": "│",
    "top_left": "╭",
    "top_right": "╮",
    "bottom_left": "╰",
    "bottom_right": "╯",
}
# The state words whose marker is not their tone's, as in
# _zsh_ui_status_glyph.
STATUS_GLYPHS = {
    "shadowed": "◆",
    "unknown": "?",
    "warn": "?",
    "warning": "?",
    "dormant": "◐",
}
# The margin on each side, where the masthead's frame lies, and the step in
# for what a section holds.
GUTTER = 2
INDENT = 2
MIN_WIDTH = 40
MAX_WIDTH = 120
# Gum's accents, as _zsh_ui_gum sets them: cyan prompts, cursors and
# spinners, blue selections and headers, never Gum's default pink.
GUM_THEME = {
    "GUM_CONFIRM_PROMPT_FOREGROUND": "6",
    "GUM_CONFIRM_SELECTED_BACKGROUND": "4",
    "GUM_CHOOSE_CURSOR_FOREGROUND": "6",
    "GUM_CHOOSE_HEADER_FOREGROUND": "4",
    "GUM_CHOOSE_SELECTED_FOREGROUND": "6",
    "GUM_SPIN_SPINNER_FOREGROUND": "6",
}


def _sgr(*tokens: str) -> str:
    return f"\033[{';'.join(SGR[token] for token in tokens)}m"


RESET = "\033[0m"
STRONG = _sgr("strong")
ACCENT = _sgr("accent")
HEADING = _sgr("heading")
MUTED = _sgr("muted")
FAINT = _sgr("faint")
FRAME = _sgr("frame")
RULE = _sgr("rule")

# A tone is how a state reads at a glance: its color and its marker. The
# marker is drawn bold; the state word keeps the plain color.
TONE_TOKENS = {
    "ok": "ok",  # healthy, done
    "pending": "warn",  # work is due: apply or prune --yes does it
    "warn": "warn",  # worth a look, but nothing failed
    "error": "error",  # failed, or needs a person
    "muted": "muted",  # informational, outside this tool's ownership
}
TONES = {tone: _sgr(token) for tone, token in TONE_TOKENS.items()}
# Plain summaries lead with the leveled label the shell's log lines use.
LABELS = {
    "ok": "[OK]   ",
    "muted": "[OK]   ",
    "pending": "[INFO] ",
    "warn": "[WARN] ",
    "error": "[ERROR]",
}
SEVERITY = ("ok", "muted", "pending", "warn", "error")

_SGR = re.compile(r"\033\[[0-9;]*m")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_STORE_HASH = re.compile(r"/nix/store/([a-z0-9]{7})[a-z0-9]{25}-")


@dataclass(frozen=True)
class Style:
    """Whether to draw, and the width to fit when drawing."""

    styled: bool
    width: int = 80

    @classmethod
    def detect(
        cls,
        stream: TextIO | None = None,
        environ: Mapping[str, str] | None = None,
    ) -> "Style":
        """Styled on a color terminal; plain for NO_COLOR, pipes and dumb."""
        stream = sys.stdout if stream is None else stream
        environ = os.environ if environ is None else environ
        isatty = getattr(stream, "isatty", None)
        styled = (
            not environ.get("NO_COLOR")
            and environ.get("TERM", "dumb") != "dumb"
            and bool(isatty and isatty())
        )
        columns = shutil.get_terminal_size((80, 24)).columns
        return cls(styled, clamp_width(columns))

    def paint(self, color: str, text: str) -> str:
        """The text in a color, when styled and both are given."""
        if self.styled and color and text:
            return f"{color}{text}{RESET}"
        return text

    def marker(self, tone: str, word: str = "") -> str:
        """The bold one-cell marker of a tone, or of a state word.

        A few state words keep a sharper marker than their tone's, as
        _zsh_ui_status_glyph draws them: ``?`` unknown, ``◐`` dormant.
        """
        glyph = STATUS_GLYPHS.get(word.lower(), GLYPH[tone])
        return self.paint(_sgr("strong", TONE_TOKENS[tone]), glyph)


class HelpFormatter(argparse.HelpFormatter):
    """Help whose description and epilog may hold lists and examples.

    A paragraph is refilled to the terminal unless it is laid out by hand:
    a line that is indented or ends in a colon keeps the whole paragraph as
    written. The usage line starts with a capital, like every sentence a
    tool prints.
    """

    def _fill_text(self, text: str, width: int, indent: str) -> str:
        paragraphs = []
        for paragraph in text.strip("\n").split("\n\n"):
            lines = paragraph.splitlines()
            if any(line[:1].isspace() or line.endswith(":") for line in lines):
                paragraphs.append("\n".join(indent + line for line in lines))
            else:
                paragraphs.append(super()._fill_text(paragraph, width, indent))
        return "\n\n".join(paragraphs)

    def add_usage(self, usage, actions, groups, prefix=None) -> None:
        if prefix is None:
            prefix = "Usage: "
        super().add_usage(usage, actions, groups, prefix)


class ArgumentParser(argparse.ArgumentParser):
    """An argument parser whose help reads in capitalized sentences.

    argparse's own headings and its ``--help`` line are lowercase; these
    replace them. Subcommands inherit the class, so their help matches.
    Pass ``version`` to add ``--version``.
    """

    def __init__(self, *args, version: str = "", **kwargs) -> None:
        kwargs.setdefault("formatter_class", HelpFormatter)
        add_help = kwargs.pop("add_help", True)
        super().__init__(*args, add_help=False, **kwargs)
        self._positionals.title = "Arguments"
        self._optionals.title = "Options"
        if add_help:
            self.add_argument(
                "-h", "--help", action="help", help="Show this help and exit"
            )
        if version:
            self.add_argument(
                "--version",
                action="version",
                version=version,
                help="Show the version and exit",
            )

    def error(self, message: str) -> NoReturn:
        """Print the usage and the message as a sentence; exit with 2."""
        self.print_usage(sys.stderr)
        self.exit(2, f"{self.prog}: {message[:1].upper()}{message[1:]}\n")


def clamp_width(columns: int, limit: int = MAX_WIDTH) -> int:
    """A readable width: never under 40 columns, never over the limit."""
    columns = columns if columns > 0 else 80
    return max(MIN_WIDTH, min(columns, limit))


def sanitize(text: object) -> str:
    """Escape control characters, so untrusted text cannot drive a terminal."""
    text = str(text)
    if not _CONTROL.search(text):
        return text
    escapes = {"\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return _CONTROL.sub(
        lambda match: escapes.get(match[0], f"\\x{ord(match[0]):02x}"), text
    )


def sanitize_lines(text: object) -> str:
    """sanitize() for a message of several lines, which stay lines."""
    return "\n".join(sanitize(line) for line in str(text).split("\n"))


def strip(text: str) -> str:
    """The text without its color sequences."""
    return _SGR.sub("", text)


def _cell(character: str) -> int:
    if unicodedata.combining(character):
        return 0
    return 2 if unicodedata.east_asian_width(character) in "WF" else 1


def text_width(text: str) -> int:
    """Display width: color sequences take none, wide characters two."""
    return sum(_cell(character) for character in strip(text))


def _head(text: str, width: int) -> str:
    """The longest prefix that fits the display width."""
    used = 0
    for index, character in enumerate(text):
        used += _cell(character)
        if used > width:
            return text[:index]
    return text


def _tail(text: str, width: int) -> str:
    """The longest suffix that fits the display width."""
    return _head(text[::-1], width)[::-1]


def _path_middle(text: str, width: int) -> str | None:
    """Drop whole middle components of a path, keeping its end first.

    The file name and the versioned directories above it say the most, then
    the root; "~/.local/…/v24.21.0/bin/node" reads better than a cut word.
    None when not even the root and the last component fit.
    """
    parts = text.split("/")
    if len(parts) < 3:
        return None
    head, tail = 1, 1

    def joined(head: int, tail: int) -> str:
        return "/".join(parts[:head] + ["…"] + parts[len(parts) - tail :])

    if text_width(joined(head, tail)) > width:
        return None
    # An absolute path keeps its first directory (/nix, /opt) when it can:
    # the bare root says nothing.
    if not parts[0] and len(parts) > 3 and text_width(joined(2, 1)) <= width:
        head = 2
    while head + tail < len(parts) - 1:
        if text_width(joined(head, tail + 1)) <= width:
            tail += 1
        elif text_width(joined(head + 1, tail)) <= width:
            head += 1
        else:
            break
    return joined(head, tail)


def truncate(text: str, width: int) -> str:
    """Shorten to a display width with an ellipsis.

    A path loses whole middle components, so its root and its file name stay
    visible; "link → target" shortens each side on its own; other text loses
    its end.
    """
    if text_width(text) <= width:
        return text
    if width < 2:
        return _head(text, max(width, 0))
    if "/" in text and " " not in text:
        shortened = _path_middle(text, width)
        if shortened is not None:
            return shortened
    if " → " in text and width >= 11:
        left, right = text.split(" → ", 1)
        left_budget = (width - 3) // 2
        right_budget = width - 3 - left_budget
        if text_width(left) < left_budget:
            right_budget += left_budget - text_width(left)
        if text_width(right) < right_budget:
            left_budget += right_budget - text_width(right)
        return (
            f"{truncate(left, left_budget)} → {truncate(right, right_budget)}"
        )
    tail = (width - 1) * 3 // 5
    head = width - 1 - tail
    if "/" in text and head > 0 and tail > 0:
        return f"{_head(text, head)}…{_tail(text, tail)}"
    return f"{_head(text, width - 1)}…"


def wrap(text: str, width: int) -> list[str]:
    """Word-wrap to a display width; a longer word is split, never lost."""
    width = max(width, 1)
    lines: list[str] = []
    line = ""
    for word in text.split():
        while text_width(word) > width:
            if line:
                lines.append(line)
                line = ""
            piece = _head(word, width)
            lines.append(piece)
            word = word[len(piece) :]
        if not word:
            continue
        if not line:
            line = word
        elif text_width(line) + 1 + text_width(word) <= width:
            line += f" {word}"
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines or [""]


def short_path(text: str, style: Style, home: str | None = None) -> str:
    """Write $HOME as ~ and cut store hashes, in styled output only.

    Plain output keeps every path intact, so a captured report can still be
    copied from.
    """
    if not style.styled:
        return text
    home = os.environ.get("HOME", "") if home is None else home
    if home and home != "/":
        text = text.replace(f"{home.rstrip('/')}/", "~/")
    return _STORE_HASH.sub(r"/nix/store/\1…-", text)


def pad(text: str, width: int) -> str:
    """Left-align text, which may carry color, in a display width."""
    return text + " " * max(width - text_width(text), 0)


def _gutter(text: str = "") -> str:
    return f"{' ' * GUTTER}{text}"


def frame(style: Style, lines: Sequence[str]) -> list[str]:
    """A rounded frame around styled lines, drawn in the margin.

    The lines inside start and end where the content below does; each is
    padded to the frame's inside.
    """
    inner = style.width - 2 * GUTTER
    edge = GLYPH["rule"] * (style.width - 2)
    side = style.paint(FRAME, GLYPH["side"])
    margin = " " * (GUTTER - 1)
    return (
        [style.paint(FRAME, f"{GLYPH['top_left']}{edge}{GLYPH['top_right']}")]
        + [f"{side}{margin}{pad(line, inner)}{margin}{side}" for line in lines]
        + [
            style.paint(
                FRAME, f"{GLYPH['bottom_left']}{edge}{GLYPH['bottom_right']}"
            )
        ]
    )


def header(
    style: Style,
    tag: str,
    title: str,
    subtitle: str = "",
    context: str = "",
    note: str = "",
) -> list[str]:
    """The masthead: the tool's badge and title, then a quieter line.

    Context sits at the right of the title and the note at the right of the
    subtitle; each gives way before the text it shares a line with is cut.
    Styled output frames both lines; plain output keeps every part on two
    bare lines.
    """
    tag, title, subtitle, context, note = map(
        sanitize, (tag, title, subtitle, context, note)
    )
    if not style.styled:
        details = " · ".join(
            part for part in (subtitle, context, note) if part
        )
        return [f"{tag} · {title}"] + ([details] if details else [])

    badge = f" {tag.upper()} "
    indent = text_width(badge) + 2
    room = style.width - 2 * GUTTER - indent
    if text_width(title) + 2 + text_width(context) > room:
        context = ""
    if text_width(subtitle) + 2 + text_width(note) > room:
        note = ""
    title = truncate(title, room)
    subtitle = truncate(subtitle, room)
    gap1 = room - text_width(title) - text_width(context)
    gap2 = room - text_width(subtitle) - text_width(note)
    lines = [
        f"{style.paint(_sgr('badge'), badge)}  "
        f"{style.paint(STRONG, title)}{' ' * gap1}"
        f"{style.paint(MUTED, context)}"
    ]
    if subtitle or note:
        lines.append(
            f"{' ' * indent}{style.paint(MUTED, subtitle)}{' ' * gap2}"
            f"{style.paint(MUTED, note)}"
        )
    return frame(style, lines)


def section(style: Style, title: str, note: str = "") -> list[str]:
    """A section title, then a rule to the right margin ending in a note.

    The note, muted, gives way before the rule grows too short to read as
    one. Plain output is the bare title, with " · note" when there is one.
    """
    title, note = sanitize(title), sanitize(note)
    if not style.styled:
        return [f"{title} · {note}" if note else title]
    room = style.width - 2 * GUTTER
    title = truncate(title, room)
    # title, space, rule, space, note
    fill = room - text_width(title) - text_width(note) - 2
    if not note or fill < 3:
        note, fill = "", room - text_width(title) - 1
    line = style.paint(HEADING, title)
    if fill > 0:
        line += f" {style.paint(RULE, GLYPH['rule'] * fill)}"
    if note:
        line += f" {style.paint(MUTED, note)}"
    return [_gutter(line)]


@dataclass
class Column:
    """A table column and how it gives way when the width runs out.

    Columns below priority 100 may be dropped, lowest first; a column with
    `shrink` is shortened down to that width before anything is dropped.
    `fold` names the row tones whose cell, when the column is dropped,
    continues the row on its own line instead of vanishing.
    """

    label: str
    priority: int = 100
    limit: int = 0
    shrink: int = 0
    fold: tuple[str, ...] = ()


@dataclass
class Cell:
    """A table cell or card value: its text, color and whether it is a path."""

    text: str
    color: str = ""
    path: bool = False


@dataclass
class Note:
    """A line that continues a row: a reason, a fix, a location."""

    text: str
    color: str = MUTED
    label: str = ""
    path: bool = False


@dataclass
class Row:
    """A table row: its cells, the tone of its marker and its notes."""

    cells: Sequence[Cell | str]
    tone: str = ""
    notes: list[Note] = field(default_factory=list[Note])


def _cells(row: Row, style: Style) -> list[Cell]:
    cells: list[Cell] = []
    for cell in row.cells:
        cell = cell if isinstance(cell, Cell) else Cell(cell)
        text = sanitize(cell.text)
        if cell.path:
            text = short_path(text, style)
        cells.append(Cell(text, cell.color, cell.path))
    return cells


def _fit(
    columns: Sequence[Column], widths: Sequence[int], available: int
) -> tuple[list[int], dict[int, int]]:
    """The columns that fit and their widths, after shrinking and dropping."""
    active = list(range(len(columns)))

    def floor(index: int) -> int:
        shrink = columns[index].shrink
        return min(widths[index], shrink) if shrink else widths[index]

    def total(measure: Callable[[int], int]) -> int:
        return sum(measure(index) for index in active) + 2 * (len(active) - 1)

    while total(floor) > available:
        droppable = [i for i in active if columns[i].priority < 100]
        if not droppable:
            break
        active.remove(min(droppable, key=lambda i: columns[i].priority))
    fitted = {index: widths[index] for index in active}
    excess = total(lambda index: fitted[index]) - available
    for index in sorted(active, key=lambda i: -fitted[i]):
        if excess <= 0:
            break
        if columns[index].shrink:
            cut = min(excess, fitted[index] - floor(index))
            fitted[index] -= cut
            excess -= cut
    if excess > 0 and active:
        # Nothing left to drop or shrink: the last column takes the cut.
        last = active[-1]
        fitted[last] = max(fitted[last] - excess, 1)
    return active, fitted


def table(
    style: Style, columns: Sequence[Column], rows: Iterable[Row]
) -> list[str]:
    """A borderless table one indent in: quiet labels, then one line a row.

    Rows with a tone lead with its marker. A row's notes continue it under
    the first column, wrapped to the right margin; paths are shortened
    instead. Plain output aligns every column at full length and keeps every
    note.
    """
    prepared = list(rows)
    cells = [_cells(row, style) for row in prepared]
    labels = [column.label.upper() for column in columns]
    if not style.styled:
        return _plain_table(labels, prepared, cells)

    marked = any(row.tone for row in prepared)
    offset = GUTTER + INDENT
    prefix = offset + (2 if marked else 0)
    widths: list[int] = []
    for index, column in enumerate(columns):
        width = max(
            [text_width(labels[index])]
            + [text_width(line[index].text) for line in cells]
        )
        widths.append(min(width, column.limit) if column.limit else width)
    active, fitted = _fit(columns, widths, style.width - prefix - GUTTER)
    dropped = [i for i in range(len(columns)) if i not in active]

    def joined(texts: Sequence[str]) -> str:
        last = active[-1]
        return "  ".join(
            texts[index] if index == last else pad(texts[index], fitted[index])
            for index in active
        )

    lines = [
        " " * prefix
        + style.paint(
            MUTED,
            joined(
                [
                    truncate(label, fitted.get(i, 0))
                    for i, label in enumerate(labels)
                ]
            ),
        ).rstrip()
    ]
    for row, line in zip(prepared, cells, strict=True):
        texts: list[str] = []
        for index, cell in enumerate(line):
            if index not in fitted:
                texts.append("")
                continue
            text = truncate(cell.text, fitted[index])
            texts.append(style.paint(cell.color, text))
        lead = f"{style.marker(row.tone)} " if row.tone else "  " * marked
        lines.append(f"{' ' * offset}{lead}{joined(texts)}".rstrip())
        folded = [
            Note(cell.text, cell.color, path=cell.path)
            for index, cell in enumerate(line)
            if index in dropped
            and row.tone in columns[index].fold
            and cell.text
        ]
        # A note reads why, then where, then how: a folded state leads, a
        # folded location follows the plain reasons, and labeled notes
        # (fix, steps) close.
        labeled = next(
            (i for i, note in enumerate(row.notes) if note.label),
            len(row.notes),
        )
        notes = (
            [note for note in folded if not note.path]
            + row.notes[:labeled]
            + [note for note in folded if note.path]
            + row.notes[labeled:]
        )
        lines += _notes(style, notes, prefix)
    return lines


def _notes(style: Style, notes: Sequence[Note], indent: int) -> list[str]:
    lines: list[str] = []
    room = style.width - indent - GUTTER
    for note in notes:
        text = sanitize(note.text)
        label = f"{note.label}  " if note.label else ""
        if note.path:
            pieces = [truncate(short_path(text, style), room - len(label))]
        else:
            pieces = wrap(text, room - len(label))
        for number, piece in enumerate(pieces):
            lead = (
                style.paint(MUTED, label) if number == 0 else " " * len(label)
            )
            lines.append(
                f"{' ' * indent}{lead}{style.paint(note.color, piece)}"
            )
    return lines


def _plain_table(
    labels: Sequence[str], rows: Sequence[Row], cells: Sequence[list[Cell]]
) -> list[str]:
    texts = [[cell.text or "-" for cell in line] for line in cells]
    widths = [
        max([text_width(label)] + [text_width(line[index]) for line in texts])
        for index, label in enumerate(labels)
    ]

    def joined(texts: Sequence[str]) -> str:
        return "  ".join(
            text if index == len(texts) - 1 else pad(text, widths[index])
            for index, text in enumerate(texts)
        )

    lines = [joined(labels)]
    for row, line in zip(rows, texts, strict=True):
        lines.append(joined(line))
        for note in row.notes:
            label = f"{note.label}: " if note.label else ""
            lines.append(f"  {label}{sanitize(note.text)}")
    return lines


def card(
    style: Style,
    title: str,
    fields: Sequence[tuple[str, Cell | str]],
    note: str = "",
) -> list[str]:
    """A section of `key  value` lines, one indent in.

    A value is text or a Cell; a path is shortened when styled and other
    text wraps under itself. Plain output keeps every value whole.
    """
    keys = [sanitize(key) for key, _ in fields]
    values = [
        value if isinstance(value, Cell) else Cell(value)
        for _, value in fields
    ]
    width = max((text_width(key) for key in keys), default=0)
    lines = section(style, title, note)
    if not style.styled:
        return lines + [
            f"{pad(key, width)}  {sanitize(value.text)}"
            for key, value in zip(keys, values, strict=True)
        ]
    indent = " " * (GUTTER + INDENT)
    room = style.width - GUTTER - INDENT - GUTTER - width - 2
    for key, value in zip(keys, values, strict=True):
        text = sanitize(value.text)
        if value.path:
            pieces = [truncate(short_path(text, style), room)]
        else:
            pieces = wrap(text, room)
        for number, piece in enumerate(pieces):
            label = pad(key, width) if number == 0 else " " * width
            lines.append(
                f"{indent}{style.paint(MUTED, label)}  "
                f"{style.paint(value.color, piece)}"
            )
    return lines


def callout(
    style: Style, tone: str, title: str, lines: Sequence[str] = ()
) -> list[str]:
    """A notice set off by a bar in its tone's color: no frame around it."""
    title = sanitize(title)
    texts = [sanitize(line) for line in lines]
    if not style.styled:
        return [title] + [f"  {line}" for line in texts]
    bar = style.paint(TONES[tone], GLYPH["bar"])
    room = style.width - 2 * GUTTER - 2
    body = [style.paint(STRONG, truncate(title, room))]
    for line in texts:
        body += wrap(line, room)
    return [_gutter(f"{bar} {line}") for line in body]


def worst(tones: Iterable[str]) -> str:
    """The most severe tone, for a summary's label."""
    return max(tones, key=SEVERITY.index, default="ok")


def summary(
    style: Style,
    counts: Iterable[tuple[str, int, str]],
    hint: str = "",
    tone: str = "ok",
) -> list[str]:
    """Close a report: the count of each state and what to do next.

    counts holds (tone, count, word) in display order. Styled output draws a
    rule across the content, then the markers and counts with the hint on
    the right margin; plain output is one leveled line, the counts and the
    hint as two sentences, whose level `tone` raises when the outcome is
    worse than the counts say. The hint is a sentence of its own, so it
    starts with a capital unless it starts with a command.
    """
    shown = [entry for entry in counts if entry[1]]
    hint = sanitize(hint)
    if not style.styled:
        words = ", ".join(f"{count} {word}" for _, count, word in shown)
        text = " ".join(f"{part}." for part in (words, hint) if part)
        label = LABELS[worst([tone, *(entry[0] for entry in shown)])]
        return [f"{label} {text}" if text else label.rstrip()]
    room = style.width - 2 * GUTTER
    items = [
        f"{style.marker(state, word)} {count} {word}"
        for state, count, word in shown
    ]
    # Counts wrap rather than overflow a narrow terminal; the hint only
    # restates them, so it gives way first.
    lines = [""]
    for item in items:
        if lines[-1] and text_width(f"{lines[-1]}   {item}") > room:
            lines.append("")
        lines[-1] += f"   {item}" if lines[-1] else item
    gap = room - text_width(lines[-1]) - text_width(hint)
    if gap < 3:
        hint, gap = "", 0
    lines[-1] += f"{' ' * gap}{style.paint(MUTED, hint)}"
    return [_gutter(style.paint(RULE, GLYPH["rule"] * room))] + [
        _gutter(line).rstrip() for line in lines
    ]
