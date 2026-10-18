"""How results reach the terminal: leveled lines, cards and tables.

Every command prints through these, in the style the shell tools share;
file names from the vault are untrusted and escaped on the way.
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


def name(path: Path, style: ui.Style) -> str:
    """A path as the user should read it: ``~`` for home when styled."""
    return ui.short_path(str(path), style)
