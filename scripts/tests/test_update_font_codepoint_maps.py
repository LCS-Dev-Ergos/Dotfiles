#!/usr/bin/env python3
"""Offline tests for the font code point map updater (scripts/updates).

Manifests, Unicode tables and target files are temporary fixtures; nothing
here runs nix or fc-query.
"""

import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "update_font_codepoint_maps",
    ROOT / "scripts/updates/update-font-codepoint-maps.py",
)
assert spec and spec.loader
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)

MANIFEST = """
[[map]]
name = "demo"
family = "Demo Mono"
overlay = { package = "demo-font", files = "share/fonts/*.ttf" }
primary = { package = "nerd-fonts.demo", files = "share/fonts/Demo-Regular.ttf" }
prefer = ["U+2200-U+22FF", "U+00B9"]
outputs = [
  { path = "out/demo.conf", format = "kitty" },
  { path = "out/demo-ghostty.conf", format = "ghostty" },
]
"""


class TempRepo(unittest.TestCase):
    """Provides a temporary repository root for each test."""

    def setUp(self):
        """Create the temporary root."""
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        """Remove the temporary root."""
        self.temp.cleanup()

    def manifest(self, text):
        """Write a manifest into the root and return its path."""
        path = self.root / "maps.toml"
        path.write_text(text, encoding="utf-8")
        return path


class ManifestTest(TempRepo):
    """Manifest parsing and validation."""

    def test_valid_manifest(self):
        """A well-formed manifest yields resolved, typed declarations."""
        (demo,) = updater.load_manifest(self.manifest(MANIFEST), self.root)
        self.assertEqual(demo.family, "Demo Mono")
        self.assertEqual(demo.prefer, ((0x2200, 0x22FF), (0xB9, 0xB9)))
        self.assertEqual(
            [(o.path, o.format) for o in demo.outputs],
            [
                (self.root / "out/demo.conf", "kitty"),
                (self.root / "out/demo-ghostty.conf", "ghostty"),
            ],
        )

    def test_rejections(self):
        """Each malformed or unsafe manifest is rejected."""
        cases = {
            "unknown key": MANIFEST.replace(
                'name = "demo"', 'name = "demo"\nextra = 1'
            ),
            "path escape": MANIFEST.replace(
                '"out/demo.conf"', '"../demo.conf"'
            ),
            "absolute path": MANIFEST.replace(
                '"out/demo.conf"', '"/tmp/demo.conf"'
            ),
            "family injection": MANIFEST.replace('"Demo Mono"', '"Demo,Mono"'),
            "flake reference": MANIFEST.replace(
                '"demo-font"', '"github:x/y#z"'
            ),
            "glob escape": MANIFEST.replace(
                '"share/fonts/*.ttf"', '"../*.ttf"'
            ),
            "reversed range": MANIFEST.replace('"U+00B9"', '"U+00B9-U+00B0"'),
            "beyond Unicode": MANIFEST.replace('"U+00B9"', '"U+110000"'),
            "unknown format": MANIFEST.replace(
                'format = "kitty"', 'format = "wezterm"'
            ),
            "duplicate output": MANIFEST.replace(
                "demo-ghostty.conf", "demo.conf"
            ),
            "invalid TOML": MANIFEST + "[[",
        }
        for label, text in cases.items():
            with self.subTest(label), self.assertRaises(updater.UpdateError):
                updater.load_manifest(self.manifest(text), self.root)

    def test_main_reports_manifest_errors(self):
        """main() reports a manifest error with status 2."""
        path = self.manifest("[[map]]\n")
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            status = updater.main(["--check", "--manifest", str(path)])
        self.assertEqual(status, 2)
        self.assertIn("missing", stderr.getvalue())


class SelectionTest(unittest.TestCase):
    """Code point selection, range compaction and rendering."""

    def unicode(self, assigned, unmappable=(), emoji=()):
        """Build a UnicodeData fixture."""
        return updater.UnicodeData(
            frozenset(assigned),
            frozenset(unmappable),
            frozenset(emoji),
            "ucd-test",
        )

    def test_policy(self):
        """Only eligible overlay code points are selected."""
        overlay = {
            0x41,
            0x85,
            0x2202,
            0x2297,
            0x16A0,
            0x1D41E,
            0x1F680,
            0xE0B0,
            0x378,
        }
        primary = {0x41, 0x2202}
        unicode = self.unicode(
            assigned=overlay - {0x378},
            unmappable={0x85, 0xE0B0},
            emoji={0x1F680},
        )
        self.assertEqual(
            updater.select(overlay, primary, unicode, ((0x2200, 0x22FF),)),
            # ∂ is preferred, A is not; ᚠ and 𝐞 fill gaps. C1 controls, private
            # use, emoji and the unassigned U+0378 are never mapped.
            {0x2202, 0x2297, 0x16A0, 0x1D41E},
        )

    def test_compact_bridges_only_unassigned_gaps(self):
        """Ranges merge across unassigned code points only."""
        assigned = {1, 2, 3, 5, 6, 10, 20}
        self.assertEqual(
            updater.compact({1, 2, 3, 6, 10, 20}, assigned),
            # 5 is assigned and not selected; 7..9 and 11..19 are unassigned.
            [(1, 3), (6, 20)],
        )

    def test_render_formats(self):
        """Both formats render the marker and their own syntax."""
        source = updater.FontSource("demo-font", "*.ttf")
        codepoint_map = updater.CodepointMap(
            "demo", "Demo Mono", source, source, (), ()
        )
        ranges = [(0xB9, 0xB9), (0x1D400, 0x1D7FF)]
        kitty = updater.render("kitty", codepoint_map, ranges, ["a", "b"])
        ghostty = updater.render("ghostty", codepoint_map, ranges, ["a", "b"])
        self.assertTrue(kitty.startswith(updater.MARKER))
        self.assertEqual(
            kitty.splitlines()[-1],
            "symbol_map U+00B9,U+1D400-U+1D7FF Demo Mono",
        )
        self.assertEqual(
            ghostty.splitlines()[-1],
            "font-codepoint-map = U+00B9,U+1D400-U+1D7FF=Demo Mono",
        )
        with self.assertRaises(updater.UpdateError):
            updater.render("kitty", codepoint_map, [], ["a"])


class ParseTest(TempRepo):
    """Parsers for fc-query output and UCD files."""

    def test_charset(self):
        """fc-query charsets parse, and malformed ones are rejected."""
        self.assertEqual(
            updater.parse_charset("20-22 1d41e\n", "font"),
            {0x20, 0x21, 0x22, 0x1D41E},
        )
        for text in ("", "zz", "22-20"):
            with self.subTest(text), self.assertRaises(updater.UpdateError):
                updater.parse_charset(text, "font")

    def test_unicode_data_ranges_and_categories(self):
        """First/Last ranges expand; Cc/Cs/Co are unmappable."""
        fields = ";" * 12  # the 12 fields after the general category
        path = self.root / "UnicodeData.txt"
        path.write_text(
            f"0041;LATIN CAPITAL LETTER A;Lu{fields}\n"
            f"0085;<control>;Cc{fields}\n"
            f"F0000;<Plane 15 Private Use, First>;Co{fields}\n"
            f"FFFFD;<Plane 15 Private Use, Last>;Co{fields}\n"
            f"100000;<Plane 16 Private Use, First>;Co{fields}\n"
            f"10FFFD;<Plane 16 Private Use, Last>;Co{fields}\n",
            encoding="utf-8",
        )
        assigned, unmappable = updater.parse_unicode_data(path)
        self.assertEqual(len(assigned), 2 + 2 * 0xFFFE)
        self.assertEqual(assigned - unmappable, {0x41})
        path.write_text(f"0041;A;Lu{fields}\n", encoding="utf-8")
        with self.assertRaises(updater.UpdateError):
            updater.parse_unicode_data(path)

    def test_property(self):
        """Only code points with the requested property are returned."""
        path = self.root / "emoji-data.txt"
        path.write_text(
            "# comment\n"
            "231A..231B    ; Emoji_Presentation # ⌚\n"
            "2194          ; Emoji              # ↔\n",
            encoding="utf-8",
        )
        self.assertEqual(
            updater.parse_property(path, "Emoji_Presentation"),
            {0x231A, 0x231B},
        )


class OutputTest(TempRepo):
    """Safety of reading and writing generated files."""

    def test_refuses_foreign_files_and_symlinks(self):
        """Hand-written files and symlinks are never replaced."""
        foreign = self.root / "foreign.conf"
        foreign.write_text("font_size 12\n", encoding="utf-8")
        link = self.root / "link.conf"
        link.symlink_to(foreign)
        for path in (foreign, link):
            with (
                self.subTest(path.name),
                self.assertRaises(updater.UpdateError),
            ):
                updater.current_text(path)
        self.assertIsNone(updater.current_text(self.root / "absent.conf"))

    def test_write_atomic(self):
        """Atomic writes leave the target only, with mode 0644."""
        target = self.root / "new/demo.conf"
        text = f"{updater.MARKER} (map demo); do not edit.\n"
        updater.write_atomic(target, text)
        self.assertEqual(updater.current_text(target), text)
        self.assertEqual(os.listdir(target.parent), ["demo.conf"])
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    unittest.main(verbosity=1)
