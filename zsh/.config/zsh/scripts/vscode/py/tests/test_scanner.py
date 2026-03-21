"""Tests for: `vscode_scanner` -- folder-name parsing and root scanning."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from vscode_models import VscodeEdition
from vscode_scanner import parse_extension_folder_name, scan_extension_root


class ParseExtensionFolderNameTests(unittest.TestCase):
    """Verify that versioned extension folder names are decomposed correctly."""

    def test_parses_versioned_extension_name(self) -> None:
        parsed = parse_extension_folder_name("github.copilot-chat-0.43.2026032001")
        self.assertEqual(parsed.extension_id, "github.copilot-chat")
        self.assertEqual(parsed.core_name, "github.copilot-chat")
        self.assertEqual(parsed.version, "0.43.2026032001")

    def test_preserves_platform_variant_in_core_name(self) -> None:
        parsed = parse_extension_folder_name("redhat.java-1.54.2026032008-darwin-arm64")
        self.assertEqual(parsed.extension_id, "redhat.java")
        self.assertEqual(parsed.core_name, "redhat.java-darwin-arm64")
        self.assertEqual(parsed.version, "1.54.2026032008")


class ScanExtensionRootTests(unittest.TestCase):
    """Verify that scanning detects real dirs, valid symlinks, and broken symlinks."""

    def test_scans_real_and_symlinked_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            base = Path(temp_dir)
            root = base / "extensions"
            root.mkdir()

            real_dir = root / "ms-python.python-2026.5.0"
            real_dir.mkdir()

            symlink_target = base / "shared-target"
            symlink_target.mkdir()
            symlink_entry = root / "ms-toolsai.jupyter-2026.4.0"
            symlink_entry.symlink_to(symlink_target)

            broken_entry = root / "redhat.java-1.54.2026032008-darwin-arm64"
            broken_entry.symlink_to(root / "missing-target")

            (root / "extensions.json").write_text("[]", encoding="utf-8")

            installs = scan_extension_root(root, edition=VscodeEdition.STABLE)

            self.assertEqual(
                [install.folder_name for install in installs],
                [
                    "ms-python.python-2026.5.0",
                    "ms-toolsai.jupyter-2026.4.0",
                    "redhat.java-1.54.2026032008-darwin-arm64",
                ],
            )

            self.assertFalse(installs[0].is_symlink)
            self.assertTrue(installs[1].is_symlink)
            self.assertEqual(installs[1].extension_id, "ms-toolsai.jupyter")
            self.assertTrue(installs[1].target_exists)
            self.assertFalse(installs[2].target_exists)
            self.assertEqual(installs[2].core_name, "redhat.java-darwin-arm64")


if __name__ == "__main__":
    unittest.main()
