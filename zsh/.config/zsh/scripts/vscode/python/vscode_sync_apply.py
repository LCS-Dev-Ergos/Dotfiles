# ============================================================================ #
"""
Apply helpers for the non-destructive Stable-to-Insiders sync workflow.

`apply_extension_setup` repairs the Insiders extension tree so that every
shared extension appears as a symlink pointing into the Stable root.  The
function handles:

1. Missing links: Creates new symlinks for Stable extensions not yet
   linked into Insiders.
2. Broken / wrong-target links: Removes and recreates symlinks that
   no longer resolve to the expected Stable target.
3. Unmanaged real directories: Migrates Insiders-only installs into the
   Stable root and replaces them with symlinks, keeping the folder accessible
   from both editions.
4. Stale managed symlinks: Removes symlinks whose Stable source has been
   deleted or excluded from sync management.
5. Manifest rebinding: After symlink repair, updates manifests through the
   safe sync repair pipeline while keeping profile selection conservative.

All mutations are guarded by canonical path-location checks to prevent
path-traversal attacks on the managed extension directories.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import os
import shutil
import time
from pathlib import Path
from typing import Callable

from vscode_backups import default_backup_root, prune_backup_directories
from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import (
    canonicalize_path,
    is_path_location_within_directory,
    is_within_directory,
)
from vscode_models import (
    ExtensionRemoveReport,
    ExtensionSetupReport,
    SymlinkAction,
)
from vscode_planner import plan_insiders_symlink_state
from vscode_profiles import (
    apply_manifest_repair_plan_safely,
    build_safe_sync_manifest_plan,
    plan_manifest_repairs,
)

_MAX_RESTORE_STAGING_ATTEMPTS = 10000


class ExtensionMutationError(RuntimeError):
    """Raised when extension-tree reconciliation cannot complete safely."""


def _safe_remove_path(path: Path, *, root: Path) -> bool:
    """Remove a path only when it stays inside the managed root."""

    if not is_path_location_within_directory(path, root):
        return False
    if path.is_symlink() or path.exists():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    return True


def _safe_create_symlink(*, link_path: Path, target_path: Path, root: Path) -> bool:
    """Create or replace a symlink only when the link lives inside the managed root."""

    if not is_path_location_within_directory(link_path, root):
        return False
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.is_symlink() or link_path.exists():
        _safe_remove_path(link_path, root=root)
    link_path.symlink_to(target_path)
    return True


def _cleanup_path_unchecked(path: Path) -> None:
    """Remove a path without containment checks; used only for local staging paths."""

    if path.is_symlink() or path.exists():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def _unique_transaction_backup_root(root: Path) -> Path:
    """Allocate a hidden sibling directory for rollback backups."""

    for attempt in range(1, _MAX_RESTORE_STAGING_ATTEMPTS + 1):
        candidate = root.parent / f".{root.name}.vscode_sync_tx.{os.getpid()}.{attempt}"
        if not candidate.exists() and not candidate.is_symlink():
            candidate.mkdir(parents=True, exist_ok=False)
            return candidate
    raise RuntimeError("failed to allocate an extension transaction backup root")


def _unique_restore_staging_path(path: Path) -> Path:
    """Allocate a unique sibling path for a temporary restore staging area."""

    for attempt in range(1, _MAX_RESTORE_STAGING_ATTEMPTS + 1):
        candidate = (
            path.parent / f".{path.name}.vscode_sync_restore.{os.getpid()}.{attempt}"
        )
        if not candidate.exists() and not candidate.is_symlink():
            return candidate
    raise RuntimeError("failed to allocate an extension restore staging path")


class _ExtensionMutationTransaction:
    """Track reversible extension-tree mutations within one setup apply run."""

    def __init__(self, *, preserve_home: Path | None = None) -> None:
        self._rollback_actions: list[Callable[[], None]] = []
        self._backup_roots: dict[Path, Path] = {}
        self._preserve_home = preserve_home

    def _backup_root_for(self, root: Path) -> Path:
        """Return the dedicated rollback backup root for one managed tree."""

        backup_root = self._backup_roots.get(root)
        if backup_root is None:
            backup_root = _unique_transaction_backup_root(root)
            self._backup_roots[root] = backup_root
        return backup_root

    def _backup_path_for(self, path: Path, *, root: Path) -> Path:
        """Return a unique rollback backup path for one managed entry."""

        backup_root = self._backup_root_for(root)
        for attempt in range(1, _MAX_RESTORE_STAGING_ATTEMPTS + 1):
            candidate = backup_root / f"{path.name}.{attempt}"
            if not candidate.exists() and not candidate.is_symlink():
                return candidate
        raise RuntimeError("failed to allocate an extension transaction backup path")

    def capture_existing_path(self, path: Path, *, root: Path) -> bool:
        """Move an existing managed path into rollback storage and record its restoration."""

        if not is_path_location_within_directory(path, root):
            raise ExtensionMutationError(
                f"path escaped managed root during setup: {path}"
            )
        if not (path.exists() or path.is_symlink()):
            return False

        backup_path = self._backup_path_for(path, root=root)
        shutil.move(str(path), str(backup_path))
        self._rollback_actions.append(
            lambda path=path, backup_path=backup_path, root=root: (
                self._restore_backup_path(
                    path,
                    backup_path,
                    root=root,
                )
            )
        )
        return True

    def record_created_path(self, path: Path, *, root: Path) -> None:
        """Record that a new managed path should be removed during rollback."""

        self._rollback_actions.append(
            lambda path=path, root=root: self._remove_created_path(path, root=root)
        )

    def record_move(
        self,
        *,
        source_path: Path,
        destination_path: Path,
        source_root: Path,
        destination_root: Path,
    ) -> None:
        """Record a reversible move between the managed Stable and Insiders trees."""

        self._rollback_actions.append(
            lambda source_path=source_path, destination_path=destination_path, source_root=source_root, destination_root=destination_root: (
                self._restore_moved_path(
                    source_path,
                    destination_path,
                    source_root=source_root,
                    destination_root=destination_root,
                )
            )
        )

    def rollback(self) -> tuple[str, ...]:
        """Best-effort rollback of all recorded mutations."""

        failures: list[str] = []
        for action in reversed(self._rollback_actions):
            try:
                action()
            except (OSError, RuntimeError, ValueError) as exc:
                failures.append(str(exc))

        for backup_root in self._backup_roots.values():
            try:
                _cleanup_path_unchecked(backup_root)
            except OSError as exc:
                failures.append(str(exc))
        return tuple(failures)

    def commit(self) -> None:
        """Preserve or discard rollback backups after a successful apply.

        Captured entries can hold user content (for example a divergent
        Insiders directory replaced by a shared symlink), so non-empty backup
        roots are moved into the shared backup location under retention
        instead of being deleted outright.
        """

        for backup_root in self._backup_roots.values():
            try:
                if self._preserve_home is not None and any(backup_root.iterdir()):
                    self._preserve_backup_root(backup_root)
                else:
                    _cleanup_path_unchecked(backup_root)
            except OSError:
                continue

    def _preserve_backup_root(self, backup_root: Path) -> None:
        """Move one non-empty rollback backup root into the shared backup dir."""

        backup_parent = default_backup_root(self._preserve_home)
        backup_parent.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        for attempt in range(1, _MAX_RESTORE_STAGING_ATTEMPTS + 1):
            candidate = (
                backup_parent / f"{timestamp}_{os.getpid()}_{attempt}_setup-replaced"
            )
            if candidate.exists() or candidate.is_symlink():
                continue
            shutil.move(str(backup_root), str(candidate))
            prune_backup_directories(backup_parent)
            return
        raise OSError("failed to allocate a setup-replaced backup directory")

    @staticmethod
    def _restore_backup_path(path: Path, backup_path: Path, *, root: Path) -> None:
        """Restore a captured pre-mutation path."""

        if not is_path_location_within_directory(path, root):
            raise ValueError(f"path escaped managed root during rollback: {path}")
        if path.exists() or path.is_symlink():
            if not _safe_remove_path(path, root=root):
                raise RuntimeError(
                    f"failed to clear path before rollback restore: {path}"
                )
        if backup_path.exists() or backup_path.is_symlink():
            shutil.move(str(backup_path), str(path))

    @staticmethod
    def _remove_created_path(path: Path, *, root: Path) -> None:
        """Remove a path that was created during the failed apply run."""

        if path.exists() or path.is_symlink():
            if not _safe_remove_path(path, root=root):
                raise RuntimeError(
                    f"failed to remove created path during rollback: {path}"
                )

    @staticmethod
    def _restore_moved_path(
        source_path: Path,
        destination_path: Path,
        *,
        source_root: Path,
        destination_root: Path,
    ) -> None:
        """Move a previously migrated directory back to its original managed root."""

        if not is_path_location_within_directory(source_path, source_root):
            raise ValueError(
                f"source path escaped managed root during rollback: {source_path}"
            )
        if not is_path_location_within_directory(destination_path, destination_root):
            raise ValueError(
                f"destination path escaped managed root during rollback: {destination_path}"
            )
        if source_path.exists() or source_path.is_symlink():
            if not _safe_remove_path(source_path, root=source_root):
                raise RuntimeError(
                    f"failed to clear source path during rollback: {source_path}"
                )
        if destination_path.exists() or destination_path.is_symlink():
            shutil.move(str(destination_path), str(source_path))


def _create_managed_symlink_or_raise(
    *, link_path: Path, target_path: Path, root: Path
) -> None:
    """Create a managed symlink or raise when the operation cannot complete safely."""

    if not target_path.is_dir():
        raise ExtensionMutationError(
            f"expected Stable extension target is missing: {target_path}"
        )
    try:
        created = _safe_create_symlink(
            link_path=link_path, target_path=target_path, root=root
        )
    except OSError as exc:
        raise ExtensionMutationError(
            f"failed to create managed symlink: {link_path}"
        ) from exc
    if not created:
        raise ExtensionMutationError(
            f"refusing to create symlink outside managed root: {link_path}"
        )


def _move_managed_path_or_raise(
    *,
    source_path: Path,
    destination_path: Path,
    source_root: Path,
    destination_root: Path,
) -> None:
    """Move a managed path between roots or raise if the move is unsafe."""

    if not is_path_location_within_directory(source_path, source_root):
        raise ExtensionMutationError(
            f"source path escaped managed root during setup: {source_path}"
        )
    if not is_path_location_within_directory(destination_path, destination_root):
        raise ExtensionMutationError(
            f"destination path escaped managed root during setup: {destination_path}"
        )
    if not (source_path.exists() or source_path.is_symlink()):
        raise ExtensionMutationError(
            f"managed source path disappeared during setup: {source_path}"
        )
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.move(str(source_path), str(destination_path))
    except OSError as exc:
        raise ExtensionMutationError(
            f"failed to move managed path into the Stable root: {source_path}"
        ) from exc


def _restore_directory_copy_or_raise(
    *,
    destination_path: Path,
    source_path: Path,
    destination_root: Path,
    source_root: Path,
    transaction: _ExtensionMutationTransaction,
) -> None:
    """Replace a managed path with an independent copy and record rollback state."""

    if not is_path_location_within_directory(destination_path, destination_root):
        raise ExtensionMutationError(
            f"destination path escaped managed root during restore: {destination_path}"
        )

    canonical_source = canonicalize_path(source_path)
    if not is_path_location_within_directory(canonical_source, source_root):
        raise ExtensionMutationError(
            f"source path escaped managed root during restore: {source_path}"
        )
    if not canonical_source.exists() or not canonical_source.is_dir():
        raise ExtensionMutationError(
            f"restore source is missing or not a directory: {source_path}"
        )

    destination_path.parent.mkdir(parents=True, exist_ok=True)
    stage_path = _unique_restore_staging_path(destination_path)
    try:
        shutil.copytree(canonical_source, stage_path, symlinks=True)
        had_original = transaction.capture_existing_path(
            destination_path, root=destination_root
        )
        shutil.move(str(stage_path), str(destination_path))
    except (OSError, RuntimeError) as exc:
        _cleanup_path_unchecked(stage_path)
        raise ExtensionMutationError(
            f"failed to restore an independent extension copy at {destination_path}"
        ) from exc

    if not had_original:
        transaction.record_created_path(destination_path, root=destination_root)


def _safe_restore_directory_copy(
    *,
    destination_path: Path,
    source_path: Path,
    destination_root: Path,
    source_root: Path,
) -> bool:
    """Replace a managed symlink with an independent directory copied from a safe source."""

    if not is_path_location_within_directory(destination_path, destination_root):
        return False

    canonical_source = canonicalize_path(source_path)
    if not is_path_location_within_directory(canonical_source, source_root):
        return False
    if not canonical_source.exists() or not canonical_source.is_dir():
        return False

    destination_path.parent.mkdir(parents=True, exist_ok=True)
    stage_path = _unique_restore_staging_path(destination_path)

    try:
        shutil.copytree(canonical_source, stage_path, symlinks=True)
    except OSError:
        _cleanup_path_unchecked(stage_path)
        return False

    # Allocated after the stage exists so the two paths can never collide;
    # a collision would nest the displaced original inside the restored copy.
    backup_path = _unique_restore_staging_path(destination_path)

    had_original = destination_path.is_symlink() or destination_path.exists()
    try:
        if had_original:
            shutil.move(str(destination_path), str(backup_path))
        shutil.move(str(stage_path), str(destination_path))
    except OSError:
        _cleanup_path_unchecked(stage_path)
        if destination_path.exists() or destination_path.is_symlink():
            _cleanup_path_unchecked(destination_path)
        if had_original and (backup_path.exists() or backup_path.is_symlink()):
            try:
                shutil.move(str(backup_path), str(destination_path))
            except OSError:
                pass
        return False

    _cleanup_path_unchecked(backup_path)
    return True


def apply_extension_setup(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> ExtensionSetupReport:
    """Apply symlink repair, excluded-copy restore, and safe manifest rebinds."""

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
    restored_excluded_copy_count = 0
    skipped_excluded_symlink_count = 0

    stable_root.mkdir(parents=True, exist_ok=True)
    insiders_root.mkdir(parents=True, exist_ok=True)

    transaction = _ExtensionMutationTransaction(preserve_home=resolved_config.home)
    try:
        for decision in plan.decisions:
            path = Path(decision.path).expanduser()
            expected_target = canonicalize_path(stable_root / decision.folder_name)

            if decision.action == SymlinkAction.LINKED:
                continue

            if decision.action == SymlinkAction.MISSING:
                if expected_target.is_dir():
                    _create_managed_symlink_or_raise(
                        link_path=path,
                        target_path=expected_target,
                        root=insiders_root,
                    )
                    transaction.record_created_path(path, root=insiders_root)
                    linked_count += 1
                continue

            if decision.action in {SymlinkAction.BROKEN, SymlinkAction.WRONG_TARGET}:
                had_original = transaction.capture_existing_path(
                    path, root=insiders_root
                )
                _create_managed_symlink_or_raise(
                    link_path=path,
                    target_path=expected_target,
                    root=insiders_root,
                )
                if not had_original:
                    transaction.record_created_path(path, root=insiders_root)
                relinked_count += 1
                continue

            if decision.action == SymlinkAction.UNMANAGED_REAL_DIR:
                stable_target = expected_target
                if stable_target.exists():
                    transaction.capture_existing_path(path, root=insiders_root)
                else:
                    _move_managed_path_or_raise(
                        source_path=path,
                        destination_path=stable_target,
                        source_root=insiders_root,
                        destination_root=stable_root,
                    )
                    transaction.record_move(
                        source_path=path,
                        destination_path=stable_target,
                        source_root=insiders_root,
                        destination_root=stable_root,
                    )
                    migrated_count += 1
                _create_managed_symlink_or_raise(
                    link_path=path,
                    target_path=stable_target,
                    root=insiders_root,
                )
                transaction.record_created_path(path, root=insiders_root)
                linked_count += 1
                continue

            if decision.action == SymlinkAction.STALE_MANAGED_SYMLINK:
                if path.exists() or path.is_symlink():
                    transaction.capture_existing_path(path, root=insiders_root)
                    removed_stale_symlink_count += 1
                continue

            if decision.action == SymlinkAction.EXCLUDED_BUT_SYMLINKED:
                try:
                    _restore_directory_copy_or_raise(
                        destination_path=path,
                        source_path=expected_target,
                        destination_root=insiders_root,
                        source_root=stable_root,
                        transaction=transaction,
                    )
                    restored_excluded_copy_count += 1
                except ExtensionMutationError:
                    skipped_excluded_symlink_count += 1
                continue

        manifest_plan = build_safe_sync_manifest_plan(
            plan_manifest_repairs(
                stable_root,
                insiders_root,
                config=resolved_config,
                exclude_patterns=resolved_patterns,
            )
        )
        manifest_apply_report = apply_manifest_repair_plan_safely(manifest_plan)
    except Exception as exc:
        rollback_failures = transaction.rollback()
        if rollback_failures:
            raise ExtensionMutationError(
                "extension setup failed and rollback was incomplete: "
                + "; ".join(rollback_failures)
            ) from exc
        raise
    else:
        transaction.commit()

    return ExtensionSetupReport(
        linked_count=linked_count,
        relinked_count=relinked_count,
        migrated_count=migrated_count,
        removed_stale_symlink_count=removed_stale_symlink_count,
        restored_excluded_copy_count=restored_excluded_copy_count,
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
    """Restore independent Insiders extension directories from the Stable source of truth."""

    del config, exclude_patterns

    stable_root = canonicalize_path(stable_dir)
    insiders_root = Path(insiders_dir).expanduser()
    canonical_insiders_root = canonicalize_path(insiders_root)
    failed_paths: list[Path] = []
    restored_root_copy_count = 0
    restored_entry_copy_count = 0
    removed_broken_symlink_count = 0
    skipped_real_dir_count = 0
    skipped_foreign_symlink_count = 0

    if insiders_root.is_symlink():
        if _safe_restore_directory_copy(
            destination_path=insiders_root,
            source_path=stable_root,
            destination_root=insiders_root.parent,
            source_root=stable_root.parent,
        ):
            restored_root_copy_count = 1
        elif _safe_remove_path(insiders_root, root=insiders_root.parent):
            removed_broken_symlink_count = 1
        else:
            failed_paths.append(insiders_root)
        return ExtensionRemoveReport(
            restored_root_copy_count=restored_root_copy_count,
            restored_entry_copy_count=restored_entry_copy_count,
            removed_broken_symlink_count=removed_broken_symlink_count,
            skipped_real_dir_count=skipped_real_dir_count,
            failed_paths=tuple(failed_paths),
        )

    if not canonical_insiders_root.exists() or not canonical_insiders_root.is_dir():
        return ExtensionRemoveReport(
            restored_root_copy_count=0,
            restored_entry_copy_count=0,
            removed_broken_symlink_count=0,
            skipped_real_dir_count=0,
            failed_paths=(),
        )

    for entry in sorted(
        canonical_insiders_root.iterdir(), key=lambda candidate: candidate.name
    ):
        if entry.is_symlink():
            source_path = canonicalize_path(stable_root / entry.name)
            if _safe_restore_directory_copy(
                destination_path=entry,
                source_path=source_path,
                destination_root=canonical_insiders_root,
                source_root=stable_root,
            ):
                restored_entry_copy_count += 1
            elif not is_within_directory(canonicalize_path(entry), stable_root):
                # A link that never pointed into the Stable root is not
                # managed by this workflow; leave it alone.
                skipped_foreign_symlink_count += 1
            elif _safe_remove_path(entry, root=canonical_insiders_root):
                removed_broken_symlink_count += 1
            else:
                failed_paths.append(entry)
            continue

        if entry.is_dir():
            skipped_real_dir_count += 1

    return ExtensionRemoveReport(
        restored_root_copy_count=restored_root_copy_count,
        restored_entry_copy_count=restored_entry_copy_count,
        removed_broken_symlink_count=removed_broken_symlink_count,
        skipped_real_dir_count=skipped_real_dir_count,
        failed_paths=tuple(failed_paths),
        skipped_foreign_symlink_count=skipped_foreign_symlink_count,
    )
