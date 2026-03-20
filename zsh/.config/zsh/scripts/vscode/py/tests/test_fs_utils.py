from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from _support import MODULE_ROOT

from vscode_fs import canonicalize_path, is_within_directory


class CanonicalizePathTests(unittest.TestCase):
    def test_canonicalize_collapses_parent_segments(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "child/../grandchild"
            self.assertEqual(canonicalize_path(candidate), root / "grandchild")


class IsWithinDirectoryTests(unittest.TestCase):
    def test_returns_true_for_nested_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            nested = root / "alpha/beta"
            self.assertTrue(is_within_directory(nested, root))

    def test_returns_false_for_sibling_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            parent = Path(temp_dir)
            root = parent / "root"
            other = parent / "other"
            self.assertFalse(is_within_directory(other, root))


if __name__ == "__main__":
    unittest.main()

