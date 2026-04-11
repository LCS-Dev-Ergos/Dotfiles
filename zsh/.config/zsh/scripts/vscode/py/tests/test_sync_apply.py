"""Tests for: `vscode_sync_apply` -- extension setup and removal."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from vscode_config import VscodePathsConfig
from vscode_fs import canonicalize_path
from vscode_profiles import ProfileManifestSafetyError
from vscode_sync_apply import apply_extension_remove, apply_extension_setup


class ApplyExtensionSetupTests(unittest.TestCase):
    """Verify extension symlink repair, migration, and manifest rebinding."""

    def test_migrates_unmanaged_real_dir_without_rewriting_profile_manifest(
        self,
    ) -> None:
        """An Insiders-only real directory should be moved to Stable and replaced with a symlink."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            config = VscodePathsConfig.from_home(home)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = config.insiders_profile_roots[0] / "profile-a"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)
            profile_dir.mkdir(parents=True)

            unmanaged_dir = insiders_root / "xaver.clang-format-1.9.0"
            unmanaged_dir.mkdir()
            (stable_root / "shared.ok-1.0.0").mkdir()
            (insiders_root / "shared.ok-1.0.0").symlink_to(stable_root / "shared.ok-1.0.0")

            manifest_path = profile_dir / "extensions.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "identifier": {"id": "xaver.clang-format"},
                            "version": "1.9.0",
                            "relativeLocation": "xaver.clang-format-1.9.0",
                            "location": {
                                "$mid": 1,
                                "path": str(insiders_root / "xaver.clang-format-1.9.0"),
                                "scheme": "file",
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )

            report = apply_extension_setup(
                stable_root,
                insiders_root,
                config=config,
            )

            self.assertEqual(report.migrated_count, 1)
            migrated_target = stable_root / "xaver.clang-format-1.9.0"
            self.assertTrue(migrated_target.is_dir())
            self.assertTrue((insiders_root / "xaver.clang-format-1.9.0").is_symlink())

            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload[0]["relativeLocation"], "xaver.clang-format-1.9.0")
            self.assertEqual(
                payload[0]["location"]["path"],
                str(insiders_root / "xaver.clang-format-1.9.0"),
            )
            self.assertEqual(report.manifest_apply_report.updated_entries, 0)
            self.assertEqual(report.manifest_apply_report.removed_entries, 0)

    def test_removes_stale_symlink_but_preserves_profile_selection(self) -> None:
        """A symlink whose Stable target was deleted should be removed without touching the manifest."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            config = VscodePathsConfig.from_home(home)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = config.insiders_profile_roots[0] / "profile-a"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)
            profile_dir.mkdir(parents=True)

            (insiders_root / "ghost.ext-1.0.0").symlink_to(stable_root / "ghost.ext-1.0.0")
            manifest_path = profile_dir / "extensions.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "identifier": {"id": "ghost.ext"},
                            "version": "1.0.0",
                            "relativeLocation": "ghost.ext-1.0.0",
                            "location": {
                                "$mid": 1,
                                "path": str(insiders_root / "ghost.ext-1.0.0"),
                                "scheme": "file",
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )

            report = apply_extension_setup(
                stable_root,
                insiders_root,
                config=config,
            )

            self.assertEqual(report.removed_stale_symlink_count, 1)
            self.assertFalse((insiders_root / "ghost.ext-1.0.0").exists())
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload[0]["relativeLocation"], "ghost.ext-1.0.0")

    def test_setup_updates_profile_manifest_to_current_installed_version(self) -> None:
        """A Stable profile manifest should be rebound to the newest installed version."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            config = VscodePathsConfig.from_home(home)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = config.stable_profile_roots[0] / "profile-a"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)
            profile_dir.mkdir(parents=True)

            (stable_root / "foo.ext-2.0.0").mkdir()
            manifest_path = profile_dir / "extensions.json"
            original_payload = [
                {
                    "identifier": {"id": "foo.ext"},
                    "version": "1.0.0",
                    "relativeLocation": "foo.ext-1.0.0",
                    "location": {
                        "$mid": 1,
                        "path": str(stable_root / "foo.ext-1.0.0"),
                        "scheme": "file",
                    },
                }
            ]
            manifest_path.write_text(json.dumps(original_payload), encoding="utf-8")

            report = apply_extension_setup(
                stable_root,
                insiders_root,
                config=config,
            )

            self.assertEqual(report.manifest_apply_report.updated_entries, 1)
            self.assertEqual(report.manifest_apply_report.removed_entries, 0)
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload[0]["relativeLocation"], "foo.ext-2.0.0")
            self.assertEqual(payload[0]["version"], "2.0.0")
            self.assertEqual(
                payload[0]["location"]["path"],
                str(canonicalize_path(stable_root / "foo.ext-2.0.0")),
            )

    def test_setup_restores_excluded_symlink_as_independent_copy(self) -> None:
        """Excluded extensions symlinked into Insiders should be materialized as real copies."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            config = VscodePathsConfig.from_home(home)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)

            excluded_dir = stable_root / "anthropic.claude-code-1.0.0"
            excluded_dir.mkdir()
            (excluded_dir / "marker.txt").write_text("stable", encoding="utf-8")
            excluded_link = insiders_root / "anthropic.claude-code-1.0.0"
            excluded_link.symlink_to(excluded_dir)

            report = apply_extension_setup(stable_root, insiders_root, config=config)

            self.assertEqual(report.restored_excluded_copy_count, 1)
            self.assertEqual(report.skipped_excluded_symlink_count, 0)
            self.assertTrue(excluded_link.is_dir())
            self.assertFalse(excluded_link.is_symlink())
            self.assertEqual((excluded_link / "marker.txt").read_text(encoding="utf-8"), "stable")

    def test_setup_rolls_back_extension_tree_when_manifest_apply_aborts(self) -> None:
        """A post-mutation manifest failure must restore the pre-run extension tree."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            config = VscodePathsConfig.from_home(home)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)

            unmanaged_dir = insiders_root / "xaver.clang-format-1.9.0"
            unmanaged_dir.mkdir()
            (unmanaged_dir / "marker.txt").write_text("original", encoding="utf-8")

            with patch(
                "vscode_sync_apply.apply_manifest_repair_plan_safely",
                side_effect=ProfileManifestSafetyError("forced test failure"),
            ):
                with self.assertRaises(ProfileManifestSafetyError):
                    apply_extension_setup(stable_root, insiders_root, config=config)

            self.assertTrue(unmanaged_dir.is_dir())
            self.assertFalse(unmanaged_dir.is_symlink())
            self.assertEqual((unmanaged_dir / "marker.txt").read_text(encoding="utf-8"), "original")
            self.assertFalse((stable_root / "xaver.clang-format-1.9.0").exists())


class ApplyExtensionRemoveTests(unittest.TestCase):
    """Verify that removal restores independent copies and preserves real directories."""

    def test_remove_restores_shared_entries_and_prunes_broken_symlinks(self) -> None:
        """Shared symlinks should become real copies while broken ones are removed."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)

            shared_dir = stable_root / "foo.ext-1.0.0"
            shared_dir.mkdir()
            (shared_dir / "marker.txt").write_text("shared", encoding="utf-8")
            shared_link = insiders_root / "foo.ext-1.0.0"
            shared_link.symlink_to(shared_dir)
            (insiders_root / "ghost.ext-1.0.0").symlink_to(stable_root / "ghost.ext-1.0.0")
            (insiders_root / "native.ext-1.0.0").mkdir()

            report = apply_extension_remove(stable_root, insiders_root)

            self.assertEqual(report.restored_root_copy_count, 0)
            self.assertEqual(report.restored_entry_copy_count, 1)
            self.assertEqual(report.removed_broken_symlink_count, 1)
            self.assertEqual(report.skipped_real_dir_count, 1)
            self.assertTrue(shared_link.is_dir())
            self.assertFalse(shared_link.is_symlink())
            self.assertEqual((shared_link / "marker.txt").read_text(encoding="utf-8"), "shared")
            self.assertFalse((insiders_root / "ghost.ext-1.0.0").exists())
            self.assertTrue((insiders_root / "native.ext-1.0.0").is_dir())
            self.assertEqual(report.failed_paths, ())

    def test_remove_restores_legacy_root_symlink_to_real_directory(self) -> None:
        """A legacy root symlink should be replaced with a copied independent directory."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            stable_root.mkdir(parents=True)
            shared_dir = stable_root / "foo.ext-1.0.0"
            shared_dir.mkdir()
            (shared_dir / "marker.txt").write_text("shared", encoding="utf-8")

            insiders_root = home / ".vscode-insiders/extensions"
            insiders_root.parent.mkdir(parents=True)
            insiders_root.symlink_to(stable_root)

            report = apply_extension_remove(stable_root, insiders_root)

            self.assertEqual(report.restored_root_copy_count, 1)
            self.assertEqual(report.restored_entry_copy_count, 0)
            self.assertEqual(report.removed_broken_symlink_count, 0)
            self.assertTrue(insiders_root.is_dir())
            self.assertFalse(insiders_root.is_symlink())
            self.assertEqual(
                (insiders_root / "foo.ext-1.0.0" / "marker.txt").read_text(encoding="utf-8"),
                "shared",
            )
            self.assertEqual(report.failed_paths, ())


if __name__ == "__main__":
    unittest.main()
