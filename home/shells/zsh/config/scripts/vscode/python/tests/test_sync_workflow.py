"""Tests for: `vscode_sync_workflow` -- top-level status, setup, and remove."""

import _support  # noqa: F401

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from vscode_config import VscodePathsConfig
from vscode_profiles import ProfileManifestSafetyError
from vscode_sync_workflow import (
    apply_sync_remove,
    apply_sync_setup,
    collect_sync_status,
)


class SyncWorkflowTests(unittest.TestCase):
    """Verify the full sync lifecycle for non-extension items (settings, keybindings, etc.)."""

    def test_collect_sync_status_reports_synced_items(self):
        """All four managed items should be reported as SYNCED when symlinks are correct."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir).resolve(strict=False)
            config = VscodePathsConfig.from_home(home)
            stable_user = config.stable_user_dir
            insiders_user = config.insiders_user_dir
            stable_extensions = home / ".vscode/extensions"
            insiders_extensions = home / ".vscode-insiders/extensions"

            (stable_user / "snippets").mkdir(parents=True)
            stable_user.mkdir(parents=True, exist_ok=True)
            insiders_user.mkdir(parents=True, exist_ok=True)
            stable_extensions.mkdir(parents=True)
            insiders_extensions.mkdir(parents=True)

            (stable_user / "settings.json").write_text("{}", encoding="utf-8")
            (stable_user / "keybindings.json").write_text("[]", encoding="utf-8")
            (stable_user / "snippets" / "python.json").write_text(
                "{}", encoding="utf-8"
            )
            (stable_user / "mcp.json").write_text("{}", encoding="utf-8")

            (insiders_user / "settings.json").symlink_to(stable_user / "settings.json")
            (insiders_user / "keybindings.json").symlink_to(
                stable_user / "keybindings.json"
            )
            (insiders_user / "snippets").symlink_to(stable_user / "snippets")
            (insiders_user / "mcp.json").symlink_to(stable_user / "mcp.json")

            report = collect_sync_status(
                stable_extensions,
                insiders_extensions,
                home=home,
            )

            self.assertEqual(report.issues, 0)
            self.assertEqual(report.warnings, 0)
            self.assertTrue(all(item.status.value == "synced" for item in report.items))

    def test_apply_sync_setup_creates_item_symlinks(self):
        """Setup should replace existing independent Insiders files with symlinks to Stable."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir).resolve(strict=False)
            config = VscodePathsConfig.from_home(home)
            stable_user = config.stable_user_dir
            insiders_user = config.insiders_user_dir
            stable_extensions = home / ".vscode/extensions"
            insiders_extensions = home / ".vscode-insiders/extensions"

            (stable_user / "snippets").mkdir(parents=True)
            insiders_user.mkdir(parents=True, exist_ok=True)
            stable_extensions.mkdir(parents=True)
            insiders_extensions.mkdir(parents=True)

            (stable_user / "settings.json").write_text("{}", encoding="utf-8")
            (stable_user / "keybindings.json").write_text("[]", encoding="utf-8")
            (stable_user / "snippets" / "python.json").write_text(
                "{}", encoding="utf-8"
            )
            (stable_user / "mcp.json").write_text("{}", encoding="utf-8")

            (insiders_user / "settings.json").write_text(
                '{"old":true}', encoding="utf-8"
            )

            report = apply_sync_setup(stable_extensions, insiders_extensions, home=home)

            self.assertEqual(report.failed_count, 0)
            self.assertEqual(report.extension_report.linked_count, 0)
            self.assertTrue((insiders_user / "settings.json").is_symlink())
            self.assertEqual(
                (insiders_user / "settings.json").resolve(strict=False),
                (stable_user / "settings.json").resolve(strict=False),
            )
            self.assertTrue((insiders_user / "keybindings.json").is_symlink())
            self.assertTrue((insiders_user / "snippets").is_symlink())
            self.assertTrue((insiders_user / "mcp.json").is_symlink())

    def test_apply_sync_remove_restores_independent_copies(self):
        """Remove should copy Stable source content back to Insiders, replacing symlinks."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir).resolve(strict=False)
            config = VscodePathsConfig.from_home(home)
            stable_user = config.stable_user_dir
            insiders_user = config.insiders_user_dir
            stable_extensions = home / ".vscode/extensions"
            insiders_extensions = home / ".vscode-insiders/extensions"

            (stable_user / "snippets").mkdir(parents=True)
            insiders_user.mkdir(parents=True, exist_ok=True)
            stable_extensions.mkdir(parents=True)
            insiders_extensions.mkdir(parents=True)

            (stable_user / "settings.json").write_text("{}", encoding="utf-8")
            (stable_user / "keybindings.json").write_text("[]", encoding="utf-8")
            (stable_user / "snippets" / "python.json").write_text(
                "{}", encoding="utf-8"
            )
            (stable_user / "mcp.json").write_text("{}", encoding="utf-8")

            apply_sync_setup(stable_extensions, insiders_extensions, home=home)
            report = apply_sync_remove(
                stable_extensions, insiders_extensions, home=home
            )

            self.assertEqual(report.failed_count, 0)
            self.assertEqual(report.extension_report.restored_entry_copy_count, 0)
            self.assertFalse((insiders_user / "settings.json").is_symlink())
            self.assertEqual(
                (insiders_user / "settings.json").read_text(encoding="utf-8"),
                "{}",
            )
            self.assertFalse((insiders_user / "snippets").is_symlink())
            self.assertTrue((insiders_user / "snippets" / "python.json").is_file())

    def test_apply_sync_setup_keeps_original_target_when_backup_fails(self):
        """A failed pre-replacement backup must leave the original target untouched."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir).resolve(strict=False)
            config = VscodePathsConfig.from_home(home)
            stable_user = config.stable_user_dir
            insiders_user = config.insiders_user_dir
            stable_extensions = home / ".vscode/extensions"
            insiders_extensions = home / ".vscode-insiders/extensions"

            stable_user.mkdir(parents=True, exist_ok=True)
            insiders_user.mkdir(parents=True, exist_ok=True)
            stable_extensions.mkdir(parents=True)
            insiders_extensions.mkdir(parents=True)

            (stable_user / "settings.json").write_text("{}", encoding="utf-8")
            original_content = '{"precious": true}'
            (insiders_user / "settings.json").write_text(
                original_content, encoding="utf-8"
            )

            with patch(
                "vscode_sync_workflow._backup_target_if_needed",
                side_effect=OSError("disk full"),
            ):
                report = apply_sync_setup(
                    stable_extensions, insiders_extensions, home=home
                )

            self.assertEqual(report.failed_count, 1)
            target = insiders_user / "settings.json"
            self.assertTrue(target.exists())
            self.assertFalse(target.is_symlink())
            self.assertEqual(target.read_text(encoding="utf-8"), original_content)

    def test_apply_sync_setup_rolls_back_items_when_extension_setup_aborts(self):
        """Item rewires should be restored if the extension phase aborts afterward."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir).resolve(strict=False)
            config = VscodePathsConfig.from_home(home)
            stable_user = config.stable_user_dir
            insiders_user = config.insiders_user_dir
            stable_extensions = home / ".vscode/extensions"
            insiders_extensions = home / ".vscode-insiders/extensions"

            stable_user.mkdir(parents=True, exist_ok=True)
            insiders_user.mkdir(parents=True, exist_ok=True)
            stable_extensions.mkdir(parents=True)
            insiders_extensions.mkdir(parents=True)

            (stable_user / "settings.json").write_text(
                '{"stable":true}', encoding="utf-8"
            )
            (stable_user / "keybindings.json").write_text("[]", encoding="utf-8")
            (stable_user / "snippets").mkdir()
            (stable_user / "snippets" / "python.json").write_text(
                "{}", encoding="utf-8"
            )
            (stable_user / "mcp.json").write_text("{}", encoding="utf-8")
            (insiders_user / "settings.json").write_text(
                '{"independent":true}', encoding="utf-8"
            )

            with patch(
                "vscode_sync_workflow.apply_extension_setup",
                side_effect=ProfileManifestSafetyError("forced test failure"),
            ):
                with self.assertRaises(ProfileManifestSafetyError):
                    apply_sync_setup(stable_extensions, insiders_extensions, home=home)

            self.assertFalse((insiders_user / "settings.json").is_symlink())
            self.assertEqual(
                (insiders_user / "settings.json").read_text(encoding="utf-8"),
                '{"independent":true}',
            )


if __name__ == "__main__":
    unittest.main()
