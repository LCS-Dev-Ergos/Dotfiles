"""Tests for: `vscode_versions.compare_versions`."""

from __future__ import annotations

import unittest

from vscode_versions import compare_versions


class CompareVersionsTests(unittest.TestCase):
    """Verify shell-compatible version comparison semantics."""

    def test_numeric_tokens_are_compared_numerically(self) -> None:
        self.assertEqual(compare_versions("1.10.0", "1.2.0"), 1)

    def test_text_tokens_are_compared_case_insensitively(self) -> None:
        self.assertEqual(compare_versions("1.0.0-beta", "1.0.0-alpha"), 1)

    def test_numeric_tokens_sort_after_text_tokens(self) -> None:
        self.assertEqual(compare_versions("1.0.0-1", "1.0.0-beta"), 1)

    def test_missing_versions_are_handled(self) -> None:
        self.assertEqual(compare_versions(None, "1.0.0"), -1)
        self.assertEqual(compare_versions("1.0.0", None), 1)
        self.assertEqual(compare_versions(None, None), 0)


if __name__ == "__main__":
    unittest.main()
