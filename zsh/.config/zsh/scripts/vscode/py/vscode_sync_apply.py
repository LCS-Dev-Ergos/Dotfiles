# ============================================================================ #
"""
Apply helpers for the non-destructive Stable-to-Insiders sync workflow.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import shutil
from pathlib import Path

from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import canonicalize_path
from vscode_models import (
    ExtensionRemoveReport,
    ExtensionSetupReport,
    SymlinkAction,
)
from vscode_planner import plan_insiders_symlink_state
from vscode_profiles import (
    apply_manifest_repair_plan_safely,
    build_update_only_manifest_plan,
    plan_manifest_repairs,
)


def _is_lexically_within_root(path: Path, root: Path) -> bool:
    """Return ``True`` when ``path`` is lexically contained inside ``root``."""
    path = path.expanduser()
    root = root.expanduser()
    return path == root or root in path.parents


def _safe_remove_path(path: Path, *, root: Path) -> bool:
    """Remove a path only when it stays inside the managed root."""
    if not _is_lexically_within_root(path, root):
        return False
    if path.is_symlink() or path.exists():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    return True


def _safe_create_symlink(*, link_path: Path, target_path: Path, root: Path) -> bool:
    """Create or replace a symlink only when the link lives inside the managed root."""
    if not _is_lexically_within_root(link_path, root):
        return False
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.is_symlink() or link_path.exists():
        _safe_remove_path(link_path, root=root)
    link_path.symlink_to(target_path)
    return True


def apply_extension_setup(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> ExtensionSetupReport:
    """Apply symlink repair, managed directory migration, and update-only manifest rebinds."""
    resolved_config = config or VscodePathsConfig.from_home()
    stable_root = canonicalize_path(stable_dir)
    insiders_root = canonicalize_path(insiders_dir)
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)
    plan = plan_insiders_symlink_state(
        stable_root,
        insiders_root,
        exclude_patterns=resolved_patterns,
    )

    linked_count = 0
    relinked_count = 0
    migrated_count = 0
    removed_stale_symlink_count = 0
    skipped_excluded_symlink_count = 0

    stable_root.mkdir(parents=True, exist_ok=True)
    insiders_root.mkdir(parents=True, exist_ok=True)

    for decision in plan.decisions:
        path = Path(decision.path).expanduser()
        expected_target = canonicalize_path(stable_root / decision.folder_name)

        if decision.action == SymlinkAction.LINKED:
            continue

        if decision.action == SymlinkAction.MISSING:
            if expected_target.is_dir():
                _safe_create_symlink(link_path=path, target_path=expected_target, root=insiders_root)
                linked_count += 1
            continue

        if decision.action in {SymlinkAction.BROKEN, SymlinkAction.WRONG_TARGET}:
            if path.exists() or path.is_symlink():
                _safe_remove_path(path, root=insiders_root)
            if expected_target.is_dir():
                _safe_create_symlink(link_path=path, target_path=expected_target, root=insiders_root)
                relinked_count += 1
            continue

        if decision.action == SymlinkAction.UNMANAGED_REAL_DIR:
            stable_target = expected_target
            if not _is_lexically_within_root(stable_target, stable_root):
                continue

            stable_target.parent.mkdir(parents=True, exist_ok=True)
            if stable_target.exists():
                _safe_remove_path(path, root=insiders_root)
            else:
                shutil.move(str(path), str(stable_target))
                migrated_count += 1
            _safe_create_symlink(link_path=path, target_path=stable_target, root=insiders_root)
            if stable_target.exists():
                linked_count += 1
            continue

        if decision.action == SymlinkAction.STALE_MANAGED_SYMLINK:
            if path.exists() or path.is_symlink():
                _safe_remove_path(path, root=insiders_root)
                removed_stale_symlink_count += 1
            continue

        if decision.action == SymlinkAction.EXCLUDED_BUT_SYMLINKED:
            skipped_excluded_symlink_count += 1
            continue

    manifest_plan = build_update_only_manifest_plan(
        plan_manifest_repairs(
            stable_root,
            insiders_root,
            config=resolved_config,
            exclude_patterns=resolved_patterns,
        )
    )
    manifest_apply_report = apply_manifest_repair_plan_safely(manifest_plan)

    return ExtensionSetupReport(
        linked_count=linked_count,
        relinked_count=relinked_count,
        migrated_count=migrated_count,
        removed_stale_symlink_count=removed_stale_symlink_count,
        skipped_excluded_symlink_count=skipped_excluded_symlink_count,
        manifest_apply_report=manifest_apply_report,
    )


def apply_extension_remove(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> ExtensionRemoveReport:
    """Remove sync-managed extension symlinks from the Insiders root."""
    del stable_dir, config, exclude_patterns

    insiders_root = Path(insiders_dir).expanduser()
    canonical_insiders_root = canonicalize_path(insiders_root)
    failed_paths: list[Path] = []
    removed_root_symlink_count = 0
    removed_entry_symlink_count = 0
    skipped_real_dir_count = 0

    if insiders_root.is_symlink():
        if _safe_remove_path(insiders_root, root=insiders_root.parent):
            removed_root_symlink_count = 1
        else:
            failed_paths.append(insiders_root)
        return ExtensionRemoveReport(
            removed_root_symlink_count=removed_root_symlink_count,
            removed_entry_symlink_count=removed_entry_symlink_count,
            skipped_real_dir_count=skipped_real_dir_count,
            failed_paths=tuple(failed_paths),
        )

    if not canonical_insiders_root.exists() or not canonical_insiders_root.is_dir():
        return ExtensionRemoveReport(
            removed_root_symlink_count=0,
            removed_entry_symlink_count=0,
            skipped_real_dir_count=0,
            failed_paths=(),
        )

    for entry in sorted(canonical_insiders_root.iterdir(), key=lambda candidate: candidate.name):
        if entry.is_symlink():
            if _safe_remove_path(entry, root=canonical_insiders_root):
                removed_entry_symlink_count += 1
            else:
                failed_paths.append(entry)
            continue

        if entry.is_dir():
            skipped_real_dir_count += 1

    return ExtensionRemoveReport(
        removed_root_symlink_count=removed_root_symlink_count,
        removed_entry_symlink_count=removed_entry_symlink_count,
        skipped_real_dir_count=skipped_real_dir_count,
        failed_paths=tuple(failed_paths),
    )
