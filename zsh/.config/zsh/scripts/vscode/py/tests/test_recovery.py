"""Tests for: `vscode_recovery` -- missing extension recovery planning."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from vscode_config import VscodePathsConfig
from vscode_fs import canonicalize_path
from vscode_recovery import _safe_replace_alias, plan_missing_extension_recovery


class RecoveryPlannerTests(unittest.TestCase):
    """Verify that recovery plans either alias to existing installs or schedule CLI installs."""

    def test_plans_alias_when_newer_install_already_exists(self) -> None:
        """If a newer version of the requested extension is installed, an alias should be planned."""

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
            (profile_dir / "extensions.json").write_text(
                json.dumps(
                    [
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
                ),
                encoding="utf-8",
            )

            plan = plan_missing_extension_recovery(
                stable_root,
                insiders_root,
                config=config,
            )

            self.assertEqual(len(plan.requests), 1)
            self.assertEqual(len(plan.install_tasks), 0)
            self.assertEqual(len(plan.alias_tasks), 1)
            self.assertEqual(
                canonicalize_path(plan.alias_tasks[0].alias_path),
                canonicalize_path(stable_root / "foo.ext-1.0.0"),
            )
            self.assertEqual(
                canonicalize_path(plan.alias_tasks[0].target_path),
                canonicalize_path(stable_root / "foo.ext-2.0.0"),
            )

    def test_plans_install_when_missing_extension_is_not_installed(self) -> None:
        """When no version of the extension is installed, a CLI install task should be scheduled."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            config = VscodePathsConfig.from_home(home)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = config.stable_profile_roots[0] / "profile-a"
            global_storage = config.stable_user_dir / "globalStorage"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)
            profile_dir.mkdir(parents=True)
            global_storage.mkdir(parents=True)
            (global_storage / "storage.json").write_text(
                json.dumps(
                    {
                        "userDataProfiles": [
                            {"location": "profile-a", "name": "LCS.Python"},
                        ]
                    }
                ),
                encoding="utf-8",
            )

            (profile_dir / "extensions.json").write_text(
                json.dumps(
                    [
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
                ),
                encoding="utf-8",
            )

            plan = plan_missing_extension_recovery(
                stable_root,
                insiders_root,
                config=config,
            )

            self.assertEqual(len(plan.requests), 1)
            self.assertEqual(len(plan.install_tasks), 1)
            self.assertEqual(plan.install_tasks[0].installer, "code")
            self.assertEqual(plan.install_tasks[0].install_spec, "foo.ext@1.0.0")
            self.assertEqual(plan.install_tasks[0].profile_name, "LCS.Python")


class RecoveryAliasSafetyTests(unittest.TestCase):
    """Verify alias replacement keeps containment checks robust."""

    def test_safe_replace_alias_rejects_parent_escape(self) -> None:
        """Alias paths escaping the managed root via `..` must be rejected."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            managed_root = home / ".vscode/extensions"
            managed_root.mkdir(parents=True)
            target_path = managed_root / "foo.ext-2.0.0"
            target_path.mkdir()

            self.assertFalse(
                _safe_replace_alias(
                    managed_root / "../escape.ext-1.0.0",
                    target_path,
                    root=managed_root,
                )
            )

    def test_safe_replace_alias_allows_alias_inside_root(self) -> None:
        """An alias located inside the managed root should be created successfully."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            managed_root = home / ".vscode/extensions"
            managed_root.mkdir(parents=True)
            target_path = managed_root / "foo.ext-2.0.0"
            target_path.mkdir()
            alias_path = managed_root / "nested/../foo.ext-1.0.0"

            self.assertTrue(_safe_replace_alias(alias_path, target_path, root=managed_root))
            self.assertTrue((managed_root / "foo.ext-1.0.0").is_symlink())


if __name__ == "__main__":
    unittest.main()
