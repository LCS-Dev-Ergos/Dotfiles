# ============================================================================ #
"""
Top-level VS Code sync workflow helpers.

Orchestrates the full sync lifecycle which consists of two layers:

Non-extension items (settings, keybindings, snippets, MCP config):
    These are plain files or directories symlinked from the Stable user-data
    directory into the Insiders user-data directory. The workflow backs up
    existing targets before replacing them.

Extensions:
    Delegated to `vscode_sync_apply` which handles symlink repair,
    directory migration, and manifest rebinding.

The workflow exposes three entry points:
    - `collect_sync_status`  -- read-only health report
    - `apply_sync_setup`     -- create/update all sync links
    - `apply_sync_remove`    -- restore independent copies and remove links

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import os
import shutil
import sys
import time
from pathlib import Path

from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import canonicalize_path, is_within_directory
from vscode_models import (
    SyncItem,
    SyncItemDecision,
    SyncItemStatus,
    SyncRemoveReport,
    SyncSetupReport,
    SyncStatusReport,
)
from vscode_planner import plan_insiders_symlink_state
from vscode_profiles import plan_manifest_repairs
from vscode_sync_apply import apply_extension_remove, apply_extension_setup

SYNC_ITEM_SPECS = (
    ("Settings", "settings.json"),
    ("Keybindings", "keybindings.json"),
    ("Snippets", "snippets"),
    ("MCP Config", "mcp.json"),
)


def detect_user_dirs(home: str | Path | None = None) -> tuple[Path, Path]:
    """Return the active Stable and Insiders user directories for this HOME."""

    home_path = Path(home or Path.home()).expanduser()
    mac_stable = home_path / "Library/Application Support/Code/User"
    mac_insiders = home_path / "Library/Application Support/Code - Insiders/User"
    linux_stable = home_path / ".config/Code/User"
    linux_insiders = home_path / ".config/Code - Insiders/User"

    if mac_stable.exists() or mac_insiders.exists():
        return mac_stable, mac_insiders
    if linux_stable.exists() or linux_insiders.exists():
        return linux_stable, linux_insiders
    if sys.platform == "darwin":
        return mac_stable, mac_insiders
    return linux_stable, linux_insiders


def build_sync_items(home: str | Path | None = None) -> tuple[SyncItem, ...]:
    """Build the managed non-extension sync items for this HOME."""

    stable_user_dir, insiders_user_dir = detect_user_dirs(home)
    return tuple(
        SyncItem(
            label=label,
            source_path=(stable_user_dir / relative_path).expanduser(),
            target_path=(insiders_user_dir / relative_path).expanduser(),
        )
        for label, relative_path in SYNC_ITEM_SPECS
    )


def evaluate_sync_item(item: SyncItem) -> SyncItemDecision:
    """Return the current sync state for one managed non-extension item."""

    source_exists = item.source_path.exists() or item.source_path.is_symlink()
    if not source_exists:
        return SyncItemDecision(
            label=item.label,
            source_path=item.source_path,
            target_path=item.target_path,
            status=SyncItemStatus.SOURCE_MISSING,
            reason="stable_source_missing",
            source_readable=False,
        )

    source_readable = os.access(item.source_path, os.R_OK)
    if item.target_path.is_symlink():
        link_target = os.readlink(item.target_path)
        if link_target == str(item.source_path):
            if item.target_path.exists():
                return SyncItemDecision(
                    label=item.label,
                    source_path=item.source_path,
                    target_path=item.target_path,
                    status=SyncItemStatus.SYNCED,
                    reason="symlink_matches_stable_source",
                    link_target=link_target,
                    source_readable=source_readable,
                )
            return SyncItemDecision(
                label=item.label,
                source_path=item.source_path,
                target_path=item.target_path,
                status=SyncItemStatus.SYMLINK_BROKEN,
                reason="symlink_matches_source_but_target_is_missing",
                link_target=link_target,
                source_readable=source_readable,
            )
        return SyncItemDecision(
            label=item.label,
            source_path=item.source_path,
            target_path=item.target_path,
            status=SyncItemStatus.SYMLINK_WRONG,
            reason="symlink_points_to_unexpected_target",
            link_target=link_target,
            source_readable=source_readable,
        )

    if item.target_path.exists():
        return SyncItemDecision(
            label=item.label,
            source_path=item.source_path,
            target_path=item.target_path,
            status=SyncItemStatus.INDEPENDENT,
            reason="target_exists_as_independent_path",
            source_readable=source_readable,
        )

    return SyncItemDecision(
        label=item.label,
        source_path=item.source_path,
        target_path=item.target_path,
        status=SyncItemStatus.MISSING,
        reason="target_missing_in_insiders",
        source_readable=source_readable,
    )


def _extension_health_counts(symlink_plan, manifest_plan) -> tuple[int, int]:
    """Return issue and warning counts for extension health."""

    issues = symlink_plan.broken_count + manifest_plan.remove_count
    warnings = (
        symlink_plan.missing_count
        + symlink_plan.wrong_target_count
        + symlink_plan.unmanaged_count
        + symlink_plan.excluded_symlinked_count
        + symlink_plan.stale_managed_count
        + manifest_plan.preserved_missing_profile_count
    )
    return issues, warnings


def _item_health_counts(
    item_decisions: tuple[SyncItemDecision, ...],
) -> tuple[int, int]:
    """Return issue and warning counts for non-extension sync items."""

    issues = 0
    warnings = 0
    for decision in item_decisions:
        if decision.status in {
            SyncItemStatus.SOURCE_MISSING,
            SyncItemStatus.SYMLINK_BROKEN,
        }:
            issues += 1
        if decision.status == SyncItemStatus.SYMLINK_WRONG:
            warnings += 1
        if decision.status != SyncItemStatus.SOURCE_MISSING and not decision.source_readable:
            warnings += 1
    return issues, warnings


def collect_sync_status(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    home: str | Path | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> SyncStatusReport:
    """Collect the top-level sync status for items plus extensions."""

    config = VscodePathsConfig.from_home(home)
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)
    item_decisions = tuple(evaluate_sync_item(item) for item in build_sync_items(config.home))
    symlink_plan = plan_insiders_symlink_state(
        stable_dir,
        insiders_dir,
        exclude_patterns=resolved_patterns,
    )
    manifest_plan = plan_manifest_repairs(
        stable_dir,
        insiders_dir,
        config=config,
        exclude_patterns=resolved_patterns,
    )
    item_issues, item_warnings = _item_health_counts(item_decisions)
    ext_issues, ext_warnings = _extension_health_counts(symlink_plan, manifest_plan)
    return SyncStatusReport(
        items=item_decisions,
        symlink_plan=symlink_plan,
        manifest_plan=manifest_plan,
        issues=item_issues + ext_issues,
        warnings=item_warnings + ext_warnings,
    )


def _safe_remove_existing(path: Path, *, home: Path) -> None:
    """Remove an existing path only when it stays within HOME."""

    if not is_within_directory(path, home):
        raise ValueError(f"path outside HOME: {path}")
    if path.is_symlink() or path.exists():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def _copy_path(source: Path, destination: Path) -> None:
    """Copy a file or directory to a destination path."""

    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir() and not source.is_symlink():
        shutil.copytree(source, destination, symlinks=True)
        return
    shutil.copy2(source, destination, follow_symlinks=True)


def _make_backup_root(home: Path) -> Path:
    """Create and return a dedicated backup directory for one apply run."""

    backup_parent = canonicalize_path(home / ".local/share/vscode-sync-backups")
    backup_parent.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    for attempt in range(20):
        candidate = backup_parent / f"{timestamp}_{os.getpid()}_{attempt}_sync-items"
        try:
            candidate.mkdir(mode=0o700)
            return candidate
        except FileExistsError:
            continue
    raise RuntimeError("failed to create sync backup directory")


def _backup_target_if_needed(target: Path, label: str, *, backup_root: Path) -> None:
    """Back up an existing target before replacing it."""

    if not target.exists():
        return
    safe_label = "".join(char for char in label.replace(" ", "_") if char.isalnum() or char in "_-")
    backup_path = backup_root / safe_label
    _copy_path(target, backup_path)


def apply_sync_setup(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    home: str | Path | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> SyncSetupReport:
    """Apply the top-level sync setup workflow for items and extensions."""

    config = VscodePathsConfig.from_home(home)
    home_path = config.home
    backup_root = _make_backup_root(home_path)
    item_reports: list[SyncItemDecision] = []
    synced_count = 0
    skipped_count = 0
    failed_count = 0

    for item in build_sync_items(home_path):
        decision = evaluate_sync_item(item)
        if decision.status == SyncItemStatus.SYNCED:
            item_reports.append(decision)
            synced_count += 1
            continue
        if decision.status == SyncItemStatus.SOURCE_MISSING:
            item_reports.append(decision)
            skipped_count += 1
            continue

        try:
            if not is_within_directory(item.target_path, home_path):
                raise ValueError("target_path_outside_home")
            _backup_target_if_needed(item.target_path, item.label, backup_root=backup_root)
            _safe_remove_existing(item.target_path, home=home_path)
            item.target_path.parent.mkdir(parents=True, exist_ok=True)
            item.target_path.symlink_to(item.source_path)
            item_reports.append(
                SyncItemDecision(
                    label=item.label,
                    source_path=item.source_path,
                    target_path=item.target_path,
                    status=SyncItemStatus.SYNCED,
                    reason="symlink_created",
                    link_target=str(item.source_path),
                    source_readable=decision.source_readable,
                )
            )
            synced_count += 1
        except (OSError, RuntimeError, ValueError):
            item_reports.append(
                SyncItemDecision(
                    label=item.label,
                    source_path=item.source_path,
                    target_path=item.target_path,
                    status=decision.status,
                    reason="setup_apply_failed",
                    link_target=decision.link_target,
                    source_readable=decision.source_readable,
                )
            )
            failed_count += 1

    extension_report = apply_extension_setup(
        stable_dir,
        insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    return SyncSetupReport(
        item_reports=tuple(item_reports),
        synced_count=synced_count,
        skipped_count=skipped_count,
        failed_count=failed_count,
        extension_report=extension_report,
    )


def apply_sync_remove(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    home: str | Path | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> SyncRemoveReport:
    """Apply the top-level sync removal workflow for items and extensions."""

    config = VscodePathsConfig.from_home(home)
    home_path = config.home
    item_reports: list[SyncItemDecision] = []
    restored_count = 0
    removed_broken_count = 0
    skipped_count = 0
    failed_count = 0

    for item in build_sync_items(home_path):
        decision = evaluate_sync_item(item)
        if not item.target_path.is_symlink():
            item_reports.append(decision)
            skipped_count += 1
            continue

        try:
            if item.target_path.exists():
                temp_target = item.target_path.with_name(
                    f"{item.target_path.name}.vscode_sync_tmp.{os.getpid()}"
                )
                _copy_path(item.source_path, temp_target)
                _safe_remove_existing(item.target_path, home=home_path)
                shutil.move(str(temp_target), str(item.target_path))
                item_reports.append(
                    SyncItemDecision(
                        label=item.label,
                        source_path=item.source_path,
                        target_path=item.target_path,
                        status=SyncItemStatus.INDEPENDENT,
                        reason="restored_independent_copy",
                        source_readable=decision.source_readable,
                    )
                )
                restored_count += 1
                continue

            _safe_remove_existing(item.target_path, home=home_path)
            item_reports.append(
                SyncItemDecision(
                    label=item.label,
                    source_path=item.source_path,
                    target_path=item.target_path,
                    status=SyncItemStatus.MISSING,
                    reason="removed_broken_symlink",
                    source_readable=decision.source_readable,
                )
            )
            removed_broken_count += 1
        except (OSError, ValueError):
            item_reports.append(
                SyncItemDecision(
                    label=item.label,
                    source_path=item.source_path,
                    target_path=item.target_path,
                    status=decision.status,
                    reason="remove_apply_failed",
                    link_target=decision.link_target,
                    source_readable=decision.source_readable,
                )
            )
            failed_count += 1

    extension_report = apply_extension_remove(
        stable_dir,
        insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    return SyncRemoveReport(
        item_reports=tuple(item_reports),
        restored_count=restored_count,
        removed_broken_count=removed_broken_count,
        skipped_count=skipped_count,
        failed_count=failed_count,
        extension_report=extension_report,
    )
