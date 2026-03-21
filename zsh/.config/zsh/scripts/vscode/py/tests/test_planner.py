from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from _support import MODULE_ROOT

from vscode_config import VscodePathsConfig
from vscode_models import CleanupAction, CleanupStrategy, SymlinkAction
from vscode_planner import plan_extension_cleanup, plan_insiders_symlink_state


class CleanupPlannerTests(unittest.TestCase):
    def test_default_reference_guard_protects_all_manifest_named_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "extensions"
            root.mkdir()
            (root / "foo.ext-1.0.0").mkdir()
            (root / "foo.ext-2.0.0").mkdir()
            (root / "extensions.json").write_text(
                json.dumps(
                    [
                        {"relativeLocation": "foo.ext-1.0.0"},
                        {"relativeLocation": "foo.ext-2.0.0"},
                    ]
                ),
                encoding="utf-8",
            )

            plan = plan_extension_cleanup(
                root,
                strategy=CleanupStrategy.NEWEST,
                respect_references=True,
                config=VscodePathsConfig.from_home(temp_dir),
            )

            self.assertEqual(plan.raw_reference_names, ("foo.ext-1.0.0", "foo.ext-2.0.0"))
            self.assertEqual(plan.protected_reference_names, ("foo.ext-1.0.0", "foo.ext-2.0.0"))
            self.assertEqual(plan.stale_reference_names, ("foo.ext-1.0.0",))
            self.assertEqual(plan.planned_deletion_count, 0)
            self.assertEqual(plan.duplicate_group_count, 1)

            actions = {
                decision.folder_name: decision.action
                for decision in plan.groups[0].decisions
            }
            self.assertEqual(actions["foo.ext-1.0.0"], CleanupAction.SKIP_REFERENCED)
            self.assertEqual(actions["foo.ext-2.0.0"], CleanupAction.KEEP)

    def test_prune_stale_references_allows_older_referenced_versions_to_be_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "extensions"
            root.mkdir()
            (root / "foo.ext-1.0.0").mkdir()
            (root / "foo.ext-2.0.0").mkdir()
            (root / "extensions.json").write_text(
                json.dumps(
                    [
                        {"relativeLocation": "foo.ext-1.0.0"},
                        {"relativeLocation": "foo.ext-2.0.0"},
                    ]
                ),
                encoding="utf-8",
            )

            plan = plan_extension_cleanup(
                root,
                strategy=CleanupStrategy.NEWEST,
                respect_references=True,
                prune_stale_references=True,
                config=VscodePathsConfig.from_home(temp_dir),
            )

            self.assertEqual(plan.raw_reference_names, ("foo.ext-1.0.0", "foo.ext-2.0.0"))
            self.assertEqual(plan.protected_reference_names, ("foo.ext-2.0.0",))
            self.assertEqual(plan.stale_reference_names, ("foo.ext-1.0.0",))
            self.assertEqual(plan.planned_deletion_count, 1)
            self.assertEqual(plan.duplicate_group_count, 1)

            actions = {
                decision.folder_name: decision.action
                for decision in plan.groups[0].decisions
            }
            self.assertEqual(actions["foo.ext-1.0.0"], CleanupAction.DELETE)
            self.assertEqual(actions["foo.ext-2.0.0"], CleanupAction.KEEP)

    def test_missing_referenced_version_is_marked_stale_when_newer_install_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "extensions"
            root.mkdir()
            (root / "foo.ext-2.0.0").mkdir()
            (root / "extensions.json").write_text(
                json.dumps([{"relativeLocation": "foo.ext-1.0.0"}]),
                encoding="utf-8",
            )

            plan = plan_extension_cleanup(
                root,
                strategy=CleanupStrategy.NEWEST,
                respect_references=True,
                prune_stale_references=True,
                config=VscodePathsConfig.from_home(temp_dir),
            )

            self.assertEqual(plan.protected_reference_names, ())
            self.assertEqual(plan.stale_reference_names, ("foo.ext-1.0.0",))

    def test_oldest_strategy_deletes_only_one_unreferenced_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "extensions"
            root.mkdir()
            (root / "foo.ext-1.0.0").mkdir()
            (root / "foo.ext-2.0.0").mkdir()
            (root / "foo.ext-3.0.0").mkdir()
            (root / "extensions.json").write_text(
                json.dumps([{"relativeLocation": "foo.ext-3.0.0"}]),
                encoding="utf-8",
            )

            plan = plan_extension_cleanup(
                root,
                strategy=CleanupStrategy.OLDEST,
                respect_references=True,
                config=VscodePathsConfig.from_home(temp_dir),
            )

            delete_decisions = [
                decision for decision in plan.groups[0].decisions if decision.action == CleanupAction.DELETE
            ]
            self.assertEqual(len(delete_decisions), 1)
            self.assertEqual(delete_decisions[0].folder_name, "foo.ext-1.0.0")


class SymlinkPlannerTests(unittest.TestCase):
    def test_detects_missing_broken_wrong_target_unmanaged_and_excluded_states(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            base = Path(temp_dir)
            stable_root = base / "stable"
            insiders_root = base / "insiders"
            stable_root.mkdir()
            insiders_root.mkdir()

            (stable_root / "shared.ok-1.0.0").mkdir()
            (stable_root / "shared.missing-1.0.0").mkdir()
            (stable_root / "shared.broken-1.0.0").mkdir()
            (stable_root / "shared.wrong-1.0.0").mkdir()
            (stable_root / "shared.real-1.0.0").mkdir()
            (stable_root / "github.copilot-chat-0.43.2026032001").mkdir()

            (insiders_root / "shared.ok-1.0.0").symlink_to(stable_root / "shared.ok-1.0.0")
            (insiders_root / "shared.broken-1.0.0").symlink_to(stable_root / "shared.broken-missing")
            wrong_target = base / "elsewhere"
            wrong_target.mkdir()
            (insiders_root / "shared.wrong-1.0.0").symlink_to(wrong_target)
            (insiders_root / "shared.real-1.0.0").mkdir()
            (insiders_root / "github.copilot-chat-0.43.2026032001").symlink_to(
                stable_root / "github.copilot-chat-0.43.2026032001"
            )
            (insiders_root / "old.stale-0.9.0").symlink_to(stable_root / "old.stale-0.9.0")

            plan = plan_insiders_symlink_state(
                stable_root,
                insiders_root,
                exclude_patterns=("github.copilot-*",),
            )

            self.assertEqual(plan.expected_link_count, 5)
            self.assertEqual(plan.linked_count, 1)
            self.assertEqual(plan.missing_count, 1)
            self.assertEqual(plan.broken_count, 1)
            self.assertEqual(plan.wrong_target_count, 1)
            self.assertEqual(plan.unmanaged_count, 1)
            self.assertEqual(plan.excluded_count, 1)
            self.assertEqual(plan.excluded_symlinked_count, 1)
            self.assertEqual(plan.stale_managed_count, 1)

            actions = {}
            for decision in plan.decisions:
                actions.setdefault(decision.folder_name, set()).add(decision.action)

            self.assertEqual(actions["shared.ok-1.0.0"], {SymlinkAction.LINKED})
            self.assertEqual(actions["shared.missing-1.0.0"], {SymlinkAction.MISSING})
            self.assertEqual(actions["shared.broken-1.0.0"], {SymlinkAction.BROKEN})
            self.assertEqual(actions["shared.wrong-1.0.0"], {SymlinkAction.WRONG_TARGET})
            self.assertEqual(actions["shared.real-1.0.0"], {SymlinkAction.UNMANAGED_REAL_DIR})
            self.assertEqual(
                actions["github.copilot-chat-0.43.2026032001"],
                {SymlinkAction.EXCLUDED_BUT_SYMLINKED},
            )
            self.assertEqual(actions["old.stale-0.9.0"], {SymlinkAction.STALE_MANAGED_SYMLINK})


if __name__ == "__main__":
    unittest.main()
