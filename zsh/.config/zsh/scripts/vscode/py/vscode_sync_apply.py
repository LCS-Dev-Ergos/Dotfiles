from __future__ import annotations

import shutil
from pathlib import Path

from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import canonicalize_path
from vscode_models import ExtensionSetupReport, ManifestApplyReport, SymlinkAction
from vscode_planner import plan_insiders_symlink_state


def _is_lexically_within_root(path: Path, root: Path) -> bool:
    path = path.expanduser()
    root = root.expanduser()
    return path == root or root in path.parents


def _safe_remove_path(path: Path, *, root: Path) -> bool:
    if not _is_lexically_within_root(path, root):
        return False
    if path.is_symlink() or path.exists():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    return True


def _safe_create_symlink(*, link_path: Path, target_path: Path, root: Path) -> bool:
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
    """Apply symlink repair and managed directory migration.

    Profile manifests are intentionally treated as read-only by the normal
    setup workflow. VS Code and Settings Sync mutate them independently, so the
    safe default is to leave them untouched until a dedicated compatibility
    layer can satisfy their requested folder names.
    """
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

    return ExtensionSetupReport(
        linked_count=linked_count,
        relinked_count=relinked_count,
        migrated_count=migrated_count,
        removed_stale_symlink_count=removed_stale_symlink_count,
        skipped_excluded_symlink_count=skipped_excluded_symlink_count,
        manifest_apply_report=ManifestApplyReport(
            updated_entries=0,
            removed_entries=0,
            touched_manifests=(),
        ),
    )
