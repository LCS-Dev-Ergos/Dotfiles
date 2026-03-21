"""Tests for: `vscode_cleanup` -- quarantine-based duplicate cleanup."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from _support import MODULE_ROOT

from vscode_cleanup import (
    _cleanup_backup_roots,
    apply_cleanup_plan,
    deletable_paths_from_plan,
)
from vscode_config import VscodePathsConfig
from vscode_models import CleanupStrategy
from vscode_planner import plan_extension_cleanup


class CleanupApplyTests(unittest.TestCase):
    """Verify that cleanup quarantine moves only the planned paths and respects security."""

    def test_apply_cleanup_plan_deletes_only_planned_paths(self) -> None:
        """The old duplicate should be quarantined; the newest version must stay."""

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "extensions"
            root.mkdir()
            old_dir = root / "foo.ext-1.0.0"
            new_dir = root / "foo.ext-2.0.0"
            old_dir.mkdir()
            new_dir.mkdir()
            (root / "extensions.json").write_text(
                json.dumps([{"relativeLocation": "foo.ext-2.0.0"}]),
                encoding="utf-8",
            )

            plan = plan_extension_cleanup(
                root,
                strategy=CleanupStrategy.NEWEST,
                respect_references=True,
                config=VscodePathsConfig.from_home(temp_dir),
            )
            self.assertEqual(deletable_paths_from_plan(plan), (old_dir,))

            report = apply_cleanup_plan(plan)

            self.assertFalse(old_dir.exists())
            self.assertTrue(new_dir.exists())
            self.assertEqual(len(report.quarantined_paths), 1)
            self.assertTrue(report.quarantined_paths[0].is_dir())
            self.assertEqual(report.quarantined_paths[0].name, old_dir.name)
            self.assertEqual(report.failed_paths, ())

    def test_ignores_env_backup_root_outside_home(self) -> None:
        """$VSCODE_SYNC_BACKUP_DIR outside HOME must be rejected for safety."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir) / "home"
            root = home / ".vscode/extensions"
            home.mkdir()
            root.mkdir(parents=True)

            original_home = os.environ.get("HOME")
            original_backup_dir = os.environ.get("VSCODE_SYNC_BACKUP_DIR")
            os.environ["HOME"] = str(home)
            os.environ["VSCODE_SYNC_BACKUP_DIR"] = "/tmp/outside-home"
            try:
                backup_roots = _cleanup_backup_roots(root)
            finally:
                if original_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = original_home
                if original_backup_dir is None:
                    os.environ.pop("VSCODE_SYNC_BACKUP_DIR", None)
                else:
                    os.environ["VSCODE_SYNC_BACKUP_DIR"] = original_backup_dir

            self.assertNotIn(Path("/tmp/outside-home"), backup_roots)


if __name__ == "__main__":
    unittest.main()
