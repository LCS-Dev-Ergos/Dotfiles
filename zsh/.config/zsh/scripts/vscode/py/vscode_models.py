# ============================================================================ #
"""
Shared data models used by the VS Code sync Python backend.

Author: XtremeXSPC
Version:
"""
# ============================================================================ #

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path


class VscodeEdition(StrEnum):
    """Identify which VS Code channel owns an extension root."""

    LOCAL = "local"
    STABLE = "stable"
    INSIDERS = "insiders"


class CleanupStrategy(StrEnum):
    """Enumerate the duplicate cleanup strategies supported by the backend."""

    NEWEST = "newest"
    OLDEST = "oldest"


class CleanupAction(StrEnum):
    """Describe the action chosen for a duplicate extension install."""

    KEEP = "keep"
    DELETE = "delete"
    SKIP_REFERENCED = "skip_referenced"


class SymlinkAction(StrEnum):
    """Describe the current state of an Insiders extension entry."""

    LINKED = "linked"
    MISSING = "missing"
    BROKEN = "broken"
    WRONG_TARGET = "wrong_target"
    UNMANAGED_REAL_DIR = "unmanaged_real_dir"
    EXCLUDED = "excluded"
    EXCLUDED_BUT_SYMLINKED = "excluded_but_symlinked"
    STALE_MANAGED_SYMLINK = "stale_managed_symlink"


class ManifestAction(StrEnum):
    """Describe the action planned for a manifest entry."""

    KEEP = "keep"
    UPDATE = "update"
    REMOVE = "remove"


@dataclass(frozen=True, slots=True)
class ParsedExtensionFolder:
    """Represent the parsed components of a versioned extension folder name."""

    folder_name: str
    extension_id: str
    core_name: str
    version: str | None

    def to_dict(self) -> dict[str, str | None]:
        """Serialize the parsed folder metadata into a JSON-friendly mapping."""
        return {
            "folder_name": self.folder_name,
            "extension_id": self.extension_id,
            "core_name": self.core_name,
            "version": self.version,
        }


@dataclass(frozen=True, slots=True)
class ExtensionInstall:
    """Represent a discovered extension install inside an extensions root."""

    folder_name: str
    extension_id: str
    core_name: str
    version: str | None
    path: Path
    edition: VscodeEdition
    is_symlink: bool
    symlink_target: str | None
    resolved_symlink_target: Path | None
    target_exists: bool
    mtime: int | None

    def to_dict(self) -> dict[str, str | int | bool | None]:
        """Serialize the install metadata into a JSON-friendly mapping."""
        return {
            "folder_name": self.folder_name,
            "extension_id": self.extension_id,
            "core_name": self.core_name,
            "version": self.version,
            "path": str(self.path),
            "edition": self.edition.value,
            "is_symlink": self.is_symlink,
            "symlink_target": self.symlink_target,
            "resolved_symlink_target": (
                str(self.resolved_symlink_target) if self.resolved_symlink_target else None
            ),
            "target_exists": self.target_exists,
            "mtime": self.mtime,
        }


@dataclass(frozen=True, slots=True)
class ReferenceEntry:
    """Represent a folder reference found in a VS Code manifest file."""

    folder_name: str
    manifest_path: Path
    source_kind: str

    def to_dict(self) -> dict[str, str]:
        """Serialize the manifest reference into a JSON-friendly mapping."""
        return {
            "folder_name": self.folder_name,
            "manifest_path": str(self.manifest_path),
            "source_kind": self.source_kind,
        }


@dataclass(frozen=True, slots=True)
class CleanupDecision:
    """Describe how a single installed extension folder should be handled."""

    folder_name: str
    path: Path
    core_name: str
    version: str | None
    action: CleanupAction
    reason: str
    referenced: bool = False

    def to_dict(self) -> dict[str, str | bool | None]:
        """Serialize the cleanup decision into a JSON-friendly mapping."""
        return {
            "folder_name": self.folder_name,
            "path": str(self.path),
            "core_name": self.core_name,
            "version": self.version,
            "action": self.action.value,
            "reason": self.reason,
            "referenced": self.referenced,
        }


@dataclass(frozen=True, slots=True)
class CleanupGroupPlan:
    """Group cleanup decisions for all installed versions of one extension core."""

    core_name: str
    installs: tuple[ExtensionInstall, ...]
    newest_folder_name: str
    oldest_unreferenced_folder_name: str | None
    decisions: tuple[CleanupDecision, ...]

    def to_dict(self) -> dict[str, object]:
        """Serialize the group cleanup plan into a JSON-friendly mapping."""
        return {
            "core_name": self.core_name,
            "installs": [install.to_dict() for install in self.installs],
            "newest_folder_name": self.newest_folder_name,
            "oldest_unreferenced_folder_name": self.oldest_unreferenced_folder_name,
            "decisions": [decision.to_dict() for decision in self.decisions],
        }


@dataclass(frozen=True, slots=True)
class CleanupPlan:
    """Capture the full duplicate-cleanup plan for one extension root."""

    root: Path
    strategy: CleanupStrategy
    respect_references: bool
    raw_reference_names: tuple[str, ...]
    protected_reference_names: tuple[str, ...]
    stale_reference_names: tuple[str, ...]
    duplicate_group_count: int
    planned_deletion_count: int
    protected_skip_count: int
    groups: tuple[CleanupGroupPlan, ...]

    def to_dict(self) -> dict[str, object]:
        """Serialize the cleanup plan into a JSON-friendly mapping."""
        return {
            "root": str(self.root),
            "strategy": self.strategy.value,
            "respect_references": self.respect_references,
            "raw_reference_names": list(self.raw_reference_names),
            "protected_reference_names": list(self.protected_reference_names),
            "stale_reference_names": list(self.stale_reference_names),
            "duplicate_group_count": self.duplicate_group_count,
            "planned_deletion_count": self.planned_deletion_count,
            "protected_skip_count": self.protected_skip_count,
            "groups": [group.to_dict() for group in self.groups],
        }


@dataclass(frozen=True, slots=True)
class CleanupApplyReport:
    """Summarize the result of applying a cleanup plan in quarantine mode."""

    root: Path
    quarantine_root: Path
    quarantined_paths: tuple[Path, ...]
    failed_paths: tuple[Path, ...]

    @property
    def deleted_paths(self) -> tuple[Path, ...]:
        """Expose quarantined paths using the legacy deleted-paths name."""
        return self.quarantined_paths

    def to_dict(self) -> dict[str, object]:
        """Serialize the cleanup apply report into a JSON-friendly mapping."""
        return {
            "root": str(self.root),
            "quarantine_root": str(self.quarantine_root),
            "quarantined_paths": [str(path) for path in self.quarantined_paths],
            "deleted_paths": [str(path) for path in self.deleted_paths],
            "failed_paths": [str(path) for path in self.failed_paths],
            "quarantined_count": len(self.quarantined_paths),
            "deleted_count": len(self.deleted_paths),
            "failed_count": len(self.failed_paths),
        }


@dataclass(frozen=True, slots=True)
class SymlinkDecision:
    """Describe the expected or observed state for one Insiders extension entry."""

    folder_name: str
    action: SymlinkAction
    reason: str
    path: Path
    target_path: Path | None = None

    def to_dict(self) -> dict[str, str | None]:
        """Serialize the symlink decision into a JSON-friendly mapping."""
        return {
            "folder_name": self.folder_name,
            "action": self.action.value,
            "reason": self.reason,
            "path": str(self.path),
            "target_path": str(self.target_path) if self.target_path else None,
        }


@dataclass(frozen=True, slots=True)
class SymlinkPlan:
    """Capture the read-only symlink state between Stable and Insiders."""

    stable_dir: Path
    insiders_dir: Path
    exclude_patterns: tuple[str, ...]
    total_source_extensions: int
    expected_link_count: int
    linked_count: int
    missing_count: int
    broken_count: int
    wrong_target_count: int
    unmanaged_count: int
    excluded_count: int
    excluded_symlinked_count: int
    stale_managed_count: int
    decisions: tuple[SymlinkDecision, ...]

    def to_dict(self) -> dict[str, object]:
        """Serialize the symlink plan into a JSON-friendly mapping."""
        return {
            "stable_dir": str(self.stable_dir),
            "insiders_dir": str(self.insiders_dir),
            "exclude_patterns": list(self.exclude_patterns),
            "total_source_extensions": self.total_source_extensions,
            "expected_link_count": self.expected_link_count,
            "linked_count": self.linked_count,
            "missing_count": self.missing_count,
            "broken_count": self.broken_count,
            "wrong_target_count": self.wrong_target_count,
            "unmanaged_count": self.unmanaged_count,
            "excluded_count": self.excluded_count,
            "excluded_symlinked_count": self.excluded_symlinked_count,
            "stale_managed_count": self.stale_managed_count,
            "decisions": [decision.to_dict() for decision in self.decisions],
        }


@dataclass(frozen=True, slots=True)
class ManifestRepairDecision:
    """Describe the action planned for one manifest entry."""

    manifest_path: Path
    entry_index: int
    edition: VscodeEdition
    source_kind: str
    extension_id: str | None
    current_folder_name: str | None
    desired_folder_name: str | None
    action: ManifestAction
    reason: str

    def to_dict(self) -> dict[str, str | int | None]:
        """Serialize the manifest repair decision into a JSON-friendly mapping."""
        return {
            "manifest_path": str(self.manifest_path),
            "entry_index": self.entry_index,
            "edition": self.edition.value,
            "source_kind": self.source_kind,
            "extension_id": self.extension_id,
            "current_folder_name": self.current_folder_name,
            "desired_folder_name": self.desired_folder_name,
            "action": self.action.value,
            "reason": self.reason,
        }


@dataclass(frozen=True, slots=True)
class ManifestRepairPlan:
    """Capture the full repair plan for root and profile manifests."""

    stable_dir: Path
    insiders_dir: Path
    update_count: int
    remove_count: int
    keep_count: int
    preserved_missing_profile_count: int
    decisions: tuple[ManifestRepairDecision, ...]

    def to_dict(self) -> dict[str, object]:
        """Serialize the manifest repair plan into a JSON-friendly mapping."""
        return {
            "stable_dir": str(self.stable_dir),
            "insiders_dir": str(self.insiders_dir),
            "update_count": self.update_count,
            "remove_count": self.remove_count,
            "keep_count": self.keep_count,
            "preserved_missing_profile_count": self.preserved_missing_profile_count,
            "decisions": [decision.to_dict() for decision in self.decisions],
        }


@dataclass(frozen=True, slots=True)
class ManifestApplyReport:
    """Summarize the result of applying a manifest repair plan."""

    updated_entries: int
    removed_entries: int
    touched_manifests: tuple[Path, ...]

    def to_dict(self) -> dict[str, object]:
        """Serialize the manifest apply report into a JSON-friendly mapping."""
        return {
            "updated_entries": self.updated_entries,
            "removed_entries": self.removed_entries,
            "touched_manifests": [str(path) for path in self.touched_manifests],
        }


@dataclass(frozen=True, slots=True)
class ExtensionSetupReport:
    """Summarize the result of repairing the Insiders extension tree."""

    linked_count: int
    relinked_count: int
    migrated_count: int
    removed_stale_symlink_count: int
    skipped_excluded_symlink_count: int
    manifest_apply_report: ManifestApplyReport

    def to_dict(self) -> dict[str, object]:
        """Serialize the extension setup report into a JSON-friendly mapping."""
        return {
            "linked_count": self.linked_count,
            "relinked_count": self.relinked_count,
            "migrated_count": self.migrated_count,
            "removed_stale_symlink_count": self.removed_stale_symlink_count,
            "skipped_excluded_symlink_count": self.skipped_excluded_symlink_count,
            "manifest_apply_report": self.manifest_apply_report.to_dict(),
        }
