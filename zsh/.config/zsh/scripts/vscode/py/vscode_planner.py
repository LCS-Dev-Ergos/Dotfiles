from __future__ import annotations

from fnmatch import fnmatchcase
from pathlib import Path

from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_fs import canonicalize_path, is_within_directory
from vscode_manifests import collect_reference_names
from vscode_models import (
    CleanupAction,
    CleanupDecision,
    CleanupGroupPlan,
    CleanupPlan,
    CleanupStrategy,
    ExtensionInstall,
    SymlinkAction,
    SymlinkDecision,
    SymlinkPlan,
    VscodeEdition,
)
from vscode_scanner import parse_extension_folder_name, scan_extension_root
from vscode_versions import compare_versions


def is_excluded_extension(folder_name: str, patterns: tuple[str, ...] | list[str]) -> bool:
    """Return True when the folder name matches one of the exclusion patterns."""
    return any(fnmatchcase(folder_name, pattern) for pattern in patterns)


def _build_effective_reference_names(
    installs: list[ExtensionInstall],
    raw_reference_names: list[str],
) -> tuple[list[str], list[str]]:
    installed_by_name = {install.folder_name: install for install in installs}
    protected_names = sorted(
        {
            name
            for name in raw_reference_names
            if name in installed_by_name
        }
    )
    return protected_names, []


def _select_newest_install(group: list[ExtensionInstall]) -> ExtensionInstall:
    newest = group[0]
    for install in group[1:]:
        cmp = compare_versions(install.version, newest.version)
        if cmp > 0:
            newest = install
            continue
        if cmp == 0 and (install.mtime or 0) > (newest.mtime or 0):
            newest = install
    return newest


def _select_oldest_unreferenced_install(
    group: list[ExtensionInstall],
    *,
    protected_names: set[str],
) -> ExtensionInstall | None:
    oldest: ExtensionInstall | None = None
    for install in group:
        if install.folder_name in protected_names:
            continue
        if oldest is None:
            oldest = install
            continue

        cmp = compare_versions(install.version, oldest.version)
        if cmp < 0:
            oldest = install
            continue
        if cmp == 0 and (install.mtime or 0) < (oldest.mtime or 0):
            oldest = install

    return oldest


def plan_extension_cleanup(
    extensions_dir: str | Path,
    *,
    strategy: CleanupStrategy = CleanupStrategy.NEWEST,
    respect_references: bool = True,
    config: VscodePathsConfig | None = None,
) -> CleanupPlan:
    """Build a deterministic cleanup plan for a VS Code extension root."""
    root = canonicalize_path(extensions_dir)
    scoped_config = config or VscodePathsConfig.from_home()
    installs = [
        install
        for install in scan_extension_root(
            root,
            edition=scoped_config.scope_for_extensions_dir(root),
        )
        if not install.is_symlink
    ]

    raw_reference_names = (
        collect_reference_names(root, config=scoped_config) if respect_references else []
    )
    protected_reference_names, stale_reference_names = _build_effective_reference_names(
        installs,
        raw_reference_names,
    )
    protected_reference_set = set(protected_reference_names)

    grouped: dict[str, list[ExtensionInstall]] = {}
    for install in installs:
        grouped.setdefault(install.core_name, []).append(install)

    groups: list[CleanupGroupPlan] = []
    planned_deletions = 0
    protected_skips = 0

    for core_name in sorted(grouped):
        group = sorted(grouped[core_name], key=lambda entry: entry.folder_name)
        if len(group) <= 1:
            continue

        newest = _select_newest_install(group)
        oldest_unreferenced = _select_oldest_unreferenced_install(
            group,
            protected_names=protected_reference_set,
        )

        decisions: list[CleanupDecision] = []
        if strategy == CleanupStrategy.NEWEST:
            for install in group:
                if install.folder_name == newest.folder_name:
                    decisions.append(
                        CleanupDecision(
                            folder_name=install.folder_name,
                            path=install.path,
                            core_name=install.core_name,
                            version=install.version,
                            action=CleanupAction.KEEP,
                            reason="newest_installed_version",
                            referenced=install.folder_name in protected_reference_set,
                        )
                    )
                    continue

                if respect_references and install.folder_name in protected_reference_set:
                    protected_skips += 1
                    decisions.append(
                        CleanupDecision(
                            folder_name=install.folder_name,
                            path=install.path,
                            core_name=install.core_name,
                            version=install.version,
                            action=CleanupAction.SKIP_REFERENCED,
                            reason="protected_referenced_version",
                            referenced=True,
                        )
                    )
                    continue

                planned_deletions += 1
                decisions.append(
                    CleanupDecision(
                        folder_name=install.folder_name,
                        path=install.path,
                        core_name=install.core_name,
                        version=install.version,
                        action=CleanupAction.DELETE,
                        reason="older_duplicate_version",
                        referenced=False,
                    )
                )
        else:
            for install in group:
                if oldest_unreferenced and install.folder_name == oldest_unreferenced.folder_name:
                    planned_deletions += 1
                    decisions.append(
                        CleanupDecision(
                            folder_name=install.folder_name,
                            path=install.path,
                            core_name=install.core_name,
                            version=install.version,
                            action=CleanupAction.DELETE,
                            reason="oldest_unreferenced_duplicate",
                            referenced=False,
                        )
                    )
                    continue

                action = CleanupAction.KEEP
                reason = "kept_duplicate_version"
                referenced = install.folder_name in protected_reference_set
                if referenced:
                    action = CleanupAction.SKIP_REFERENCED
                    reason = "protected_referenced_version"
                    protected_skips += 1

                decisions.append(
                    CleanupDecision(
                        folder_name=install.folder_name,
                        path=install.path,
                        core_name=install.core_name,
                        version=install.version,
                        action=action,
                        reason=reason,
                        referenced=referenced,
                    )
                )

        groups.append(
            CleanupGroupPlan(
                core_name=core_name,
                installs=tuple(group),
                newest_folder_name=newest.folder_name,
                oldest_unreferenced_folder_name=(
                    oldest_unreferenced.folder_name if oldest_unreferenced else None
                ),
                decisions=tuple(
                    sorted(decisions, key=lambda decision: (decision.folder_name, decision.action.value))
                ),
            )
        )

    return CleanupPlan(
        root=root,
        strategy=strategy,
        respect_references=respect_references,
        raw_reference_names=tuple(sorted(set(raw_reference_names))),
        protected_reference_names=tuple(protected_reference_names),
        stale_reference_names=tuple(stale_reference_names),
        duplicate_group_count=len(groups),
        planned_deletion_count=planned_deletions,
        protected_skip_count=protected_skips,
        groups=tuple(groups),
    )


def plan_insiders_symlink_state(
    stable_dir: str | Path,
    insiders_dir: str | Path,
    *,
    exclude_patterns: tuple[str, ...] | list[str] | None = None,
) -> SymlinkPlan:
    """Build a read-only plan describing symlink drift between Stable and Insiders."""
    stable_root = canonicalize_path(stable_dir)
    insiders_root = canonicalize_path(insiders_dir)
    resolved_patterns = tuple(exclude_patterns or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)

    stable_installs = scan_extension_root(stable_root, edition=VscodeEdition.STABLE)
    insiders_installs = scan_extension_root(insiders_root, edition=VscodeEdition.INSIDERS)

    stable_by_name = {install.folder_name: install for install in stable_installs}
    insiders_by_name = {install.folder_name: install for install in insiders_installs}
    stable_names = set(stable_by_name)

    decisions: list[SymlinkDecision] = []
    linked_count = 0
    missing_count = 0
    broken_count = 0
    wrong_target_count = 0
    unmanaged_count = 0
    excluded_count = 0
    excluded_symlinked_count = 0
    stale_managed_count = 0

    for install in stable_installs:
        expected_target = canonicalize_path(stable_root / install.folder_name)
        insiders_path = insiders_root / install.folder_name
        insiders_install = insiders_by_name.get(install.folder_name)

        if is_excluded_extension(install.folder_name, resolved_patterns):
            excluded_count += 1
            if insiders_install and insiders_install.is_symlink:
                excluded_symlinked_count += 1
                decisions.append(
                    SymlinkDecision(
                        folder_name=install.folder_name,
                        action=SymlinkAction.EXCLUDED_BUT_SYMLINKED,
                        reason="excluded_extension_should_not_be_symlinked",
                        path=insiders_path,
                        target_path=expected_target,
                    )
                )
            else:
                decisions.append(
                    SymlinkDecision(
                        folder_name=install.folder_name,
                        action=SymlinkAction.EXCLUDED,
                        reason="excluded_from_shared_symlink_management",
                        path=insiders_path,
                        target_path=expected_target,
                    )
                )
            continue

        if insiders_install is None:
            missing_count += 1
            decisions.append(
                SymlinkDecision(
                    folder_name=install.folder_name,
                    action=SymlinkAction.MISSING,
                    reason="expected_symlink_missing_in_insiders",
                    path=insiders_path,
                    target_path=expected_target,
                )
            )
            continue

        if insiders_install.is_symlink:
            if not insiders_install.target_exists:
                broken_count += 1
                decisions.append(
                    SymlinkDecision(
                        folder_name=install.folder_name,
                        action=SymlinkAction.BROKEN,
                        reason="insiders_symlink_target_missing",
                        path=insiders_install.path,
                        target_path=expected_target,
                    )
                )
            elif insiders_install.resolved_symlink_target != expected_target:
                wrong_target_count += 1
                decisions.append(
                    SymlinkDecision(
                        folder_name=install.folder_name,
                        action=SymlinkAction.WRONG_TARGET,
                        reason="insiders_symlink_points_to_unexpected_target",
                        path=insiders_install.path,
                        target_path=insiders_install.resolved_symlink_target,
                    )
                )
            else:
                linked_count += 1
                decisions.append(
                    SymlinkDecision(
                        folder_name=install.folder_name,
                        action=SymlinkAction.LINKED,
                        reason="expected_symlink_present",
                        path=insiders_install.path,
                        target_path=expected_target,
                    )
                )
            continue

        unmanaged_count += 1
        decisions.append(
            SymlinkDecision(
                folder_name=install.folder_name,
                action=SymlinkAction.UNMANAGED_REAL_DIR,
                reason="insiders_contains_real_directory_instead_of_symlink",
                path=insiders_install.path,
                target_path=expected_target,
            )
        )

    for install in insiders_installs:
        if install.folder_name in stable_names:
            continue

        if not install.is_symlink:
            if is_excluded_extension(install.folder_name, resolved_patterns):
                continue
            unmanaged_count += 1
            decisions.append(
                SymlinkDecision(
                    folder_name=install.folder_name,
                    action=SymlinkAction.UNMANAGED_REAL_DIR,
                    reason="insiders_only_real_directory_should_be_migrated_to_shared_root",
                    path=install.path,
                    target_path=stable_root / install.folder_name,
                )
            )
            continue

        if not install.resolved_symlink_target:
            continue
        if not is_within_directory(install.resolved_symlink_target, stable_root):
            continue

        stale_managed_count += 1
        decisions.append(
            SymlinkDecision(
                folder_name=install.folder_name,
                action=SymlinkAction.STALE_MANAGED_SYMLINK,
                reason="symlink_points_into_stable_root_but_source_extension_is_missing_or_excluded",
                path=install.path,
                target_path=install.resolved_symlink_target,
            )
        )

    return SymlinkPlan(
        stable_dir=stable_root,
        insiders_dir=insiders_root,
        exclude_patterns=resolved_patterns,
        total_source_extensions=len(stable_installs),
        expected_link_count=len(stable_installs) - excluded_count,
        linked_count=linked_count,
        missing_count=missing_count,
        broken_count=broken_count,
        wrong_target_count=wrong_target_count,
        unmanaged_count=unmanaged_count,
        excluded_count=excluded_count,
        excluded_symlinked_count=excluded_symlinked_count,
        stale_managed_count=stale_managed_count,
        decisions=tuple(
            sorted(
                decisions,
                key=lambda decision: (decision.action.value, decision.folder_name),
            )
        ),
    )
