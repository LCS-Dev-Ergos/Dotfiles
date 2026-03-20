from __future__ import annotations

import json
from collections import defaultdict
from copy import deepcopy
from pathlib import Path

from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import canonicalize_path
from vscode_manifests import (
    _extract_folder_name_from_location_path,
    iter_manifest_paths_for_extensions_dir,
)
from vscode_models import (
    ExtensionInstall,
    ManifestAction,
    ManifestApplyReport,
    ManifestRepairDecision,
    ManifestRepairPlan,
    VscodeEdition,
)
from vscode_planner import is_excluded_extension
from vscode_scanner import parse_extension_folder_name, scan_extension_root
from vscode_versions import compare_versions

PRESERVE_MISSING_PROFILE_SELECTION_REASON = "preserve_unresolved_profile_selection"


class ProfileManifestSafetyError(RuntimeError):
    """Raised when a manifest repair would change profile extension selection."""


def _load_manifest_payload(manifest_path: Path) -> list[dict]:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        return []
    return [item for item in payload if isinstance(item, dict)]


def _manifest_context(
    manifest_path: Path,
    *,
    config: VscodePathsConfig,
    stable_dir: Path,
    insiders_dir: Path,
) -> tuple[VscodeEdition, str, Path]:
    canonical_manifest_path = canonicalize_path(manifest_path)

    if canonical_manifest_path == stable_dir / "extensions.json":
        return (VscodeEdition.STABLE, "root", stable_dir)
    if canonical_manifest_path == insiders_dir / "extensions.json":
        return (VscodeEdition.INSIDERS, "root", insiders_dir)

    for profile_root in config.stable_profile_roots:
        if profile_root in canonical_manifest_path.parents:
            return (VscodeEdition.STABLE, "profile", stable_dir)
    for profile_root in config.insiders_profile_roots:
        if profile_root in canonical_manifest_path.parents:
            return (VscodeEdition.INSIDERS, "profile", insiders_dir)

    return (config.scope_for_extensions_dir(stable_dir), "local", stable_dir)


def _sort_installs_by_preference(installs: list[ExtensionInstall]) -> list[ExtensionInstall]:
    def sort_key(install: ExtensionInstall) -> tuple[int, int, str]:
        mtime = install.mtime or 0
        return (0, mtime, install.folder_name)

    sorted_installs = sorted(installs, key=sort_key)
    best_first: list[ExtensionInstall] = []
    for install in sorted_installs:
        inserted = False
        for idx, current in enumerate(best_first):
            cmp = compare_versions(install.version, current.version)
            if cmp > 0 or (cmp == 0 and (install.mtime or 0) > (current.mtime or 0)):
                best_first.insert(idx, install)
                inserted = True
                break
        if not inserted:
            best_first.append(install)
    return best_first


def _build_extension_indexes(
    installs: list[ExtensionInstall],
) -> tuple[dict[str, list[ExtensionInstall]], dict[str, ExtensionInstall]]:
    installs_by_id: dict[str, list[ExtensionInstall]] = defaultdict(list)
    installs_by_name: dict[str, ExtensionInstall] = {}
    for install in installs:
        installs_by_id[install.extension_id].append(install)
        installs_by_name[install.folder_name] = install

    for extension_id in list(installs_by_id):
        installs_by_id[extension_id] = _sort_installs_by_preference(installs_by_id[extension_id])

    return dict(installs_by_id), installs_by_name


def _extract_current_folder_name(item: dict) -> str | None:
    relative_location = item.get("relativeLocation")
    if isinstance(relative_location, str) and relative_location.strip():
        return relative_location.strip().strip("/")

    location = item.get("location")
    if not isinstance(location, dict):
        return None

    location_path = location.get("path")
    if not isinstance(location_path, str):
        return None

    return _extract_folder_name_from_location_path(location_path)


def _extract_extension_id(item: dict, current_folder_name: str | None) -> str | None:
    identifier = item.get("identifier")
    if isinstance(identifier, dict):
        extension_id = identifier.get("id")
        if isinstance(extension_id, str) and extension_id.strip():
            return extension_id.strip()

    if current_folder_name:
        return parse_extension_folder_name(current_folder_name).extension_id

    return None


def _excluded_for_entry(
    extension_id: str | None,
    current_folder_name: str | None,
    exclude_patterns: tuple[str, ...],
) -> bool:
    if current_folder_name and is_excluded_extension(current_folder_name, exclude_patterns):
        return True
    if extension_id and is_excluded_extension(f"{extension_id}-candidate", exclude_patterns):
        return True
    return False


def _best_candidate_for_entry(
    *,
    extension_id: str | None,
    current_folder_name: str | None,
    edition: VscodeEdition,
    current_root: Path,
    stable_by_id: dict[str, list[ExtensionInstall]],
    insiders_by_id: dict[str, list[ExtensionInstall]],
    stable_by_name: dict[str, ExtensionInstall],
    insiders_by_name: dict[str, ExtensionInstall],
    exclude_patterns: tuple[str, ...],
) -> tuple[str | None, Path | None]:
    if extension_id:
        excluded_entry = _excluded_for_entry(extension_id, current_folder_name, exclude_patterns)

        if edition == VscodeEdition.STABLE:
            candidates = stable_by_id.get(extension_id, [])
            if candidates:
                return (candidates[0].folder_name, current_root / candidates[0].folder_name)
        elif excluded_entry:
            candidates = [install for install in insiders_by_id.get(extension_id, []) if not install.is_symlink]
            if not candidates:
                candidates = insiders_by_id.get(extension_id, [])
            if candidates:
                return (candidates[0].folder_name, current_root / candidates[0].folder_name)
        else:
            candidates = stable_by_id.get(extension_id, [])
            if candidates:
                return (candidates[0].folder_name, current_root / candidates[0].folder_name)

            fallback_candidates = insiders_by_id.get(extension_id, [])
            if fallback_candidates:
                return (fallback_candidates[0].folder_name, current_root / fallback_candidates[0].folder_name)

    if current_folder_name:
        if edition == VscodeEdition.STABLE and current_folder_name in stable_by_name:
            current_install = stable_by_name[current_folder_name]
            return (current_install.folder_name, current_root / current_install.folder_name)
        if edition == VscodeEdition.INSIDERS and current_folder_name in insiders_by_name:
            current_install = insiders_by_name[current_folder_name]
            return (current_install.folder_name, current_root / current_install.folder_name)

    return (None, None)


def plan_manifest_repairs(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> ManifestRepairPlan:
    """Plan updates/removals for Stable and Insiders extensions manifests."""
    resolved_config = config or VscodePathsConfig.from_home()
    stable_root = canonicalize_path(stable_dir)
    insiders_root = canonicalize_path(insiders_dir)
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)

    stable_installs = scan_extension_root(stable_root, edition=VscodeEdition.STABLE)
    insiders_installs = scan_extension_root(insiders_root, edition=VscodeEdition.INSIDERS)
    stable_by_id, stable_by_name = _build_extension_indexes(stable_installs)
    insiders_by_id, insiders_by_name = _build_extension_indexes(insiders_installs)

    manifest_specs = iter_manifest_paths_for_extensions_dir(stable_root, config=resolved_config)
    manifest_specs += iter_manifest_paths_for_extensions_dir(insiders_root, config=resolved_config)

    decisions: list[ManifestRepairDecision] = []
    update_count = 0
    remove_count = 0
    keep_count = 0
    preserved_missing_profile_count = 0

    for manifest_path, source_kind in manifest_specs:
        manifest_items = _load_manifest_payload(manifest_path)
        edition, _, current_root = _manifest_context(
            manifest_path,
            config=resolved_config,
            stable_dir=stable_root,
            insiders_dir=insiders_root,
        )

        for entry_index, item in enumerate(manifest_items):
            current_folder_name = _extract_current_folder_name(item)
            extension_id = _extract_extension_id(item, current_folder_name)
            desired_folder_name, _ = _best_candidate_for_entry(
                extension_id=extension_id,
                current_folder_name=current_folder_name,
                edition=edition,
                current_root=current_root,
                stable_by_id=stable_by_id,
                insiders_by_id=insiders_by_id,
                stable_by_name=stable_by_name,
                insiders_by_name=insiders_by_name,
                exclude_patterns=resolved_patterns,
            )

            current_path = current_root / current_folder_name if current_folder_name else None
            current_exists = bool(current_path and current_path.exists())

            action = ManifestAction.KEEP
            reason = "manifest_entry_already_resolves"
            if desired_folder_name:
                if current_folder_name != desired_folder_name:
                    action = ManifestAction.UPDATE
                    reason = "rebind_to_current_installed_version"
                elif not current_exists:
                    action = ManifestAction.UPDATE
                    reason = "repair_missing_referenced_path"
            elif current_exists:
                action = ManifestAction.KEEP
                reason = "current_manifest_entry_still_resolves"
            elif source_kind == "profile":
                action = ManifestAction.KEEP
                reason = PRESERVE_MISSING_PROFILE_SELECTION_REASON
                preserved_missing_profile_count += 1
            else:
                action = ManifestAction.REMOVE
                reason = "remove_orphaned_manifest_entry"

            if action == ManifestAction.UPDATE:
                update_count += 1
            elif action == ManifestAction.REMOVE:
                remove_count += 1
            else:
                keep_count += 1

            decisions.append(
                ManifestRepairDecision(
                    manifest_path=canonicalize_path(manifest_path),
                    entry_index=entry_index,
                    edition=edition,
                    source_kind=source_kind,
                    extension_id=extension_id,
                    current_folder_name=current_folder_name,
                    desired_folder_name=desired_folder_name,
                    action=action,
                    reason=reason,
                )
            )

    return ManifestRepairPlan(
        stable_dir=stable_root,
        insiders_dir=insiders_root,
        update_count=update_count,
        remove_count=remove_count,
        keep_count=keep_count,
        preserved_missing_profile_count=preserved_missing_profile_count,
        decisions=tuple(
            sorted(
                decisions,
                key=lambda decision: (
                    str(decision.manifest_path),
                    decision.entry_index,
                ),
            )
        ),
    )


def is_preserved_missing_profile_decision(decision: ManifestRepairDecision) -> bool:
    return (
        decision.action == ManifestAction.KEEP
        and decision.source_kind == "profile"
        and decision.reason == PRESERVE_MISSING_PROFILE_SELECTION_REASON
    )


def apply_manifest_repair_plan(plan: ManifestRepairPlan) -> ManifestApplyReport:
    """Apply planned manifest repairs in place."""
    grouped: dict[Path, list[ManifestRepairDecision]] = defaultdict(list)
    for decision in plan.decisions:
        if decision.action != ManifestAction.KEEP:
            grouped[decision.manifest_path].append(decision)

    touched_manifests: list[Path] = []
    updated_entries = 0
    removed_entries = 0

    for manifest_path in sorted(grouped):
        payload = _load_manifest_payload(manifest_path)
        decisions_by_index = {decision.entry_index: decision for decision in grouped[manifest_path]}
        updated_payload: list[dict] = []

        for index, item in enumerate(payload):
            decision = decisions_by_index.get(index)
            if not decision:
                updated_payload.append(item)
                continue

            if decision.action == ManifestAction.REMOVE:
                removed_entries += 1
                continue

            updated_item = dict(item)
            if decision.desired_folder_name:
                current_root = plan.stable_dir if decision.edition == VscodeEdition.STABLE else plan.insiders_dir
                updated_item["relativeLocation"] = decision.desired_folder_name
                location = dict(updated_item.get("location") or {})
                location["path"] = str(current_root / decision.desired_folder_name)
                location["scheme"] = "file"
                location.setdefault("$mid", 1)
                updated_item["location"] = location
                parsed = parse_extension_folder_name(decision.desired_folder_name)
                if parsed.version:
                    updated_item["version"] = parsed.version
                updated_entries += 1

            updated_payload.append(updated_item)

        manifest_path.write_text(
            json.dumps(updated_payload, indent=2) + "\n",
            encoding="utf-8",
        )
        touched_manifests.append(manifest_path)

    return ManifestApplyReport(
        updated_entries=updated_entries,
        removed_entries=removed_entries,
        touched_manifests=tuple(touched_manifests),
    )


def _snapshot_manifest_payloads(manifest_paths: set[Path]) -> dict[Path, list[dict]]:
    snapshots: dict[Path, list[dict]] = {}
    for manifest_path in manifest_paths:
        snapshots[manifest_path] = deepcopy(_load_manifest_payload(manifest_path))
    return snapshots


def _restore_manifest_payloads(snapshots: dict[Path, list[dict]]) -> None:
    for manifest_path, payload in snapshots.items():
        manifest_path.write_text(
            json.dumps(payload, indent=2) + "\n",
            encoding="utf-8",
        )


def _profile_entry_signature(item: dict) -> dict:
    return {
        key: deepcopy(value)
        for key, value in item.items()
        if key not in {"relativeLocation", "location", "version"}
    }


def _profile_manifest_signature(payload: list[dict]) -> list[dict]:
    return [_profile_entry_signature(item) for item in payload if isinstance(item, dict)]


def apply_manifest_repair_plan_safely(plan: ManifestRepairPlan) -> ManifestApplyReport:
    """Apply manifest repairs with rollback if profile selection changes."""
    touched_manifests = {
        decision.manifest_path
        for decision in plan.decisions
        if decision.action != ManifestAction.KEEP
    }
    profile_manifests = {
        decision.manifest_path
        for decision in plan.decisions
        if decision.source_kind == "profile"
    }

    if not touched_manifests:
        return ManifestApplyReport(
            updated_entries=0,
            removed_entries=0,
            touched_manifests=(),
        )

    snapshots = _snapshot_manifest_payloads(touched_manifests | profile_manifests)
    profile_signatures_before = {
        manifest_path: _profile_manifest_signature(payload)
        for manifest_path, payload in snapshots.items()
        if manifest_path in profile_manifests
    }

    try:
        report = apply_manifest_repair_plan(plan)
    except Exception as exc:  # pragma: no cover - defensive rollback path
        _restore_manifest_payloads(snapshots)
        raise ProfileManifestSafetyError(
            "Manifest repair failed; restored manifest snapshot."
        ) from exc

    changed_profiles: list[Path] = []
    for manifest_path, signature_before in profile_signatures_before.items():
        signature_after = _profile_manifest_signature(_load_manifest_payload(manifest_path))
        if signature_after != signature_before:
            changed_profiles.append(manifest_path)

    if changed_profiles:
        _restore_manifest_payloads(snapshots)
        changed_display = ", ".join(str(path) for path in sorted(changed_profiles))
        raise ProfileManifestSafetyError(
            "Profile manifest selection changed during repair; restored snapshot: "
            f"{changed_display}"
        )

    return report
