from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from _support import MODULE_ROOT

from vscode_config import VscodePathsConfig
from vscode_manifests import (
    collect_reference_entries,
    collect_reference_names,
    parse_manifest_reference_entries,
)

FIXTURES_DIR = MODULE_ROOT / "tests/fixtures/manifests"


def _fixture_text(name: str) -> str:
    return (FIXTURES_DIR / name).read_text(encoding="utf-8")


class ParseManifestReferenceEntriesTests(unittest.TestCase):
    def test_extracts_relative_and_absolute_location_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "extensions.json"
            manifest_path.write_text(_fixture_text("root_extensions.json"), encoding="utf-8")

            entries = parse_manifest_reference_entries(manifest_path)

            self.assertEqual(
                [entry.folder_name for entry in entries],
                [
                    "ms-python.python-2026.5.0",
                    "ms-toolsai.jupyter-2026.4.0",
                    "github.copilot-chat-0.43.2026032001",
                ],
            )


class CollectReferenceNamesTests(unittest.TestCase):
    def test_stable_scope_ignores_insiders_profiles(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)

            stable_extensions_dir = home / ".vscode/extensions"
            stable_extensions_dir.mkdir(parents=True)
            (stable_extensions_dir / "extensions.json").write_text(
                _fixture_text("root_extensions.json"),
                encoding="utf-8",
            )

            stable_profile_dir = home / "Library/Application Support/Code/User/profiles/profile-a"
            stable_profile_dir.mkdir(parents=True)
            (stable_profile_dir / "extensions.json").write_text(
                _fixture_text("stable_profile_extensions.json"),
                encoding="utf-8",
            )

            insiders_profile_dir = (
                home / "Library/Application Support/Code - Insiders/User/profiles/profile-b"
            )
            insiders_profile_dir.mkdir(parents=True)
            (insiders_profile_dir / "extensions.json").write_text(
                _fixture_text("insiders_profile_extensions.json"),
                encoding="utf-8",
            )

            config = VscodePathsConfig.from_home(home)
            names = collect_reference_names(stable_extensions_dir, config=config)

            self.assertEqual(
                names,
                [
                    "github.copilot-chat-0.43.2026032001",
                    "ms-python.python-2026.5.0",
                    "ms-toolsai.jupyter-2026.4.0",
                    "redhat.java-1.54.2026032008-darwin-arm64",
                ],
            )

    def test_local_scope_only_reads_root_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "custom/extensions"
            root.mkdir(parents=True)
            (root / "extensions.json").write_text(
                _fixture_text("root_extensions.json"),
                encoding="utf-8",
            )

            entries = collect_reference_entries(root, config=VscodePathsConfig.from_home(temp_dir))

            self.assertTrue(all(entry.source_kind == "root" for entry in entries))
            self.assertEqual(len(entries), 3)


if __name__ == "__main__":
    unittest.main()

