"""Watermark detection and removal."""

import json
import unittest

import pikepdf

from core import watermarks as wm
from tests.support import WATERMARK, Folder


class TextTests(unittest.TestCase):
    """Text extraction and masking for clustering."""

    def test_text_operators_join_and_skip_kerning(self) -> None:
        """Tj and TJ join; TJ's numbers are spacing, not text."""
        operations = [(["Hello  "], b"Tj"), ([["world", -10, "!"]], b"TJ")]
        self.assertEqual(wm.text_of(operations), "Hello world!")

    def test_masking_lets_variants_cluster(self) -> None:
        """Ids and long words are masked; short words stay."""
        self.assertEqual(
            wm.mask("Invoice 12345 for Alice"), "<word> <id> for <word>"
        )
        self.assertEqual(wm.normalize(" a\n  b "), "a b")


class GeometryTests(unittest.TestCase):
    """Boxes and matrices."""

    def test_boxes(self) -> None:
        """Corners in any order; a translation moves every corner."""
        self.assertEqual(wm.box_of([10, 20, 0, 5]), wm.Box(0, 5, 10, 20))
        moved = wm.transform(wm.Box(0, 0, 10, 20), (1, 0, 0, 1, 5, 7), None)
        self.assertEqual(moved, wm.Box(5, 7, 15, 27))

    def test_dominant_ignores_unknown(self) -> None:
        """Unknown positions do not count."""
        self.assertEqual(wm.dominant(["a", "a", "b", "unknown"]), 2 / 3)


class BlockTests(unittest.TestCase):
    """Finding blocks and what removing them takes."""

    def test_a_wrapped_draw_is_one_block(self) -> None:
        """q Do Q is a block, and its Do is not counted again."""
        operations = [([], b"q"), (["/WM"], b"Do"), ([], b"Q")]
        ranges, covered = wm.wrapped_draws(operations)
        self.assertEqual((ranges, covered), ([(0, 3)], {1}))
        self.assertEqual(wm.draws(operations, covered), [])

    def test_unwrapped_blocks_keep_their_state(self) -> None:
        """A colour or font set by an unwrapped block outlives it."""
        operations = [
            ([], b"BT"),
            (["/F1", 12], b"Tf"),
            ([0.5], b"g"),
            (["Stamp"], b"Tj"),
            ([], b"ET"),
            (["/F1", 12], b"Tf"),
        ]
        cut = wm.removable(operations, 0, 5, last=False)
        self.assertEqual(cut, {0, 3, 4})
        wrapped = [([], b"q"), *operations[:5], ([], b"Q")]
        self.assertEqual(
            wm.removable(wrapped, 0, 7, last=False), set(range(7))
        )

    def test_a_whole_stream_goes_only_when_last(self) -> None:
        """An earlier stream may set state for the ones after it."""
        operations = [([1, 0, 0, 1, 5, 5], b"cm"), (["/X"], b"Do")]
        self.assertEqual(wm.removable(operations, 0, 2, last=True), {0, 1})
        self.assertEqual(wm.removable(operations, 0, 2, last=False), {1})


class DocumentTests(unittest.TestCase):
    """Whole documents, through the command."""

    def setUp(self) -> None:
        """A folder for samples."""
        self.folder = Folder(self)

    def test_a_stamp_is_found_and_removed(self) -> None:
        """The stamp goes from every page; the body stays."""
        book = self.folder.pdf("book.pdf", 4, stamp=WATERMARK)
        report = self.folder.root / "report.json"
        status, out, _ = self.folder.run(
            "watermarks", str(book), "--report", str(report)
        )
        self.assertEqual(status, 0)
        self.assertIn("removed 4 overlays · on 4 pages", out)
        texts = self.folder.texts(self.folder.root / "book_cleaned.pdf")
        for number, text in enumerate(texts, start=1):
            self.assertNotIn("CONFIDENTIAL", text)
            self.assertIn(f"Body of page {number}", text)
            self.assertIn("540 700 l", text)
        payload = json.loads(report.read_text())
        chosen = [
            c for c in payload["candidates"] if c["decision"] == "remove"
        ]
        self.assertEqual(len(chosen), 1)
        self.assertEqual(chosen[0]["pages"], [1, 2, 3, 4])
        self.assertEqual(payload["applied"]["removed"], 4)
        status, _, err = self.folder.run(
            "watermarks", str(book), "-n", "--report", str(report)
        )
        self.assertEqual(status, 1)
        self.assertIn("--force replaces it", err)

    def test_a_dry_run_writes_no_pdf(self) -> None:
        """Only the analysis is shown."""
        book = self.folder.pdf("book.pdf", 3, stamp=WATERMARK)
        status, out, _ = self.folder.run("watermarks", str(book), "-n")
        self.assertEqual(status, 0)
        self.assertIn("1 of", out)
        self.assertIn("Dry run", out)
        self.assertFalse((self.folder.root / "book_cleaned.pdf").exists())

    def test_ordinary_pages_are_left_alone(self) -> None:
        """Repeated body text without a watermark cue is kept."""
        book = self.folder.pdf("book.pdf", 4)
        status, out, _ = self.folder.run("watermarks", str(book))
        self.assertEqual(status, 0)
        self.assertIn("Nothing certain enough to remove", out)
        self.assertFalse((self.folder.root / "book_cleaned.pdf").exists())

    def test_named_text_tips_the_balance(self) -> None:
        """A plain footer is kept until the user names it."""
        footer = b"BT /F1 8 Tf 72 30 Td (Purchased by Ada Lovelace) Tj ET"
        book = self.folder.pdf("book.pdf", 4, stamp=footer)
        status, out, _ = self.folder.run("watermarks", str(book), "-n")
        self.assertIn("0 of", out)
        status, out, _ = self.folder.run(
            "watermarks", str(book), "--match-text", "purchased by"
        )
        self.assertEqual(status, 0)
        texts = self.folder.texts(self.folder.root / "book_cleaned.pdf")
        self.assertTrue(all("Purchased" not in text for text in texts))

    def test_owner_restrictions_survive(self) -> None:
        """The cleaned copy keeps the owner's restrictions."""
        book = self.folder.pdf("book.pdf", 3, stamp=WATERMARK, owner="boss")
        self.folder.run("watermarks", str(book))
        with pikepdf.open(self.folder.root / "book_cleaned.pdf") as pdf:
            self.assertTrue(pdf.is_encrypted)


if __name__ == "__main__":
    unittest.main()
