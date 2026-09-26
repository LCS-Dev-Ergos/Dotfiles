"""Tests for: `remove_watermarks` -- text/geometry helpers and overlay clustering."""

from __future__ import annotations

import unittest

from _support import MODULE_ROOT  # noqa: F401
from remove_watermarks import (
    BBox,
    detect_do_ranges,
    detect_small_wrapped_do_ranges,
    dominant_share,
    extract_text_from_operations,
    mask_dynamic_text,
    normalize_whitespace,
    parse_bbox,
    transform_bbox,
)


class TextNormalizationTests(unittest.TestCase):
    """Verify PDF text-operator extraction and token masking for clustering."""

    def test_extracts_and_normalizes_pdf_text_operations(self) -> None:
        """Tj and TJ operands join into one string; TJ's numeric kerning
        adjustments are skipped, not rendered as text."""
        operations = [(["Hello  "], b"Tj"), ([["world", -10, "!"]], b"TJ")]
        self.assertEqual(extract_text_from_operations(operations), "Hello world!")

    def test_masks_dynamic_tokens_for_clustering(self) -> None:
        """Tokens containing a digit collapse to <id> and words longer than
        three letters collapse to <word>, so overlays that differ only by
        invoice number or name still cluster together; short words like "for"
        pass through unchanged."""
        self.assertEqual(
            mask_dynamic_text("Invoice 12345 for Alice"), "<word> <id> for <word>"
        )
        self.assertEqual(normalize_whitespace(" a\n  b "), "a b")


class GeometryTests(unittest.TestCase):
    """Verify bounding-box parsing and affine-matrix transformation."""

    def test_parses_reversed_bbox(self) -> None:
        """A /BBox array with min/max coordinates swapped still normalizes to
        (x0, y0, x1, y1) with x0 <= x1 and y0 <= y1."""
        self.assertEqual(parse_bbox([10, 20, 0, 5]), BBox(0, 5, 10, 20))

    def test_transforms_bbox_with_translation(self) -> None:
        """An identity-scale outer matrix with a translation offsets every
        corner of the box by the same amount."""
        box = transform_bbox(BBox(0, 0, 10, 20), (1, 0, 0, 1, 5, 7), None)
        self.assertEqual(box, BBox(5, 7, 15, 27))


class OverlayClusteringTests(unittest.TestCase):
    """Verify repeated small-overlay detection used to identify watermark clusters."""

    def test_dominant_share_ignores_unknown(self) -> None:
        """ "unknown" entries are excluded from the denominator, so a 2-of-3
        known majority reports 2/3, not 2/4."""
        self.assertEqual(dominant_share(["same", "same", "other", "unknown"]), 2 / 3)

    def test_detects_small_wrapped_xobject_draw(self) -> None:
        """A single `Do` draw wrapped in its own q/Q save-restore pair is
        reported as one self-contained overlay range and its Do index is
        marked protected, so the general Do-range scan skips it."""
        operations = [([], b"q"), (["/WM"], b"Do"), ([], b"Q")]
        ranges, protected = detect_small_wrapped_do_ranges(operations)
        self.assertEqual(ranges, [(0, 3)])
        self.assertEqual(protected, {1})
        self.assertEqual(detect_do_ranges(operations, protected), [])


if __name__ == "__main__":
    unittest.main()
