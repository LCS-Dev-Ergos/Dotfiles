# ============================================================================ #
"""
Extension update planning and apply helpers for the VS Code sync workflow.

The update workflow proceeds in several phases:

1. Plan (`build_extension_update_plan`): Snapshot the current symlink
   and cleanup state before any mutations.
2. Shared Stable update: Invoke `code --update-extensions` against the
   Stable root so all shared extensions receive marketplace updates.
3. Post-update cleanup: Re-scan the Stable root and quarantine old
   duplicate versions left behind by the update.
4. Native excluded updates: For extensions excluded from symlink sharing
   (e.g. Claude Code, Copilot), perform an isolated update in a temporary
   root, then promote the new version into the real Insiders root with
   rollback-safe directory swaps.
5. Reconciliation: Repair symlinks and manifests so Insiders reflects
   the newly updated Stable state.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from vscode_cleanup import apply_cleanup_plan
from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import canonicalize_path, is_within_directory
from vscode_models import (
    CleanupPlan,
    ExtensionInstall,
    ExtensionSetupReport,
    ManifestRepairPlan,
    SymlinkPlan,
    VscodeEdition,
)
from vscode_planner import (
    is_excluded_extension,
    plan_extension_cleanup,
    plan_insiders_symlink_state,
)
from vscode_profiles import plan_manifest_repairs
from vscode_scanner import scan_extension_root
from vscode_sync_apply import apply_extension_setup
from vscode_versions import compare_versions

_UPDATE_TIMEOUT_SECONDS = 300
_MAX_BACKUP_SUFFIX_ATTEMPTS = 10000
_UPDATED_EXTENSION_RE = re.compile(r"Extension '([^']+)' .* was successfully updated\.")


@dataclass(frozen=True, slots=True)
class ExtensionUpdatePlan:
    """Capture the planned extension update workflow."""

    stable_dir: Path
    insiders_dir: Path
    skip_clean: bool
    native_excluded_extension_ids: tuple[str, ...]
    symlink_plan: SymlinkPlan
    cleanup_plan: CleanupPlan | None
    manifest_plan: ManifestRepairPlan

    def to_dict(self) -> dict[str, object]:
        """Serialize the update plan into a JSON-friendly mapping."""
        return {
            "stable_dir": str(self.stable_dir),
            "insiders_dir": str(self.insiders_dir),
            "skip_clean": self.skip_clean,
            "native_excluded_extension_ids": list(self.native_excluded_extension_ids),
            "symlink_plan": self.symlink_plan.to_dict(),
            "cleanup_plan": self.cleanup_plan.to_dict() if self.cleanup_plan else None,
            "manifest_plan": self.manifest_plan.to_dict(),
        }


@dataclass(frozen=True, slots=True)
class ExtensionUpdateReport:
    """Summarize the result of applying an extension update workflow."""

    shared_update_succeeded: bool
    shared_updated_extension_ids: tuple[str, ...]
    cleanup_quarantined_count: int
    cleanup_failed_count: int
    excluded_updates_attempted: tuple[str, ...]
    excluded_updates_applied: tuple[str, ...]
    excluded_updates_current: tuple[str, ...]
    excluded_updates_failed: tuple[str, ...]
    setup_report: ExtensionSetupReport
    final_symlink_plan: SymlinkPlan
    final_manifest_plan: ManifestRepairPlan

    def to_dict(self) -> dict[str, object]:
        """Serialize the update report into a JSON-friendly mapping."""
        return {
            "shared_update_succeeded": self.shared_update_succeeded,
            "shared_updated_extension_ids": list(self.shared_updated_extension_ids),
            "cleanup_quarantined_count": self.cleanup_quarantined_count,
            "cleanup_failed_count": self.cleanup_failed_count,
            "excluded_updates_attempted": list(self.excluded_updates_attempted),
            "excluded_updates_applied": list(self.excluded_updates_applied),
            "excluded_updates_current": list(self.excluded_updates_current),
            "excluded_updates_failed": list(self.excluded_updates_failed),
            "setup_report": self.setup_report.to_dict(),
            "final_symlink_plan": self.final_symlink_plan.to_dict(),
            "final_manifest_plan": self.final_manifest_plan.to_dict(),
        }


def _run_cli_command(
    command: list[str],
    *,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[object]:
    """Run a VS Code CLI command and optionally capture its output."""

    return subprocess.run(
        command,
        timeout=_UPDATE_TIMEOUT_SECONDS,
        capture_output=capture_output,
        text=capture_output,
    )


def _collect_native_excluded_extension_ids(
    insiders_dir: Path,
    *,
    exclude_patterns: tuple[str, ...],
) -> tuple[str, ...]:
    """Collect excluded extension IDs currently managed as real Insiders directories."""

    extension_ids = {
        install.extension_id
        for install in scan_extension_root(insiders_dir)
        if not install.is_symlink and is_excluded_extension(install.folder_name, exclude_patterns)
    }
    return tuple(sorted(extension_ids))


def _ordered_unique(items: list[str]) -> tuple[str, ...]:
    """Return input items once, preserving their first-seen order."""

    seen: set[str] = set()
    ordered: list[str] = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        ordered.append(item)
    return tuple(ordered)


def _parse_shared_updated_extension_ids(output: str) -> tuple[str, ...]:
    """Extract unique updated extension IDs from VS Code CLI output."""

    updated_ids = [
        match.group(1)
        for line in output.splitlines()
        if (match := _UPDATED_EXTENSION_RE.search(line))
    ]
    return _ordered_unique(updated_ids)


def _list_native_excluded_installs(
    insiders_dir: Path,
    extension_id: str,
) -> tuple[ExtensionInstall, ...]:
    """Return the real Insiders installs currently present for one excluded extension."""

    installs = [
        install
        for install in scan_extension_root(insiders_dir, edition=VscodeEdition.INSIDERS)
        if not install.is_symlink and install.extension_id == extension_id
    ]
    return tuple(installs)


def _select_latest_install(
    installs: tuple[ExtensionInstall, ...],
) -> ExtensionInstall | None:
    """Return the newest install using version, mtime, and folder name as tie-breakers."""

    latest: ExtensionInstall | None = None
    for install in installs:
        if latest is None:
            latest = install
            continue

        version_cmp = compare_versions(install.version, latest.version)
        if version_cmp > 0:
            latest = install
            continue
        if version_cmp < 0:
            continue

        install_mtime = install.mtime or 0
        latest_mtime = latest.mtime or 0
        if install_mtime > latest_mtime:
            latest = install
            continue
        if install_mtime == latest_mtime and install.folder_name > latest.folder_name:
            latest = install

    return latest


def _is_newer_install(candidate: ExtensionInstall, current: ExtensionInstall) -> bool:
    """Return `True` when `candidate` should replace `current` in the real root."""

    version_cmp = compare_versions(candidate.version, current.version)
    if version_cmp > 0:
        return True
    if version_cmp < 0:
        return False
    return candidate.folder_name != current.folder_name


def _make_native_update_temp_root(home: Path) -> tempfile.TemporaryDirectory[str]:
    """Create a temporary root used to stage one isolated excluded-extension update."""

    temp_parent = canonicalize_path(home / ".cache/vscode-sync")
    temp_parent.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(
        prefix="excluded-native-update-",
        dir=temp_parent,
    )


def _make_native_update_backup_root(home: Path, extension_id: str) -> Path:
    """Create a unique backup directory for one excluded-extension promotion."""

    backup_parent = canonicalize_path(home / ".local/share/vscode-sync-backups")
    backup_parent.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    safe_extension_id = extension_id.replace("/", "__")
    for attempt in range(1, _MAX_BACKUP_SUFFIX_ATTEMPTS + 1):
        candidate = (
            backup_parent
            / f"{timestamp}_{os.getpid()}_{attempt}_native-excluded-update"
            / safe_extension_id
        )
        try:
            candidate.mkdir(parents=True, exist_ok=False)
            return candidate
        except FileExistsError:
            continue

    raise RuntimeError("failed to allocate a native excluded update backup directory")


def _unique_backup_target(backup_root: Path, path: Path) -> Path:
    """Return a unique backup destination for `path` inside `backup_root`."""

    candidate = backup_root / path.name
    if not candidate.exists():
        return candidate

    for attempt in range(1, _MAX_BACKUP_SUFFIX_ATTEMPTS + 1):
        candidate = backup_root / f"{path.name}.{attempt}"
        if not candidate.exists():
            return candidate

    raise RuntimeError("failed to allocate a unique native excluded update backup target")


def _promote_native_excluded_update(
    extension_id: str,
    staged_install: ExtensionInstall,
    *,
    insiders_dir: Path,
    home: Path,
) -> bool:
    """Promote a staged excluded update into the real Insiders root with rollback safety."""

    if not staged_install.path.is_dir():
        return False

    current_installs = _list_native_excluded_installs(insiders_dir, extension_id)
    paths_to_backup = [canonicalize_path(install.path) for install in current_installs]

    target_path = canonicalize_path(insiders_dir / staged_install.folder_name)
    if not is_within_directory(target_path, insiders_dir):
        return False

    conflict_path = canonicalize_path(target_path)
    if (
        conflict_path.exists() or conflict_path.is_symlink()
    ) and conflict_path not in paths_to_backup:
        paths_to_backup.append(conflict_path)

    backup_root = _make_native_update_backup_root(home, extension_id)
    moved_backups: list[tuple[Path, Path]] = []

    try:
        # Move current installs out of the way first. This guarantees we can
        # atomically promote the staged directory into its final name.
        for source_path in paths_to_backup:
            if not is_within_directory(source_path, insiders_dir):
                raise RuntimeError("refusing to back up a path outside the Insiders root")
            if not (source_path.exists() or source_path.is_symlink()):
                continue

            destination = _unique_backup_target(backup_root, source_path)
            shutil.move(str(source_path), str(destination))
            moved_backups.append((source_path, destination))

        shutil.move(str(staged_install.path), str(target_path))
    except (OSError, RuntimeError):
        # Best-effort rollback to preserve the previously installed excluded extension.
        for original_path, backup_path in reversed(moved_backups):
            if original_path.exists() or original_path.is_symlink():
                continue
            if backup_path.exists() or backup_path.is_symlink():
                try:
                    shutil.move(str(backup_path), str(original_path))
                except OSError:
                    continue
        return False

    return True


def _update_native_excluded_extension(
    extension_id: str,
    *,
    insiders_dir: Path,
    home: Path,
) -> str:
    """Run an isolated update-only flow for one Insiders-native excluded extension."""

    current_installs = _list_native_excluded_installs(insiders_dir, extension_id)
    current_install = _select_latest_install(current_installs)
    if current_install is None or not current_install.path.is_dir():
        return "failed"

    with _make_native_update_temp_root(home) as temp_dir:
        temp_root = Path(temp_dir)
        staged_current = temp_root / current_install.folder_name
        try:
            shutil.copytree(current_install.path, staged_current, symlinks=True)
        except OSError:
            return "failed"

        completed = _run_cli_command(
            [
                "code-insiders",
                "--extensions-dir",
                str(temp_root),
                "--update-extensions",
            ],
            capture_output=True,
        )
        staged_installs = tuple(
            install
            for install in scan_extension_root(temp_root, edition=VscodeEdition.INSIDERS)
            if not install.is_symlink and install.extension_id == extension_id
        )
        staged_install = _select_latest_install(staged_installs)
        if staged_install is None:
            return "failed"
        if completed.returncode != 0:
            return "failed"
        if not _is_newer_install(staged_install, current_install):
            return "current"
        if not _promote_native_excluded_update(
            extension_id,
            staged_install,
            insiders_dir=insiders_dir,
            home=home,
        ):
            return "failed"

    return "applied"


def build_extension_update_plan(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    skip_clean: bool = False,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> ExtensionUpdatePlan:
    """Build a deterministic update plan for the shared extension workflow."""

    resolved_config = config or VscodePathsConfig.from_home()
    stable_root = Path(stable_dir).expanduser().resolve(strict=False)
    insiders_root = Path(insiders_dir).expanduser().resolve(strict=False)
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)

    symlink_plan = plan_insiders_symlink_state(
        stable_root,
        insiders_root,
        exclude_patterns=resolved_patterns,
    )
    cleanup_plan = None
    if not skip_clean:
        cleanup_plan = plan_extension_cleanup(
            stable_root,
            config=resolved_config,
            prune_stale_references=False,
        )
    manifest_plan = plan_manifest_repairs(
        stable_root,
        insiders_root,
        config=resolved_config,
        exclude_patterns=resolved_patterns,
    )

    return ExtensionUpdatePlan(
        stable_dir=stable_root,
        insiders_dir=insiders_root,
        skip_clean=skip_clean,
        native_excluded_extension_ids=_collect_native_excluded_extension_ids(
            insiders_root,
            exclude_patterns=resolved_patterns,
        ),
        symlink_plan=symlink_plan,
        cleanup_plan=cleanup_plan,
        manifest_plan=manifest_plan,
    )


def _build_runtime_cleanup_plan(
    stable_dir: Path,
    *,
    config: VscodePathsConfig,
) -> CleanupPlan:
    """Recompute cleanup actions against the live shared root after Stable updates."""

    return plan_extension_cleanup(
        stable_dir,
        config=config,
        prune_stale_references=False,
    )


def apply_extension_update(
    plan: ExtensionUpdatePlan,
    *,
    config: VscodePathsConfig | None = None,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> ExtensionUpdateReport:
    """Apply an extension update plan end to end."""

    resolved_config = config or VscodePathsConfig.from_home()
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)

    if shutil.which("code") is None:
        raise FileNotFoundError("VS Code Stable CLI not found: code")
    if shutil.which("code-insiders") is None:
        raise FileNotFoundError("VS Code Insiders CLI not found: code-insiders")

    shared_update_completed = _run_cli_command(
        [
            "code",
            "--extensions-dir",
            str(plan.stable_dir),
            "--update-extensions",
        ],
        capture_output=True,
    )
    shared_update_succeeded = shared_update_completed.returncode == 0
    if not shared_update_succeeded:
        raise RuntimeError("Shared Stable extension update failed.")
    shared_stdout = (
        shared_update_completed.stdout if isinstance(shared_update_completed.stdout, str) else ""
    )
    shared_stderr = (
        shared_update_completed.stderr if isinstance(shared_update_completed.stderr, str) else ""
    )
    shared_updated_extension_ids = _parse_shared_updated_extension_ids(
        shared_stdout + "\n" + shared_stderr
    )

    cleanup_quarantined_count = 0
    cleanup_failed_count = 0
    if plan.cleanup_plan is not None:
        cleanup_report = apply_cleanup_plan(
            _build_runtime_cleanup_plan(
                plan.stable_dir,
                config=resolved_config,
            )
        )
        cleanup_quarantined_count = len(cleanup_report.quarantined_paths)
        cleanup_failed_count = len(cleanup_report.failed_paths)
        if cleanup_failed_count:
            raise RuntimeError("Shared Stable duplicate cleanup failed.")

    excluded_updates_attempted: list[str] = []
    excluded_updates_applied: list[str] = []
    excluded_updates_current: list[str] = []
    excluded_updates_failed: list[str] = []
    for extension_id in plan.native_excluded_extension_ids:
        excluded_updates_attempted.append(extension_id)
        result = _update_native_excluded_extension(
            extension_id,
            insiders_dir=plan.insiders_dir,
            home=resolved_config.home,
        )
        if result == "applied":
            excluded_updates_applied.append(extension_id)
        elif result == "current":
            excluded_updates_current.append(extension_id)
        else:
            excluded_updates_failed.append(extension_id)

    setup_report = apply_extension_setup(
        plan.stable_dir,
        plan.insiders_dir,
        config=resolved_config,
        exclude_patterns=resolved_patterns,
    )
    final_symlink_plan = plan_insiders_symlink_state(
        plan.stable_dir,
        plan.insiders_dir,
        exclude_patterns=resolved_patterns,
    )
    final_manifest_plan = plan_manifest_repairs(
        plan.stable_dir,
        plan.insiders_dir,
        config=resolved_config,
        exclude_patterns=resolved_patterns,
    )

    return ExtensionUpdateReport(
        shared_update_succeeded=shared_update_succeeded,
        shared_updated_extension_ids=shared_updated_extension_ids,
        cleanup_quarantined_count=cleanup_quarantined_count,
        cleanup_failed_count=cleanup_failed_count,
        excluded_updates_attempted=tuple(excluded_updates_attempted),
        excluded_updates_applied=tuple(excluded_updates_applied),
        excluded_updates_current=tuple(excluded_updates_current),
        excluded_updates_failed=tuple(excluded_updates_failed),
        setup_report=setup_report,
        final_symlink_plan=final_symlink_plan,
        final_manifest_plan=final_manifest_plan,
    )
