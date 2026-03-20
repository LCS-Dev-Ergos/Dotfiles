from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from vscode_config import VscodePathsConfig
from vscode_recovery import plan_missing_extension_recovery


class RecoveryPlannerTests(unittest.TestCase):
    def test_plans_alias_when_newer_install_already_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = home / "Library/Application Support/Code/User/profiles/profile-a"
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
                config=VscodePathsConfig.from_home(home),
            )

            self.assertEqual(len(plan.requests), 1)
            self.assertEqual(len(plan.install_tasks), 0)
            self.assertEqual(len(plan.alias_tasks), 1)
            self.assertEqual(plan.alias_tasks[0].alias_path, stable_root / "foo.ext-1.0.0")
            self.assertEqual(plan.alias_tasks[0].target_path, stable_root / "foo.ext-2.0.0")

    def test_plans_install_when_missing_extension_is_not_installed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            profile_dir = home / "Library/Application Support/Code/User/profiles/profile-a"
            global_storage = home / "Library/Application Support/Code/User/globalStorage"
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
                config=VscodePathsConfig.from_home(home),
            )

            self.assertEqual(len(plan.requests), 1)
            self.assertEqual(len(plan.install_tasks), 1)
            self.assertEqual(plan.install_tasks[0].installer, "code")
            self.assertEqual(plan.install_tasks[0].install_spec, "foo.ext@1.0.0")
            self.assertEqual(plan.install_tasks[0].profile_name, "LCS.Python")


if __name__ == "__main__":
    unittest.main()
