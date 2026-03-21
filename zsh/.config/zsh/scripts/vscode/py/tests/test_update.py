"""Tests for: `vscode_update` -- native excluded update isolation and full update workflow."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import _support  # noqa: F401
from vscode_config import VscodePathsConfig
from vscode_models import ExtensionSetupReport, ManifestApplyReport
from vscode_update import (
    _parse_shared_updated_extension_ids,
    _update_native_excluded_extension,
    apply_extension_update,
    build_extension_update_plan,
)


class NativeExcludedUpdateTests(unittest.TestCase):
    """Verify isolated update flow for extensions excluded from symlink sharing."""

    def test_native_excluded_update_returns_current_when_no_newer_version_exists(
        self,
    ) -> None:
        """If the staged update produces the same version, result should be 'current'."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            insiders_root = home / ".vscode-insiders/extensions"
            insiders_root.mkdir(parents=True)
            current_dir = insiders_root / "anthropic.claude-code-1.0.0"
            current_dir.mkdir()

            with patch(
                "vscode_update._run_cli_command",
                return_value=subprocess.CompletedProcess(["code-insiders"], 0),
            ):
                result = _update_native_excluded_extension(
                    "anthropic.claude-code",
                    insiders_dir=insiders_root,
                    home=home,
                )

            self.assertEqual(result, "current")
            self.assertTrue(current_dir.is_dir())
            self.assertFalse((home / ".local/share/vscode-sync-backups").exists())

    def test_native_excluded_update_promotes_newer_version_into_real_root(self) -> None:
        """A staged newer version should be promoted into the real Insiders root with a backup."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            insiders_root = home / ".vscode-insiders/extensions"
            insiders_root.mkdir(parents=True)
            old_dir = insiders_root / "anthropic.claude-code-1.0.0"
            old_dir.mkdir()

            def fake_update(
                command: list[str], *, capture_output: bool = False
            ) -> subprocess.CompletedProcess[object]:
                self.assertTrue(capture_output)
                temp_root = Path(command[2])
                (temp_root / "anthropic.claude-code-1.1.0").mkdir()
                return subprocess.CompletedProcess(command, 0)

            with patch("vscode_update._run_cli_command", side_effect=fake_update):
                result = _update_native_excluded_extension(
                    "anthropic.claude-code",
                    insiders_dir=insiders_root,
                    home=home,
                )

            self.assertEqual(result, "applied")
            self.assertFalse(old_dir.exists())
            self.assertTrue((insiders_root / "anthropic.claude-code-1.1.0").is_dir())
            backup_paths = tuple(
                (home / ".local/share/vscode-sync-backups").glob(
                    "*_native-excluded-update/anthropic.claude-code/anthropic.claude-code-1.0.0"
                )
            )
            self.assertEqual(len(backup_paths), 1)

    def test_native_excluded_update_keeps_real_root_untouched_on_failed_update(
        self,
    ) -> None:
        """A failed update command must leave the existing install and root intact."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            insiders_root = home / ".vscode-insiders/extensions"
            insiders_root.mkdir(parents=True)
            old_dir = insiders_root / "github.copilot-chat-0.40.0"
            old_dir.mkdir()

            def fake_update(
                command: list[str], *, capture_output: bool = False
            ) -> subprocess.CompletedProcess[object]:
                self.assertTrue(capture_output)
                temp_root = Path(command[2])
                (temp_root / "github.copilot-chat-0.40.1").mkdir()
                return subprocess.CompletedProcess(command, 1)

            with patch("vscode_update._run_cli_command", side_effect=fake_update):
                result = _update_native_excluded_extension(
                    "github.copilot-chat",
                    insiders_dir=insiders_root,
                    home=home,
                )

            self.assertEqual(result, "failed")
            self.assertTrue(old_dir.is_dir())
            self.assertFalse((insiders_root / "github.copilot-chat-0.40.1").exists())
            self.assertFalse((home / ".local/share/vscode-sync-backups").exists())


class ExtensionUpdateReportTests(unittest.TestCase):
    """Verify update report parsing and full workflow classification."""

    def test_parse_shared_updated_extension_ids_deduplicates_cli_noise(self) -> None:
        """Duplicate update lines in CLI output should yield unique extension IDs."""

        parsed = _parse_shared_updated_extension_ids(
            "\n".join(
                [
                    "Updating extensions: foo.bar, baz.qux",
                    "Extension 'foo.bar' v1.2.3 was successfully updated.",
                    "Extension 'foo.bar' v1.2.3 was successfully updated.",
                    "Extension 'baz.qux' v4.5.6 was successfully updated.",
                ]
            )
        )

        self.assertEqual(parsed, ("foo.bar", "baz.qux"))

    def test_apply_extension_update_classifies_excluded_update_outcomes(self) -> None:
        """Each native excluded extension should be classified as current, applied, or failed."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)

            (insiders_root / "anthropic.claude-code-1.0.0").mkdir()
            (insiders_root / "github.copilot-chat-0.40.0").mkdir()

            plan = build_extension_update_plan(
                stable_root,
                insiders_root,
                skip_clean=True,
                config=VscodePathsConfig.from_home(home),
            )

            setup_report = ExtensionSetupReport(
                linked_count=0,
                relinked_count=0,
                migrated_count=0,
                removed_stale_symlink_count=0,
                skipped_excluded_symlink_count=0,
                manifest_apply_report=ManifestApplyReport(
                    updated_entries=0,
                    removed_entries=0,
                    touched_manifests=(),
                ),
            )

            def fake_native_result(
                extension_id: str,
                *,
                insiders_dir: Path,
                home: Path,
            ) -> str:
                del insiders_dir, home
                return {
                    "anthropic.claude-code": "current",
                    "github.copilot-chat": "failed",
                }[extension_id]

            with (
                patch("vscode_update.shutil.which", return_value="/usr/bin/true"),
                patch(
                    "vscode_update._run_cli_command",
                    return_value=subprocess.CompletedProcess(["code"], 0),
                ),
                patch(
                    "vscode_update._update_native_excluded_extension",
                    side_effect=fake_native_result,
                ),
                patch(
                    "vscode_update.apply_extension_setup",
                    return_value=setup_report,
                ),
            ):
                report = apply_extension_update(
                    plan,
                    config=VscodePathsConfig.from_home(home),
                )

            self.assertEqual(
                report.excluded_updates_attempted,
                ("anthropic.claude-code", "github.copilot-chat"),
            )
            self.assertEqual(report.excluded_updates_applied, ())
            self.assertEqual(report.excluded_updates_current, ("anthropic.claude-code",))
            self.assertEqual(report.excluded_updates_failed, ("github.copilot-chat",))
            self.assertEqual(report.shared_updated_extension_ids, ())

    def test_apply_extension_update_replans_cleanup_after_shared_update(self) -> None:
        """Post-update cleanup must re-scan the root and quarantine old duplicates left by the update."""

        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            stable_root = home / ".vscode/extensions"
            insiders_root = home / ".vscode-insiders/extensions"
            stable_root.mkdir(parents=True)
            insiders_root.mkdir(parents=True)

            old_dir = stable_root / "foo.ext-1.0.0"
            old_dir.mkdir()
            (stable_root / "extensions.json").write_text(
                json.dumps(
                    [
                        {
                            "identifier": {"id": "foo.ext"},
                            "version": "1.0.0",
                            "relativeLocation": "foo.ext-1.0.0",
                            "location": {
                                "$mid": 1,
                                "path": str(old_dir),
                                "scheme": "file",
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )

            plan = build_extension_update_plan(
                stable_root,
                insiders_root,
                skip_clean=False,
                config=VscodePathsConfig.from_home(home),
            )
            self.assertEqual(plan.cleanup_plan.planned_deletion_count, 0)

            setup_report = ExtensionSetupReport(
                linked_count=0,
                relinked_count=0,
                migrated_count=0,
                removed_stale_symlink_count=0,
                skipped_excluded_symlink_count=0,
                manifest_apply_report=ManifestApplyReport(
                    updated_entries=0,
                    removed_entries=0,
                    touched_manifests=(),
                ),
            )

            def fake_shared_update(
                command: list[str],
                *,
                capture_output: bool = False,
            ) -> subprocess.CompletedProcess[object]:
                self.assertTrue(capture_output)
                new_dir = stable_root / "foo.ext-2.0.0"
                new_dir.mkdir()
                (stable_root / "extensions.json").write_text(
                    json.dumps(
                        [
                            {
                                "identifier": {"id": "foo.ext"},
                                "version": "2.0.0",
                                "relativeLocation": "foo.ext-2.0.0",
                                "location": {
                                    "$mid": 1,
                                    "path": str(new_dir),
                                    "scheme": "file",
                                },
                            }
                        ]
                    ),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="Extension 'foo.ext' v2.0.0 was successfully updated.\n",
                    stderr="",
                )

            with (
                patch("vscode_update.shutil.which", return_value="/usr/bin/true"),
                patch(
                    "vscode_update._run_cli_command",
                    side_effect=fake_shared_update,
                ),
                patch(
                    "vscode_update.apply_extension_setup",
                    return_value=setup_report,
                ),
            ):
                report = apply_extension_update(
                    plan,
                    config=VscodePathsConfig.from_home(home),
                )

            self.assertEqual(report.shared_updated_extension_ids, ("foo.ext",))
            self.assertEqual(report.cleanup_quarantined_count, 1)
            self.assertFalse(old_dir.exists())
            self.assertTrue((stable_root / "foo.ext-2.0.0").is_dir())


if __name__ == "__main__":
    unittest.main()
