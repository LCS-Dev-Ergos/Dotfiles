from __future__ import annotations

import json
from pathlib import Path

from vscode_config import VscodePathsConfig
from vscode_fs import canonicalize_path
from vscode_models import ReferenceEntry


class ManifestParseError(RuntimeError):
    """Raised when an extensions manifest cannot be parsed as JSON."""


def _extract_folder_name_from_location_path(location_path: str) -> str | None:
    normalized_path = location_path.replace("\\", "/")
    marker = "/extensions/"
    if marker not in normalized_path:
        return None

    trailing_path = normalized_path.rsplit(marker, 1)[-1].strip("/")
    if not trailing_path:
        return None

    return trailing_path.split("/", 1)[0] or None


def parse_manifest_reference_entries(
    manifest_path: str | Path,
    *,
    source_kind: str = "manifest",
) -> list[ReferenceEntry]:
    """Parse all extension folder references from a VS Code extensions.json file."""
    canonical_manifest_path = canonicalize_path(manifest_path)

    try:
        payload = json.loads(canonical_manifest_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    except json.JSONDecodeError as exc:
        raise ManifestParseError(f"Invalid JSON in {canonical_manifest_path}: {exc}") from exc

    if not isinstance(payload, list):
        return []

    entries: list[ReferenceEntry] = []
    for item in payload:
        if not isinstance(item, dict):
            continue

        relative_location = item.get("relativeLocation")
        if isinstance(relative_location, str):
            folder_name = relative_location.strip().strip("/")
            if folder_name:
                entries.append(
                    ReferenceEntry(
                        folder_name=folder_name,
                        manifest_path=canonical_manifest_path,
                        source_kind=source_kind,
                    )
                )

        location = item.get("location")
        if not isinstance(location, dict):
            continue

        location_path = location.get("path")
        if not isinstance(location_path, str):
            continue

        folder_name = _extract_folder_name_from_location_path(location_path)
        if folder_name:
            entries.append(
                ReferenceEntry(
                    folder_name=folder_name,
                    manifest_path=canonical_manifest_path,
                    source_kind=source_kind,
                )
            )

    return entries


def iter_manifest_paths_for_extensions_dir(
    extensions_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
) -> list[tuple[Path, str]]:
    """Return all manifest paths relevant to the selected extension root."""
    resolved_config = config or VscodePathsConfig.from_home()
    canonical_extensions_dir = canonicalize_path(extensions_dir)
    manifest_paths: list[tuple[Path, str]] = []

    root_manifest = canonical_extensions_dir / "extensions.json"
    if root_manifest.is_file():
        manifest_paths.append((root_manifest, "root"))

    for profile_root in resolved_config.profile_roots_for_extensions_dir(canonical_extensions_dir):
        if not profile_root.is_dir():
            continue
        for profile_dir in sorted(
            (candidate for candidate in profile_root.iterdir() if candidate.is_dir()),
            key=lambda candidate: candidate.name,
        ):
            manifest_path = profile_dir / "extensions.json"
            if manifest_path.is_file():
                manifest_paths.append((manifest_path, "profile"))

    return manifest_paths


def collect_reference_entries(
    extensions_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
) -> list[ReferenceEntry]:
    """Collect structured reference entries for a root and its relevant profiles."""
    entries: list[ReferenceEntry] = []
    for manifest_path, source_kind in iter_manifest_paths_for_extensions_dir(
        extensions_dir,
        config=config,
    ):
        entries.extend(
            parse_manifest_reference_entries(
                manifest_path,
                source_kind=source_kind,
            )
        )
    return entries


def collect_reference_names(
    extensions_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
) -> list[str]:
    """Collect unique referenced folder names relevant to the selected root."""
    names = {entry.folder_name for entry in collect_reference_entries(extensions_dir, config=config)}
    return sorted(names)

