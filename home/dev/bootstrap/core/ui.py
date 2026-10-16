"""Terminal drawing primitives: the Python twin of the shell's style module.

The look is defined once, in `_ui.zsh` of the Zsh configuration, and this
module mirrors its tokens (a test compares the two). The masthead sits in a
rounded frame drawn in a two-column margin, so its inside lines up with the
content below: section titles followed by a rule, borderless tables one
indent in with quiet column labels, one marker and state word per row, and a
summary under a rule across the content.

Plain output, chosen by NO_COLOR, a pipe or a dumb terminal, is never colored
or truncated: a captured report stays complete. Nothing here runs a process;
interactions (Gum) belong to the frontend, not to drawing.
"""

import os
import re
import shutil
import sys
import unicodedata
from dataclasses import dataclass, field

# Style tokens. Keep them identical to _ZSH_UI_SGR and _ZSH_UI_GLYPH in
# home/shells/zsh/config/scripts/_ui.zsh; tests/unit/test_render.py checks.
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
# The margin on each side, where the masthead's frame lies, and the step in
# for what a section holds.
GUTTER = 2
INDENT = 2
MIN_WIDTH = 40
MAX_WIDTH = 120


def _sgr(*tokens):
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
    def detect(cls, stream=None, environ=None):
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

    def paint(self, color, text):
        if self.styled and color and text:
            return f"{color}{text}{RESET}"
        return text

    def marker(self, tone):
        """The bold one-cell marker of a tone."""
        return self.paint(_sgr("strong", TONE_TOKENS[tone]), GLYPH[tone])


def clamp_width(columns, limit=MAX_WIDTH):
    """A readable width: never under 40 columns, never over the limit."""
    columns = columns if columns > 0 else 80
    return max(MIN_WIDTH, min(columns, limit))


def sanitize(text):
    """Escape control characters, so untrusted text cannot drive a terminal."""
    text = str(text)
    if not _CONTROL.search(text):
        return text
    escapes = {"\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return _CONTROL.sub(
        lambda match: escapes.get(match[0], f"\\x{ord(match[0]):02x}"), text
    )


def sanitize_lines(text):
    """sanitize() for a message of several lines, which stay lines."""
    return "\n".join(sanitize(line) for line in str(text).split("\n"))


def strip(text):
    """The text without its color sequences."""
    return _SGR.sub("", text)


def _cell(character):
    if unicodedata.combining(character):
        return 0
    return 2 if unicodedata.east_asian_width(character) in "WF" else 1


def text_width(text):
    """Display width: color sequences take none, wide characters two."""
    return sum(_cell(character) for character in strip(text))


def _head(text, width):
    """The longest prefix that fits the display width."""
    used = 0
    for index, character in enumerate(text):
        used += _cell(character)
        if used > width:
            return text[:index]
    return text


def _tail(text, width):
    """The longest suffix that fits the display width."""
    return _head(text[::-1], width)[::-1]


def _path_middle(text, width):
    """Drop whole middle components of a path, keeping its end first.

    The file name and the versioned directories above it say the most, then
    the root; "~/.local/…/v24.21.0/bin/node" reads better than a cut word.
    None when not even the root and the last component fit.
    """
    parts = text.split("/")
    if len(parts) < 3:
        return None
    head, tail = 1, 1

    def joined(head, tail):
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


def truncate(text, width):
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


def wrap(text, width):
    """Word-wrap to a display width; a longer word is split, never lost."""
    width = max(width, 1)
    lines, line = [], ""
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


def short_path(text, style, home=None):
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


def pad(text, width):
    """Left-align text, which may carry color, in a display width."""
    return text + " " * max(width - text_width(text), 0)


def _gutter(text=""):
    return f"{' ' * GUTTER}{text}"


def frame(style, lines):
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


def header(style, tag, title, subtitle="", context="", note=""):
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


def section(style, title, note=""):
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
    fold: tuple = ()


@dataclass
class Cell:
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
    cells: list
    tone: str = ""
    notes: list = field(default_factory=list)


def _cells(row, style):
    cells = []
    for cell in row.cells:
        cell = cell if isinstance(cell, Cell) else Cell(cell)
        text = sanitize(cell.text)
        if cell.path:
            text = short_path(text, style)
        cells.append(Cell(text, cell.color, cell.path))
    return cells


def _fit(columns, widths, available):
    """The columns that fit and their widths, after shrinking and dropping."""
    active = list(range(len(columns)))

    def floor(index):
        shrink = columns[index].shrink
        return min(widths[index], shrink) if shrink else widths[index]

    def total(measure):
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


def table(style, columns, rows):
    """A borderless table one indent in: quiet labels, then one line a row.

    Rows with a tone lead with its marker. A row's notes continue it under
    the first column, wrapped to the right margin; paths are shortened
    instead. Plain output aligns every column at full length and keeps every
    note.
    """
    rows = [Row(_cells(row, style), row.tone, row.notes) for row in rows]
    labels = [column.label.upper() for column in columns]
    if not style.styled:
        return _plain_table(labels, rows)

    marked = any(row.tone for row in rows)
    offset = GUTTER + INDENT
    prefix = offset + (2 if marked else 0)
    widths = []
    for index, column in enumerate(columns):
        width = max(
            [text_width(labels[index])]
            + [text_width(row.cells[index].text) for row in rows]
        )
        widths.append(min(width, column.limit) if column.limit else width)
    active, fitted = _fit(columns, widths, style.width - prefix - GUTTER)
    dropped = [i for i in range(len(columns)) if i not in active]

    def joined(texts):
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
    for row in rows:
        texts = []
        for index, cell in enumerate(row.cells):
            if index not in fitted:
                texts.append("")
                continue
            text = truncate(cell.text, fitted[index])
            texts.append(style.paint(cell.color, text))
        lead = f"{style.marker(row.tone)} " if row.tone else "  " * marked
        lines.append(f"{' ' * offset}{lead}{joined(texts)}".rstrip())
        folded = [
            Note(cell.text, cell.color, path=cell.path)
            for index, cell in enumerate(row.cells)
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


def _notes(style, notes, indent):
    lines = []
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


def _plain_table(labels, rows):
    cells = [[cell.text or "-" for cell in row.cells] for row in rows]
    widths = [
        max([text_width(label)] + [text_width(line[index]) for line in cells])
        for index, label in enumerate(labels)
    ]

    def joined(texts):
        return "  ".join(
            text if index == len(texts) - 1 else pad(text, widths[index])
            for index, text in enumerate(texts)
        )

    lines = [joined(labels)]
    for row, line in zip(rows, cells, strict=True):
        lines.append(joined(line))
        for note in row.notes:
            label = f"{note.label}: " if note.label else ""
            lines.append(f"  {label}{sanitize(note.text)}")
    return lines


def card(style, title, fields, note=""):
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


def callout(style, tone, title, lines=()):
    """A notice set off by a bar in its tone's color: no frame around it."""
    title = sanitize(title)
    lines = [sanitize(line) for line in lines]
    if not style.styled:
        return [title] + [f"  {line}" for line in lines]
    bar = style.paint(TONES[tone], GLYPH["bar"])
    room = style.width - 2 * GUTTER - 2
    body = [style.paint(STRONG, truncate(title, room))]
    for line in lines:
        body += wrap(line, room)
    return [_gutter(f"{bar} {line}") for line in body]


def worst(tones):
    """The most severe tone, for a summary's label."""
    return max(tones, key=SEVERITY.index, default="ok")


def summary(style, counts, hint="", tone="ok"):
    """Close a report: the count of each state and what to do next.

    counts holds (tone, count, word) in display order. Styled output draws a
    rule across the content, then the markers and counts with the hint on
    the right margin; plain output is one leveled sentence, whose level
    `tone` raises when the outcome is worse than the counts say.
    """
    counts = [entry for entry in counts if entry[1]]
    hint = sanitize(hint)
    if not style.styled:
        words = ", ".join(f"{count} {word}" for _, count, word in counts)
        sentence = "; ".join(part for part in (words, hint) if part)
        label = LABELS[worst([tone, *(entry[0] for entry in counts)])]
        return [f"{label} {sentence}." if sentence else label.rstrip()]
    room = style.width - 2 * GUTTER
    items = [
        f"{style.marker(tone)} {count} {word}" for tone, count, word in counts
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
