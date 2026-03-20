# ============================================================================ #
"""
Cleanup application helpers for duplicate VS Code extension installs.

Author: XtremeXSPC
Version:
"""
# ============================================================================ #

from __future__ import annotations

import os
import shutil
from datetime import datetime
from pathlib import Path

from vscode_fs import canonicalize_path, is_within_directory
from vscode_models import CleanupAction, CleanupApplyReport, CleanupPlan


def deletable_paths_from_plan(plan: CleanupPlan) -> tuple[Path, ...]:
    """Return the unique, sorted set of paths selected for quarantine."""
    paths = {
        canonicalize_path(decision.path)
        for group in plan.groups
        for decision in group.decisions
        if decision.action == CleanupAction.DELETE
    }
    return tuple(sorted(paths))


def _cleanup_backup_roots(root: Path) -> tuple[Path, ...]:
    """Return the candidate backup roots that can host cleanup quarantine data."""
    env_root = os.environ.get("VSCODE_SYNC_BACKUP_DIR")
    candidates: list[Path] = []
    if env_root:
        candidates.append(Path(env_root).expanduser())
    candidates.append(Path.home() / ".local/share/vscode-sync-backups")
    candidates.append(root.parent / ".vscode-sync-backups")
    return tuple(candidates)


def _cleanup_quarantine_root(root: Path) -> Path:
    """Create and return a unique quarantine directory for a cleanup run."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    suffix = f"{timestamp}_{os.getpid()}_extension-cleaner-quarantine"
    root_fragment = str(root).replace(str(Path.home()), "HOME").strip("/").replace("/", "__")
    if not root_fragment:
        root_fragment = "extensions"

    for backup_root in _cleanup_backup_roots(root):
        quarantine_root = backup_root / suffix / root_fragment
        try:
            quarantine_root.mkdir(parents=True, exist_ok=True)
        except OSError:
            continue
        return quarantine_root

    raise OSError("unable to create an extension cleanup quarantine directory")


def _unique_quarantine_target(quarantine_root: Path, source_path: Path) -> Path:
    """Return a unique destination path inside the quarantine directory."""
    candidate = quarantine_root / source_path.name
    if not candidate.exists():
        return candidate

    attempt = 1
    while True:
        candidate = quarantine_root / f"{source_path.name}.{attempt}"
        if not candidate.exists():
            return candidate
        attempt += 1


def apply_cleanup_plan(plan: CleanupPlan) -> CleanupApplyReport:
    """Apply a cleanup plan by moving selected directories into quarantine."""
    root = canonicalize_path(plan.root)
    quarantine_root = _cleanup_quarantine_root(root)

    quarantined_paths: list[Path] = []
    failed_paths: list[Path] = []

    for path in deletable_paths_from_plan(plan):
        if not is_within_directory(path, root):
            failed_paths.append(path)
            continue
        if not path.exists():
            continue
        if not path.is_dir():
            failed_paths.append(path)
            continue

        try:
            destination = _unique_quarantine_target(quarantine_root, path)
            shutil.move(str(path), str(destination))
        except OSError:
            failed_paths.append(path)
            continue

        quarantined_paths.append(destination)

    return CleanupApplyReport(
        root=root,
        quarantine_root=quarantine_root,
        quarantined_paths=tuple(quarantined_paths),
        failed_paths=tuple(failed_paths),
    )
