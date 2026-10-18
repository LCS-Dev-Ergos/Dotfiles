"""How results reach the terminal: leveled lines, cards and tables.

Every command prints through these, in the style the shell tools share;
file names and document text are untrusted and escaped on the way.
"""

import sys
from pathlib import Path

import terminal_style as ui

_LOG = {
    "info": ("[INFO]  ", "info", ui.ACCENT),
    "ok": ("[OK]    ", "done", ui.TONES["ok"]),
    "warn": ("[WARN]  ", "pending", ui.TONES["warn"]),
    "error": ("[ERROR] ", "error", ui.TONES["error"]),
}


def log(style: ui.Style, level: str, text: str) -> str:
    """One leveled line: ``[OK]    text`` plain, a colored mark styled."""
    label, glyph, color = _LOG[level]
    text = ui.sanitize(text)
    if not style.styled:
        return f"{label}{text}"
    return f"{' ' * ui.GUTTER}{style.paint(color, ui.GLYPH[glyph])} {text}"


def say(style: ui.Style, level: str, text: str) -> None:
    """Print one leveled line; warnings and errors go to standard error."""
    stream = sys.stderr if level in ("warn", "error") else sys.stdout
    print(log(style, level, text), file=stream)


def show(lines: list[str]) -> None:
    """Print drawn lines."""
    print("\n".join(lines))


def human(size: int) -> str:
    """A byte count in the largest unit that keeps it above 1."""
    if size < 1024:
        return f"{size} B"
    value = size / 1024
    for unit in ("KB", "MB"):
        if value < 1024:
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"


def change(before: int, after: int) -> str:
    """``12.0 MB → 4.0 MB (−67%)``."""
    if not before:
        return f"{human(before)} → {human(after)}"
    percent = round((after - before) * 100 / before)
    sign = "−" if percent < 0 else "+"
    return f"{human(before)} → {human(after)} ({sign}{abs(percent)}%)"


def plural(count: int, noun: str, many: str = "") -> str:
    """``1 page`` or ``n pages``."""
    return f"{count} {noun if count == 1 else many or noun + 's'}"


def name(path: Path, style: ui.Style) -> str:
    """A path as the user should read it: ``~`` for home when styled."""
    return ui.short_path(str(path), style)
