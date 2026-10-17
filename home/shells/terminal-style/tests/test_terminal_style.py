"""The Python style module: detection, measuring, and parity with the shell."""

import io
import os
import re
import unittest
from pathlib import Path
from unittest.mock import patch

import terminal_style as ui

SHELL = (Path(ui.__file__).with_name("terminal-style.zsh")).read_text(
    encoding="utf-8"
)


def shell_table(name: str) -> dict[str, str]:
    """One associative array of terminal-style.zsh, as a dictionary."""
    block = re.search(rf"typeset -gA {name}=\(\n(.*?)\n\)", SHELL, re.S)
    assert block is not None, name
    return dict(re.findall(r"^\s+(\w+)\s+'([^']*)'\s*$", block[1], re.M))


class Terminal(io.StringIO):
    """A captured stream that reports itself as a terminal."""

    def isatty(self) -> bool:
        """Always a terminal."""
        return True


class StyleTests(unittest.TestCase):
    """When output is styled, and how wide it is."""

    def test_only_a_color_terminal_is_styled(self) -> None:
        """NO_COLOR, a dumb or unset TERM and a pipe all draw plain."""
        terminal = Terminal()
        cases: tuple[tuple[io.StringIO, dict[str, str], bool], ...] = (
            (terminal, {"TERM": "xterm-256color"}, True),
            (terminal, {"TERM": "xterm-256color", "NO_COLOR": "1"}, False),
            (terminal, {"TERM": "dumb"}, False),
            (terminal, {}, False),
            (io.StringIO(), {"TERM": "xterm-256color"}, False),
        )
        for stream, environ, styled in cases:
            with self.subTest(environ=environ, tty=stream is terminal):
                self.assertIs(ui.Style.detect(stream, environ).styled, styled)

    def test_width_follows_columns_within_bounds(self) -> None:
        """The width follows COLUMNS between 40 and 120."""
        for columns, width in (("30", 40), ("65", 65), ("300", 120)):
            with (
                self.subTest(columns=columns),
                patch.dict(os.environ, {"COLUMNS": columns}),
            ):
                self.assertEqual(
                    ui.Style.detect(io.StringIO(), {}).width, width
                )


class MeasureTests(unittest.TestCase):
    """Display widths, shortening and escaping."""

    def test_text_width_counts_cells(self) -> None:
        """Color takes no cell, a wide character two."""
        self.assertEqual(ui.text_width("\033[1;32m●\033[0m ok"), 4)
        self.assertEqual(ui.text_width("界"), 2)
        self.assertEqual(ui.truncate("界界界", 5), "界界…")

    def test_paths_lose_whole_middle_components(self) -> None:
        """A path keeps its root and its end; other text loses its end."""
        path = "/home/user/.pyenv/versions/3.14.8/bin/python"
        self.assertEqual(ui.truncate(path, 20), "/home/…/bin/python")
        self.assertEqual(ui.truncate(path, 28), "/home/…/3.14.8/bin/python")
        self.assertEqual(ui.truncate("~/a/b/c/d/file", 10), "~/…/d/file")
        self.assertEqual(
            ui.truncate("no slashes here at all", 10), "no slashe…"
        )

    def test_control_characters_are_escaped(self) -> None:
        """Untrusted text cannot move the cursor or recolor the terminal."""
        self.assertEqual(ui.sanitize("a\tb\x1b[2Jc"), "a\\tb\\x1b[2Jc")
        self.assertEqual(ui.sanitize_lines("one\ntwo\r"), "one\ntwo\\r")

    def test_plain_output_keeps_paths_whole(self) -> None:
        """Only styled output abbreviates HOME and store hashes."""
        path = "/home/user/.local/bin/tool"
        self.assertEqual(
            ui.short_path(path, ui.Style(False), "/home/user"), path
        )
        self.assertEqual(
            ui.short_path(path, ui.Style(True), "/home/user"),
            "~/.local/bin/tool",
        )


class ParityTests(unittest.TestCase):
    """One look across languages: the tokens are those of the shell module."""

    def test_tokens_match(self) -> None:
        """Colors and glyphs are the shell's tables."""
        self.assertEqual(shell_table("_ZSH_UI_SGR"), ui.SGR)
        self.assertEqual(shell_table("_ZSH_UI_GLYPH"), ui.GLYPH)

    def test_layout_matches(self) -> None:
        """The margin and the indent are the shell's."""
        for name, value in (("GUTTER", ui.GUTTER), ("INDENT", ui.INDENT)):
            with self.subTest(name=name):
                found = re.search(rf"typeset -gi _ZSH_UI_{name}=(\d+)", SHELL)
                assert found is not None, name
                self.assertEqual(int(found[1]), value)

    def test_state_markers_match(self) -> None:
        """The words with a marker of their own are the shell's."""
        body = re.search(
            r"_zsh_ui_status_glyph\(\) \{\n(.*?)\n\}", SHELL, re.S
        )
        assert body is not None
        found: dict[str, str] = {}
        for words, glyph in re.findall(
            r'([a-z|]+)\) REPLY="([^"$]+)" ;;', body[1]
        ):
            found.update(dict.fromkeys(words.split("|"), glyph))
        for plain in ("x", "!", "-", "*"):
            found = {k: v for k, v in found.items() if v != plain}
        self.assertEqual(found, ui.STATUS_GLYPHS)

    def test_gum_theme_matches(self) -> None:
        """Gum is themed as _zsh_ui_gum themes it."""
        body = re.search(r"_zsh_ui_gum\(\) \{\n(.*?)\n\}", SHELL, re.S)
        assert body is not None
        self.assertEqual(
            dict(re.findall(r"(GUM_\w+)=(\S+)", body[1])), ui.GUM_THEME
        )


if __name__ == "__main__":
    unittest.main()
