"""Tests for: `vscode_fs` -- canonicalize_path and containment helpers."""

from __future__ import annotations

import _support  # noqa: F401

import tempfile
import unittest
from pathlib import Path

from vscode_fs import (
    canonicalize_path,
    canonicalize_path_location,
    is_path_location_within_directory,
    is_within_directory,
)


class CanonicalizePathTests(unittest.TestCase):
    """Verify that path canonicalisation collapses redundant segments."""

    def test_canonicalize_collapses_parent_segments(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "child/../grandchild"
            self.assertEqual(
                canonicalize_path(candidate), canonicalize_path(root / "grandchild")
            )


class IsWithinDirectoryTests(unittest.TestCase):
    """Verify containment checks for nested and sibling paths."""

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


class PathLocationContainmentTests(unittest.TestCase):
    """Verify containment checks that preserve the final symlink path location."""

    def test_canonicalize_path_location_keeps_final_component_unresolved(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            # Resolved because canonicalize_path_location canonicalizes the
            # parent (macOS tempdirs live behind the /var symlink).
            root = Path(temp_dir).resolve()
            managed_root = root / "managed"
            outside_root = root / "outside"
            managed_root.mkdir()
            outside_root.mkdir()
            link_path = managed_root / "alias.ext"
            link_path.symlink_to(outside_root / "target.ext")

            self.assertEqual(
                canonicalize_path_location(link_path), managed_root / "alias.ext"
            )

    def test_is_path_location_within_directory_accepts_symlink_inside_root(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            managed_root = root / "managed"
            outside_root = root / "outside"
            managed_root.mkdir()
            outside_root.mkdir()
            link_path = managed_root / "alias.ext"
            link_path.symlink_to(outside_root / "target.ext")

            self.assertTrue(is_path_location_within_directory(link_path, managed_root))

    def test_is_path_location_within_directory_rejects_parent_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            managed_root = root / "managed"
            managed_root.mkdir()

            self.assertFalse(
                is_path_location_within_directory(
                    managed_root / "../escape.ext",
                    managed_root,
                )
            )


if __name__ == "__main__":
    unittest.main()
