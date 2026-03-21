"""Tests for: `vscode_profiles` -- manifest repair planning and safe application."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from _support import MODULE_ROOT

from vscode_config import VscodePathsConfig
from vscode_models import (
    ManifestAction,
    ManifestRepairDecision,
    ManifestRepairPlan,
    VscodeEdition,
)
from vscode_profiles import (
    ProfileManifestSafetyError,
    _write_manifest_payload_atomically,
    apply_manifest_repair_plan_safely,
    build_update_only_manifest_plan,
    plan_manifest_repairs,
)


class ManifestRepairPlanTests(unittest.TestCase):
    """Verify manifest repair decisions for profile and root manifests."""

    def test_updates_insiders_profile_to_current_shared_version(self) -> None:
        """An Insiders profile referencing an old version should be rebound to the current one."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = (
                home
                / "Library/Application Support/Code - Insiders/User/profiles/profile-a"
            )
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)
            profile_dir.mkdir(parents=True)

            (stable_root / "foo.ext-2.0.0").mkdir()
            (insiders_root / "foo.ext-2.0.0").symlink_to(stable_root / "foo.ext-2.0.0")
            manifest_path = profile_dir / "extensions.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "identifier": {"id": "foo.ext"},
                            "version": "1.0.0",
                            "relativeLocation": "foo.ext-1.0.0",
                            "location": {
                                "$mid": 1,
                                "path": str(insiders_root / "foo.ext-1.0.0"),
                                "scheme": "file",
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )

            plan = plan_manifest_repairs(
                stable_root,
                insiders_root,
                config=VscodePathsConfig.from_home(home),
            )

            self.assertEqual(plan.update_count, 1)
            self.assertEqual(plan.remove_count, 0)
            self.assertEqual(plan.decisions[0].action, ManifestAction.UPDATE)
            self.assertEqual(plan.decisions[0].desired_folder_name, "foo.ext-2.0.0")

            report = apply_manifest_repair_plan_safely(plan)
            self.assertEqual(report.updated_entries, 1)

            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload[0]["relativeLocation"], "foo.ext-2.0.0")
            self.assertEqual(payload[0]["version"], "2.0.0")
            self.assertEqual(
                payload[0]["location"]["path"], str(insiders_root / "foo.ext-2.0.0")
            )

    def test_preserves_missing_profile_entry_instead_of_removing_it(self) -> None:
        """Profile entries for extensions not installed anywhere must be kept (not removed)."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = (
                home / "Library/Application Support/Code/User/profiles/profile-a"
            )
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)
            profile_dir.mkdir(parents=True)

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

            plan = plan_manifest_repairs(
                stable_root,
                insiders_root,
                config=VscodePathsConfig.from_home(home),
            )
            self.assertEqual(plan.remove_count, 0)
            self.assertEqual(plan.preserved_missing_profile_count, 1)
            self.assertEqual(plan.decisions[0].action, ManifestAction.KEEP)

            report = apply_manifest_repair_plan_safely(plan)
            self.assertEqual(report.removed_entries, 0)
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload[0]["relativeLocation"], "ghost.ext-1.0.0")

    def test_root_manifest_orphan_is_still_removed(self) -> None:
        """Root-manifest entries with no installed extension should be removed."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)

            manifest_path = stable_root / "extensions.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "identifier": {"id": "ghost.ext"},
                            "version": "1.0.0",
                            "relativeLocation": "ghost.ext-1.0.0",
                            "location": {
                                "$mid": 1,
                                "path": str(stable_root / "ghost.ext-1.0.0"),
                                "scheme": "file",
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )

            plan = plan_manifest_repairs(
                stable_root,
                insiders_root,
                config=VscodePathsConfig.from_home(home),
            )
            self.assertEqual(plan.remove_count, 1)
            self.assertEqual(plan.preserved_missing_profile_count, 0)
            self.assertEqual(plan.decisions[0].action, ManifestAction.REMOVE)

            report = apply_manifest_repair_plan_safely(plan)
            self.assertEqual(report.removed_entries, 1)
            self.assertEqual(json.loads(manifest_path.read_text(encoding="utf-8")), [])

    def test_update_only_manifest_plan_skips_remove_actions(self) -> None:
        """build_update_only_manifest_plan must strip REMOVE decisions."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)

            manifest_path = stable_root / "extensions.json"
            manifest_path.write_text(
                json.dumps(
                    [
                        {
                            "identifier": {"id": "ghost.ext"},
                            "version": "1.0.0",
                            "relativeLocation": "ghost.ext-1.0.0",
                            "location": {
                                "$mid": 1,
                                "path": str(stable_root / "ghost.ext-1.0.0"),
                                "scheme": "file",
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )

            plan = plan_manifest_repairs(
                stable_root,
                insiders_root,
                config=VscodePathsConfig.from_home(home),
            )
            filtered_plan = build_update_only_manifest_plan(plan)

            self.assertEqual(filtered_plan.update_count, 0)
            self.assertEqual(filtered_plan.remove_count, 0)
            self.assertEqual(filtered_plan.decisions, ())

    def test_safe_apply_rolls_back_if_profile_selection_would_change(self) -> None:
        """Removing a profile entry must trigger a rollback via ProfileManifestSafetyError."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = (
                home / "Library/Application Support/Code/User/profiles/profile-a"
            )
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)
            profile_dir.mkdir(parents=True)

            manifest_path = profile_dir / "extensions.json"
            original_payload = [
                {
                    "identifier": {"id": "ghost.ext"},
                    "version": "1.0.0",
                    "relativeLocation": "ghost.ext-1.0.0",
                    "location": {
                        "$mid": 1,
                        "path": str(stable_root / "ghost.ext-1.0.0"),
                        "scheme": "file",
                    },
                }
            ]
            manifest_path.write_text(
                json.dumps(original_payload),
                encoding="utf-8",
            )

            plan = ManifestRepairPlan(
                stable_dir=stable_root,
                insiders_dir=insiders_root,
                update_count=0,
                remove_count=1,
                keep_count=0,
                preserved_missing_profile_count=0,
                decisions=(
                    ManifestRepairDecision(
                        manifest_path=manifest_path,
                        entry_index=0,
                        edition=VscodeEdition.STABLE,
                        source_kind="profile",
                        extension_id="ghost.ext",
                        current_folder_name="ghost.ext-1.0.0",
                        desired_folder_name=None,
                        action=ManifestAction.REMOVE,
                        reason="test_remove_profile_entry",
                    ),
                ),
            )

            with self.assertRaises(ProfileManifestSafetyError):
                apply_manifest_repair_plan_safely(plan)

            restored_payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(restored_payload, original_payload)

    def test_atomic_manifest_write_replaces_content_cleanly(self) -> None:
        """Atomic write must fully replace the previous file content."""
        
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "extensions.json"
            manifest_path.write_text(
                '[{"relativeLocation":"old.ext-1.0.0"}]\n', encoding="utf-8"
            )

            _write_manifest_payload_atomically(
                manifest_path,
                [{"relativeLocation": "new.ext-2.0.0"}],
            )

            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(payload, [{"relativeLocation": "new.ext-2.0.0"}])


if __name__ == "__main__":
    unittest.main()
