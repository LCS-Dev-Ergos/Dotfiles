"""Tests for: `vscode_backups` -- shared backup-root retention."""

from __future__ import annotations

import _support  # noqa: F401

import tempfile
import unittest
from pathlib import Path

from vscode_backups import default_backup_root, prune_backup_directories


class BackupRetentionTests(unittest.TestCase):
    """Verify pruning of old top-level backup directories."""

    def test_default_backup_root_uses_shared_home_location(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            # Resolved because default_backup_root canonicalizes (macOS
            # tempdirs live behind the /var -> /private/var symlink).
            home = Path(temp_dir).resolve()
            self.assertEqual(
                default_backup_root(home),
                home / ".local/share/vscode-sync-backups",
            )

    def test_prune_backup_directories_retains_each_subtype_independently(self) -> None:
        """Frequent subtypes must not evict rarer ones such as quarantine data."""

        with tempfile.TemporaryDirectory() as temp_dir:
            backup_root = Path(temp_dir) / "backups"
            backup_root.mkdir()
            quarantine = (
                backup_root / "20260101_090000_100_extension-cleaner-quarantine"
            )
            quarantine.mkdir()
            for index in range(1, 8):
                (backup_root / f"20260322_10150{index}_0000_sync-items").mkdir()

            removed = prune_backup_directories(backup_root, keep_count=5)

            self.assertEqual(len(removed), 2)
            self.assertTrue(quarantine.is_dir())
            self.assertEqual(
                sum(
                    1
                    for entry in backup_root.iterdir()
                    if entry.name.endswith("_sync-items")
                ),
                5,
            )

    def test_prune_backup_directories_keeps_only_newest_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            backup_root = Path(temp_dir) / "backups"
            backup_root.mkdir()
            for index in range(1, 8):
                (backup_root / f"20260322_10150{index}_0000_profile-state").mkdir()

            removed = prune_backup_directories(backup_root, keep_count=5)

            self.assertEqual(len(removed), 2)
            self.assertEqual(
                sorted(path.name for path in backup_root.iterdir() if path.is_dir()),
                [
                    "20260322_101503_0000_profile-state",
                    "20260322_101504_0000_profile-state",
                    "20260322_101505_0000_profile-state",
                    "20260322_101506_0000_profile-state",
                    "20260322_101507_0000_profile-state",
                ],
            )


if __name__ == "__main__":
    unittest.main()
