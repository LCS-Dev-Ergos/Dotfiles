# ============================================================================ #
"""
Command-line interface for the VS Code sync Python backend.

Exposes all backend operations as `argparse` subcommands.  Every subcommand
accepts `--json` for machine-readable output and works with either local or
remote extension directories.

Subcommand Groups
    Scanning / inspection:
        `scan`, `references`, `plan-links`, `extension-status`,
        `extension-check`, `sync-status`, `sync-check`

    Cleanup:
        `plan-cleanup``, `clean`

    Manifest repair:
        `plan-manifests``, `repair-manifests`

    Setup / teardown:
        `setup-extensions``, `remove-extensions``, `sync-setup``, `sync-remove`

    Recovery:
        `recover-missing`

    Updates:
        `update-extensions``, `sync-update`

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import argparse
import json
from pathlib import Path

from vscode_cleanup import apply_cleanup_plan, deletable_paths_from_plan
from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_manifests import collect_reference_entries, collect_reference_names
from vscode_models import (
    CleanupStrategy,
    ManifestAction,
    SymlinkAction,
    SyncItemStatus,
    VscodeEdition,
)
from vscode_planner import plan_extension_cleanup, plan_insiders_symlink_state
from vscode_profiles import (
    ProfileManifestSafetyError,
    apply_manifest_repair_plan_safely,
    is_preserved_missing_profile_decision,
    plan_manifest_repairs,
)
from vscode_recovery import (
    apply_missing_extension_recovery,
    plan_missing_extension_recovery,
)
from vscode_scanner import scan_extension_root
from vscode_sync_apply import apply_extension_remove, apply_extension_setup
from vscode_sync_workflow import (
    apply_sync_remove,
    apply_sync_setup,
    collect_sync_status,
)
from vscode_update import apply_extension_update, build_extension_update_plan


def _parse_edition(value: str) -> VscodeEdition:
    """Parse a CLI edition argument into a ``VscodeEdition`` value."""

    try:
        return VscodeEdition(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"invalid edition '{value}' (expected: local, stable, insiders)"
        ) from exc


def _build_parser() -> argparse.ArgumentParser:
    """Build and return the top-level CLI argument parser."""

    parser = argparse.ArgumentParser(description="Python backend for the VS Code sync workflow.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    scan_parser = subparsers.add_parser("scan", help="Scan an extension root.")
    scan_parser.add_argument("extensions_dir", type=Path)
    scan_parser.add_argument(
        "--edition",
        type=_parse_edition,
        default=VscodeEdition.LOCAL,
        help="Label to attach to discovered installs.",
    )
    scan_parser.add_argument("--json", action="store_true", dest="json_output")

    refs_parser = subparsers.add_parser(
        "references",
        help="Collect manifest references relevant to an extension root.",
    )
    refs_parser.add_argument("extensions_dir", type=Path)
    refs_parser.add_argument(
        "--home",
        type=Path,
        default=None,
        help="Optional HOME override for profile discovery.",
    )
    refs_parser.add_argument("--json", action="store_true", dest="json_output")
    refs_parser.add_argument(
        "--entries",
        action="store_true",
        help="Emit structured reference entries instead of unique folder names.",
    )

    cleanup_parser = subparsers.add_parser(
        "plan-cleanup",
        help="Build a read-only cleanup plan for an extension root.",
    )
    cleanup_parser.add_argument("extensions_dir", type=Path)
    cleanup_parser.add_argument(
        "--home",
        type=Path,
        default=None,
        help="Optional HOME override for profile discovery.",
    )
    cleanup_parser.add_argument(
        "--strategy",
        choices=[strategy.value for strategy in CleanupStrategy],
        default=CleanupStrategy.NEWEST.value,
        help="Cleanup strategy to simulate.",
    )
    cleanup_parser.add_argument(
        "--no-respect-references",
        action="store_false",
        dest="respect_references",
        help="Ignore manifest references while building the plan.",
    )
    cleanup_parser.add_argument(
        "--prune-stale-references",
        action="store_true",
        help="Allow cleanup to ignore older manifest references shadowed by newer installs.",
    )
    cleanup_parser.add_argument("--json", action="store_true", dest="json_output")

    clean_parser = subparsers.add_parser(
        "clean",
        help="Dry-run or apply a cleanup plan for an extension root.",
    )
    clean_parser.add_argument("extensions_dir", type=Path)
    clean_parser.add_argument(
        "--home",
        type=Path,
        default=None,
        help="Optional HOME override for profile discovery.",
    )
    clean_parser.add_argument(
        "--strategy",
        choices=[strategy.value for strategy in CleanupStrategy],
        default=CleanupStrategy.NEWEST.value,
        help="Cleanup strategy to use.",
    )
    clean_parser.add_argument(
        "--no-respect-references",
        action="store_false",
        dest="respect_references",
        help="Ignore manifest references while building the cleanup plan.",
    )
    clean_parser.add_argument(
        "--prune-stale-references",
        action="store_true",
        help="Allow cleanup to ignore older manifest references shadowed by newer installs.",
    )
    clean_parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply the cleanup plan. Without this flag, the command is a dry-run.",
    )
    clean_parser.add_argument(
        "--yes",
        action="store_true",
        help="Skip confirmation when --apply is used.",
    )
    clean_parser.add_argument("--json", action="store_true", dest="json_output")

    manifest_parser = subparsers.add_parser(
        "plan-manifests",
        help="Build a read-only repair plan for root/profile manifests.",
    )
    manifest_parser.add_argument("stable_dir", type=Path)
    manifest_parser.add_argument("insiders_dir", type=Path)
    manifest_parser.add_argument("--home", type=Path, default=None)
    manifest_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    manifest_parser.add_argument("--json", action="store_true", dest="json_output")

    repair_manifest_parser = subparsers.add_parser(
        "repair-manifests",
        help="Apply a manifest repair plan in place.",
    )
    repair_manifest_parser.add_argument("stable_dir", type=Path)
    repair_manifest_parser.add_argument("insiders_dir", type=Path)
    repair_manifest_parser.add_argument("--home", type=Path, default=None)
    repair_manifest_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    repair_manifest_parser.add_argument("--json", action="store_true", dest="json_output")

    setup_parser = subparsers.add_parser(
        "setup-extensions",
        help="Apply symlink repair and manifest reconciliation.",
    )
    setup_parser.add_argument("stable_dir", type=Path)
    setup_parser.add_argument("insiders_dir", type=Path)
    setup_parser.add_argument("--home", type=Path, default=None)
    setup_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    setup_parser.add_argument("--json", action="store_true", dest="json_output")

    remove_parser = subparsers.add_parser(
        "remove-extensions",
        help="Remove sync-managed Insiders extension symlinks.",
    )
    remove_parser.add_argument("stable_dir", type=Path)
    remove_parser.add_argument("insiders_dir", type=Path)
    remove_parser.add_argument("--home", type=Path, default=None)
    remove_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    remove_parser.add_argument("--json", action="store_true", dest="json_output")

    ext_status_parser = subparsers.add_parser(
        "extension-status",
        help="Print a combined symlink and manifest status report.",
    )
    ext_status_parser.add_argument("stable_dir", type=Path)
    ext_status_parser.add_argument("insiders_dir", type=Path)
    ext_status_parser.add_argument("--home", type=Path, default=None)
    ext_status_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    ext_status_parser.add_argument("--json", action="store_true", dest="json_output")

    ext_check_parser = subparsers.add_parser(
        "extension-check",
        help="Print a combined extension health report.",
    )
    ext_check_parser.add_argument("stable_dir", type=Path)
    ext_check_parser.add_argument("insiders_dir", type=Path)
    ext_check_parser.add_argument("--home", type=Path, default=None)
    ext_check_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    ext_check_parser.add_argument(
        "--counts-only",
        action="store_true",
        help="Emit only machine-readable issue/warning counts.",
    )
    ext_check_parser.add_argument("--json", action="store_true", dest="json_output")

    recover_parser = subparsers.add_parser(
        "recover-missing",
        help="Reinstall missing manifest-requested extensions and recreate compatibility aliases.",
    )
    recover_parser.add_argument("stable_dir", type=Path)
    recover_parser.add_argument("insiders_dir", type=Path)
    recover_parser.add_argument("--home", type=Path, default=None)
    recover_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    recover_parser.add_argument("--apply", action="store_true")
    recover_parser.add_argument("--json", action="store_true", dest="json_output")

    update_parser = subparsers.add_parser(
        "update-extensions",
        help="Plan or apply the shared Stable/Insiders extension update workflow.",
    )
    update_parser.add_argument("stable_dir", type=Path)
    update_parser.add_argument("insiders_dir", type=Path)
    update_parser.add_argument("--home", type=Path, default=None)
    update_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    update_parser.add_argument("--skip-clean", action="store_true")
    update_parser.add_argument("--apply", action="store_true")
    update_parser.add_argument("--json", action="store_true", dest="json_output")

    sync_status_parser = subparsers.add_parser(
        "sync-status",
        help="Print the top-level sync status for files plus extensions.",
    )
    sync_status_parser.add_argument("stable_dir", type=Path)
    sync_status_parser.add_argument("insiders_dir", type=Path)
    sync_status_parser.add_argument("--home", type=Path, default=None)
    sync_status_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    sync_status_parser.add_argument("--json", action="store_true", dest="json_output")

    sync_check_parser = subparsers.add_parser(
        "sync-check",
        help="Print the top-level sync health report.",
    )
    sync_check_parser.add_argument("stable_dir", type=Path)
    sync_check_parser.add_argument("insiders_dir", type=Path)
    sync_check_parser.add_argument("--home", type=Path, default=None)
    sync_check_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    sync_check_parser.add_argument(
        "--counts-only",
        action="store_true",
        help="Emit only machine-readable issue/warning counts.",
    )
    sync_check_parser.add_argument("--json", action="store_true", dest="json_output")

    sync_setup_parser = subparsers.add_parser(
        "sync-setup",
        help="Apply the top-level setup workflow for files plus extensions.",
    )
    sync_setup_parser.add_argument("stable_dir", type=Path)
    sync_setup_parser.add_argument("insiders_dir", type=Path)
    sync_setup_parser.add_argument("--home", type=Path, default=None)
    sync_setup_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    sync_setup_parser.add_argument("--json", action="store_true", dest="json_output")

    sync_remove_parser = subparsers.add_parser(
        "sync-remove",
        help="Apply the top-level remove workflow for files plus extensions.",
    )
    sync_remove_parser.add_argument("stable_dir", type=Path)
    sync_remove_parser.add_argument("insiders_dir", type=Path)
    sync_remove_parser.add_argument("--home", type=Path, default=None)
    sync_remove_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    sync_remove_parser.add_argument("--json", action="store_true", dest="json_output")

    sync_update_parser = subparsers.add_parser(
        "sync-update",
        help="Plan or apply the top-level extension update workflow.",
    )
    sync_update_parser.add_argument("stable_dir", type=Path)
    sync_update_parser.add_argument("insiders_dir", type=Path)
    sync_update_parser.add_argument("--home", type=Path, default=None)
    sync_update_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    sync_update_parser.add_argument("--skip-clean", action="store_true")
    sync_update_parser.add_argument("--apply", action="store_true")
    sync_update_parser.add_argument("--json", action="store_true", dest="json_output")

    links_parser = subparsers.add_parser(
        "plan-links",
        help="Build a read-only Stable/Insiders symlink drift plan.",
    )
    links_parser.add_argument("stable_dir", type=Path)
    links_parser.add_argument("insiders_dir", type=Path)
    links_parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        help="Shell-style exclusion pattern. Can be passed multiple times.",
    )
    links_parser.add_argument("--json", action="store_true", dest="json_output")

    return parser


def _emit_json(payload: object) -> int:
    """Print a JSON payload and return a successful exit code."""

    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def _print_section(title: str) -> None:
    """Print a consistently formatted section title."""

    print(title)


def _print_metric(label: str, value: object) -> None:
    """Print one aligned key/value metric."""

    print(f"  {label:<24} {value}")


def _print_list_item(value: object, *, prefix: str = "-") -> None:
    """Print one indented list item."""

    print(f"    {prefix} {value}")


def _run_scan(args: argparse.Namespace) -> int:
    """Handle the `scan` subcommand."""

    installs = scan_extension_root(args.extensions_dir, edition=args.edition)
    if args.json_output:
        return _emit_json([install.to_dict() for install in installs])

    for install in installs:
        status = "symlink" if install.is_symlink else "directory"
        version = install.version or "-"
        suffix = ""
        if install.is_symlink:
            suffix = f" -> {install.symlink_target}"
            if not install.target_exists:
                suffix += " [broken]"
        print(
            f"{install.folder_name}\tcore={install.core_name}\tversion={version}"
            f"\ttype={status}{suffix}"
        )
    return 0


def _run_references(args: argparse.Namespace) -> int:
    """Handle the `references` subcommand."""

    config = VscodePathsConfig.from_home(args.home) if args.home else VscodePathsConfig.from_home()

    if args.entries:
        entries = collect_reference_entries(args.extensions_dir, config=config)
        if args.json_output:
            return _emit_json([entry.to_dict() for entry in entries])
        for entry in entries:
            print(f"{entry.folder_name}\t{entry.source_kind}\t{entry.manifest_path}")
        return 0

    names = collect_reference_names(args.extensions_dir, config=config)
    if args.json_output:
        return _emit_json(names)
    for name in names:
        print(name)
    return 0


def _run_plan_cleanup(args: argparse.Namespace) -> int:
    """Handle the `plan-cleanup` subcommand."""

    config = VscodePathsConfig.from_home(args.home) if args.home else VscodePathsConfig.from_home()
    plan = plan_extension_cleanup(
        args.extensions_dir,
        strategy=CleanupStrategy(args.strategy),
        respect_references=args.respect_references,
        prune_stale_references=args.prune_stale_references,
        config=config,
    )

    if args.json_output:
        return _emit_json(plan.to_dict())

    _print_section("Cleanup Plan")
    _print_metric("Root", plan.root)
    _print_metric("Strategy", plan.strategy.value)
    _print_metric("Respect references", plan.respect_references)
    _print_metric("Prune stale refs", plan.prune_stale_references)
    _print_metric("Duplicate groups", plan.duplicate_group_count)
    _print_metric("Planned quarantine", plan.planned_deletion_count)
    _print_metric("Protected refs", len(plan.protected_reference_names))
    _print_metric("Stale refs", len(plan.stale_reference_names))
    for group in plan.groups:
        _print_section(f"  Group: {group.core_name}")
        for decision in group.decisions:
            print(f"    - {decision.folder_name:<52} {decision.action.value} ({decision.reason})")
    return 0


def _run_plan_links(args: argparse.Namespace) -> int:
    """Handle the `plan-links` subcommand."""

    exclude_patterns = tuple(args.exclude or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)
    plan = plan_insiders_symlink_state(
        args.stable_dir,
        args.insiders_dir,
        exclude_patterns=exclude_patterns,
    )

    if args.json_output:
        return _emit_json(plan.to_dict())

    print(f"stable_dir={plan.stable_dir}")
    print(f"insiders_dir={plan.insiders_dir}")
    print(f"expected_links={plan.expected_link_count}")
    print(f"linked={plan.linked_count}")
    print(f"missing={plan.missing_count}")
    print(f"broken={plan.broken_count}")
    print(f"wrong_target={plan.wrong_target_count}")
    print(f"unmanaged={plan.unmanaged_count}")
    print(f"excluded={plan.excluded_count}")
    print(f"stale_managed={plan.stale_managed_count}")
    for decision in plan.decisions:
        print(f"  - {decision.folder_name}\t{decision.action.value}\treason={decision.reason}")
    return 0


def _run_clean(args: argparse.Namespace) -> int:
    """Handle the `clean` subcommand."""

    config = VscodePathsConfig.from_home(args.home) if args.home else VscodePathsConfig.from_home()
    plan = plan_extension_cleanup(
        args.extensions_dir,
        strategy=CleanupStrategy(args.strategy),
        respect_references=args.respect_references,
        prune_stale_references=args.prune_stale_references,
        config=config,
    )

    if not args.apply:
        if args.json_output:
            return _emit_json(plan.to_dict())

        _print_section("Cleanup Preview")
        _print_metric("Root", plan.root)
        _print_metric("Strategy", plan.strategy.value)
        _print_metric("Mode", "dry-run")
        if plan.respect_references:
            _print_metric("Reference guard", "enabled")
            _print_metric("Raw references", len(plan.raw_reference_names))
            _print_metric("Protected refs", len(plan.protected_reference_names))
            if plan.stale_reference_names:
                mode = "enabled" if plan.prune_stale_references else "disabled"
                _print_metric("Stale ref pruning", mode)
                _print_metric("Detected stale refs", len(plan.stale_reference_names))
        else:
            _print_metric("Reference guard", "disabled")

        _print_metric("Duplicate groups", plan.duplicate_group_count)
        _print_metric("Planned quarantine", plan.planned_deletion_count)
        for path in deletable_paths_from_plan(plan):
            _print_list_item(path)
        return 0

    deletable_paths = deletable_paths_from_plan(plan)
    if not deletable_paths:
        if args.json_output:
            return _emit_json(
                {
                    "plan": plan.to_dict(),
                    "apply_report": {
                        "root": str(plan.root),
                        "quarantine_root": None,
                        "quarantined_paths": [],
                        "deleted_paths": [],
                        "failed_paths": [],
                        "quarantined_count": 0,
                        "deleted_count": 0,
                        "failed_count": 0,
                    },
                }
            )
        _print_section("Cleanup Apply")
        _print_metric("Result", "no folders selected for quarantine")
        return 0

    if not args.yes:
        _print_section("Cleanup Apply")
        _print_metric("Action", "quarantine selected folders")
        for path in deletable_paths:
            _print_list_item(path)
        response = input("Proceed with quarantine move? [y/N] ").strip().lower()
        if response not in {"y", "yes"}:
            print("Aborted by user.")
            return 0

    report = apply_cleanup_plan(plan)
    if args.json_output:
        return _emit_json(
            {
                "plan": plan.to_dict(),
                "apply_report": report.to_dict(),
            }
        )

    _print_section("Cleanup Result")
    _print_metric("Quarantined", len(report.quarantined_paths))
    _print_metric("Quarantine root", report.quarantine_root)
    _print_metric("Failed", len(report.failed_paths))
    for path in report.quarantined_paths:
        _print_list_item(f"quarantined {path}")
    for path in report.failed_paths:
        _print_list_item(f"failed {path}")
    return 0 if not report.failed_paths else 1


def _resolve_shared_args(
    args: argparse.Namespace,
) -> tuple[VscodePathsConfig, tuple[str, ...]]:
    """Resolve shared HOME/configuration arguments used by multi-root commands."""

    config = (
        VscodePathsConfig.from_home(args.home)
        if getattr(args, "home", None)
        else VscodePathsConfig.from_home()
    )
    exclude_patterns = tuple(getattr(args, "exclude", None) or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)
    return config, exclude_patterns


def _run_plan_manifests(args: argparse.Namespace) -> int:
    """Handle the `plan-manifests` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    plan = plan_manifest_repairs(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )

    if args.json_output:
        return _emit_json(plan.to_dict())

    print(f"manifest_updates={plan.update_count}")
    print(f"manifest_removals={plan.remove_count}")
    print(f"manifest_keeps={plan.keep_count}")
    print(f"manifest_preserved_missing_profiles={plan.preserved_missing_profile_count}")
    for decision in plan.decisions:
        if decision.action == ManifestAction.KEEP and not is_preserved_missing_profile_decision(
            decision
        ):
            continue
        label = decision.action.value
        if is_preserved_missing_profile_decision(decision):
            label = "preserve"
        print(
            f"{label}\t{decision.manifest_path}\t"
            f"{decision.current_folder_name or '-'} -> {decision.desired_folder_name or '-'}"
        )
    return 0


def _run_repair_manifests(args: argparse.Namespace) -> int:
    """Handle the `repair-manifests` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    plan = plan_manifest_repairs(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    try:
        report = apply_manifest_repair_plan_safely(plan)
    except ProfileManifestSafetyError as exc:
        print(f"Manifest repair aborted: {exc}")
        return 1

    if args.json_output:
        return _emit_json({"plan": plan.to_dict(), "apply_report": report.to_dict()})

    print(f"Updated entries: {report.updated_entries}")
    print(f"Removed entries: {report.removed_entries}")
    print(f"Preserved unresolved profile entries: {plan.preserved_missing_profile_count}")
    print(f"Touched manifests: {len(report.touched_manifests)}")
    for path in report.touched_manifests:
        print(f"  - {path}")
    return 0


def _combined_extension_state(args: argparse.Namespace):
    """Return the symlink and manifest plans for the selected roots."""

    config, exclude_patterns = _resolve_shared_args(args)
    symlink_plan = plan_insiders_symlink_state(
        args.stable_dir,
        args.insiders_dir,
        exclude_patterns=exclude_patterns,
    )
    manifest_plan = plan_manifest_repairs(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    return symlink_plan, manifest_plan


def _extension_health_counts(symlink_plan, manifest_plan) -> tuple[int, int]:
    """Return issue and warning counts for extension health checks."""

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


def _run_setup_extensions(args: argparse.Namespace) -> int:
    """Handle the `setup-extensions` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    try:
        report = apply_extension_setup(
            args.stable_dir,
            args.insiders_dir,
            config=config,
            exclude_patterns=exclude_patterns,
        )
    except ProfileManifestSafetyError as exc:
        print(f"Setup aborted: {exc}")
        return 1
    if args.json_output:
        return _emit_json(report.to_dict())

    _print_section("Setup Result")
    _print_metric("Linked", report.linked_count)
    _print_metric("Relinked", report.relinked_count)
    _print_metric("Migrated unmanaged", report.migrated_count)
    _print_metric("Removed stale", report.removed_stale_symlink_count)
    _print_metric("Skipped excluded", report.skipped_excluded_symlink_count)
    _print_metric("Manifest updates", report.manifest_apply_report.updated_entries)
    _print_metric("Manifest removals", report.manifest_apply_report.removed_entries)
    plan = plan_manifest_repairs(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    _print_metric("Preserved profile drift", plan.preserved_missing_profile_count)
    return 0


def _run_remove_extensions(args: argparse.Namespace) -> int:
    """Handle the `remove-extensions` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    report = apply_extension_remove(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    if args.json_output:
        return _emit_json(report.to_dict())

    print(f"Removed legacy root symlinks: {report.removed_root_symlink_count}")
    print(f"Removed entry symlinks: {report.removed_entry_symlink_count}")
    print(f"Skipped real directories: {report.skipped_real_dir_count}")
    print(f"Failed paths: {len(report.failed_paths)}")
    for path in report.failed_paths:
        print(f"  - failed\t{path}")
    return 0 if not report.failed_paths else 1


def _run_extension_status(args: argparse.Namespace) -> int:
    """Handle the `extension-status` subcommand."""

    symlink_plan, manifest_plan = _combined_extension_state(args)
    if args.json_output:
        return _emit_json(
            {
                "symlink_plan": symlink_plan.to_dict(),
                "manifest_plan": manifest_plan.to_dict(),
            }
        )

    _print_section("Extensions")
    _print_metric("Linked", f"{symlink_plan.linked_count}/{symlink_plan.expected_link_count}")
    _print_metric("Missing", symlink_plan.missing_count)
    _print_metric("Broken", symlink_plan.broken_count)
    _print_metric("Unmanaged", symlink_plan.unmanaged_count)
    _print_metric("Stale", symlink_plan.stale_managed_count)
    _print_metric("Excluded", symlink_plan.excluded_count)
    if symlink_plan.excluded_symlinked_count:
        _print_metric("Excluded symlinked", symlink_plan.excluded_symlinked_count)
    if manifest_plan.update_count or manifest_plan.remove_count:
        _print_metric(
            "Manifest drift",
            f"{manifest_plan.update_count} update candidate(s), {manifest_plan.remove_count} removal candidate(s)",
        )
    if manifest_plan.preserved_missing_profile_count:
        _print_metric("Preserved profile drift", manifest_plan.preserved_missing_profile_count)

    for decision in symlink_plan.decisions:
        if decision.action == SymlinkAction.LINKED or decision.action == SymlinkAction.EXCLUDED:
            continue
        _print_list_item(f"{decision.folder_name} [{decision.action.value}] {decision.reason}")

    for decision in manifest_plan.decisions:
        if decision.action == ManifestAction.KEEP and not is_preserved_missing_profile_decision(
            decision
        ):
            continue
        label = decision.action.value
        if is_preserved_missing_profile_decision(decision):
            label = "preserve"
        _print_list_item(
            f"manifest {label}: {decision.manifest_path} "
            f"{decision.current_folder_name or '-'} -> {decision.desired_folder_name or '-'}"
        )
    return 0


def _run_extension_check(args: argparse.Namespace) -> int:
    """Handle the `extension-check` subcommand."""

    symlink_plan, manifest_plan = _combined_extension_state(args)
    issues, warnings = _extension_health_counts(symlink_plan, manifest_plan)

    if args.json_output:
        return _emit_json(
            {
                "issues": issues,
                "warnings": warnings,
                "symlink_plan": symlink_plan.to_dict(),
                "manifest_plan": manifest_plan.to_dict(),
            }
        )

    if args.counts_only:
        print(f"ISSUES={issues}")
        print(f"WARNINGS={warnings}")
        return 0

    _print_section("Extensions")
    _print_metric("Linked", f"{symlink_plan.linked_count}/{symlink_plan.expected_link_count}")
    _print_metric("Missing", symlink_plan.missing_count)
    _print_metric("Broken", symlink_plan.broken_count)
    _print_metric("Unmanaged", symlink_plan.unmanaged_count)
    _print_metric("Stale", symlink_plan.stale_managed_count)
    if manifest_plan.update_count or manifest_plan.remove_count:
        _print_metric("Manifest updates", manifest_plan.update_count)
        _print_metric("Manifest removals", manifest_plan.remove_count)
    if manifest_plan.preserved_missing_profile_count:
        _print_metric("Preserved profile drift", manifest_plan.preserved_missing_profile_count)
    print(f"ISSUES={issues}")
    print(f"WARNINGS={warnings}")
    return 0 if issues == 0 else 1


def _run_sync_status(args: argparse.Namespace) -> int:
    """Handle the `sync-status` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    report = collect_sync_status(
        args.stable_dir,
        args.insiders_dir,
        home=config.home,
        exclude_patterns=exclude_patterns,
    )

    if args.json_output:
        return _emit_json(report.to_dict())

    _print_section("Items")
    for item in report.items:
        if item.status == SyncItemStatus.SYNCED:
            print(f"  [SYNCED]  {item.label:<12} {item.source_path}")
        elif item.status == SyncItemStatus.SYMLINK_BROKEN:
            print(f"  [BROKEN]  {item.label:<12} {item.link_target or '-'} (target missing)")
        elif item.status == SyncItemStatus.SYMLINK_WRONG:
            print(
                f"  [WRONG]   {item.label:<12} {item.link_target or '-'} "
                f"(expected: {item.source_path})"
            )
        elif item.status == SyncItemStatus.INDEPENDENT:
            print(f"  [INDEP]   {item.label:<12} Independent file/directory")
        elif item.status == SyncItemStatus.MISSING:
            print(f"  [MISS]    {item.label:<12} Target does not exist")
        else:
            print(f"  [NO SRC]  {item.label:<12} Source not found: {item.source_path}")

    _print_section("Extensions")
    _print_metric(
        "Linked",
        f"{report.symlink_plan.linked_count}/{report.symlink_plan.expected_link_count}",
    )
    _print_metric("Missing", report.symlink_plan.missing_count)
    _print_metric("Broken", report.symlink_plan.broken_count)
    _print_metric("Unmanaged", report.symlink_plan.unmanaged_count)
    _print_metric("Stale", report.symlink_plan.stale_managed_count)
    _print_metric("Excluded", report.symlink_plan.excluded_count)
    if report.manifest_plan.update_count or report.manifest_plan.remove_count:
        _print_metric(
            "Manifest drift",
            f"{report.manifest_plan.update_count} update candidate(s), {report.manifest_plan.remove_count} removal candidate(s)",
        )
    if report.manifest_plan.preserved_missing_profile_count:
        _print_metric(
            "Preserved profile drift",
            report.manifest_plan.preserved_missing_profile_count,
        )
    return 0


def _run_sync_check(args: argparse.Namespace) -> int:
    """Handle the `sync-check` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    report = collect_sync_status(
        args.stable_dir,
        args.insiders_dir,
        home=config.home,
        exclude_patterns=exclude_patterns,
    )

    if args.json_output:
        return _emit_json(report.to_dict())

    if args.counts_only:
        print(f"ISSUES={report.issues}")
        print(f"WARNINGS={report.warnings}")
        return 0

    _print_section("Items")
    for item in report.items:
        print(f"  {item.label}")
        if item.status == SyncItemStatus.SYNCED:
            _print_metric("status", "ok")
            _print_metric("reason", "symlink_valid")
        elif item.status == SyncItemStatus.SYMLINK_BROKEN:
            _print_metric("status", "error")
            _print_metric("reason", f"broken_symlink ({item.target_path})")
        elif item.status == SyncItemStatus.SYMLINK_WRONG:
            _print_metric("status", "warn")
            _print_metric("reason", f"wrong_symlink ({item.link_target or '-'})")
        elif item.status == SyncItemStatus.INDEPENDENT:
            _print_metric("status", "info")
            _print_metric("reason", "independent_path")
        elif item.status == SyncItemStatus.MISSING:
            _print_metric("status", "info")
            _print_metric("reason", "target_missing")
        else:
            _print_metric("status", "error")
            _print_metric("reason", f"source_missing ({item.source_path})")

    _print_section("Extensions")
    _print_metric(
        "Linked",
        f"{report.symlink_plan.linked_count}/{report.symlink_plan.expected_link_count}",
    )
    _print_metric("Missing", report.symlink_plan.missing_count)
    _print_metric("Broken", report.symlink_plan.broken_count)
    _print_metric("Unmanaged", report.symlink_plan.unmanaged_count)
    _print_metric("Stale", report.symlink_plan.stale_managed_count)
    if report.manifest_plan.update_count or report.manifest_plan.remove_count:
        _print_metric("Manifest updates", report.manifest_plan.update_count)
        _print_metric("Manifest removals", report.manifest_plan.remove_count)
    if report.manifest_plan.preserved_missing_profile_count:
        _print_metric(
            "Preserved profile drift",
            report.manifest_plan.preserved_missing_profile_count,
        )
    _print_section("Health")
    _print_metric("Issues", report.issues)
    _print_metric("Warnings", report.warnings)
    print(f"ISSUES={report.issues}")
    print(f"WARNINGS={report.warnings}")
    return 0 if report.issues == 0 else 1


def _run_sync_setup(args: argparse.Namespace) -> int:
    """Handle the `sync-setup` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    try:
        report = apply_sync_setup(
            args.stable_dir,
            args.insiders_dir,
            home=config.home,
            exclude_patterns=exclude_patterns,
        )
    except ProfileManifestSafetyError as exc:
        print(f"Setup aborted: {exc}")
        return 1
    if args.json_output:
        return _emit_json(report.to_dict())

    _print_section("Setup Result")
    _print_metric("Synced items", report.synced_count)
    _print_metric("Skipped items", report.skipped_count)
    _print_metric("Failed items", report.failed_count)
    _print_metric("Linked", report.extension_report.linked_count)
    _print_metric("Relinked", report.extension_report.relinked_count)
    _print_metric("Migrated unmanaged", report.extension_report.migrated_count)
    _print_metric("Removed stale", report.extension_report.removed_stale_symlink_count)
    _print_metric("Skipped excluded", report.extension_report.skipped_excluded_symlink_count)
    _print_metric(
        "Manifest updates",
        report.extension_report.manifest_apply_report.updated_entries,
    )
    _print_metric(
        "Manifest removals",
        report.extension_report.manifest_apply_report.removed_entries,
    )
    return 0 if report.failed_count == 0 else 1


def _run_sync_remove(args: argparse.Namespace) -> int:
    """Handle the `sync-remove` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    report = apply_sync_remove(
        args.stable_dir,
        args.insiders_dir,
        home=config.home,
        exclude_patterns=exclude_patterns,
    )
    if args.json_output:
        return _emit_json(report.to_dict())

    _print_section("Remove Result")
    _print_metric("Restored items", report.restored_count)
    _print_metric("Removed broken", report.removed_broken_count)
    _print_metric("Skipped items", report.skipped_count)
    _print_metric("Failed items", report.failed_count)
    _print_metric("Removed root symlink", report.extension_report.removed_root_symlink_count)
    _print_metric("Removed entry symlinks", report.extension_report.removed_entry_symlink_count)
    _print_metric("Skipped real dirs", report.extension_report.skipped_real_dir_count)
    _print_metric("Failed paths", len(report.extension_report.failed_paths))
    return 0 if report.failed_count == 0 and not report.extension_report.failed_paths else 1


def _run_update_extensions(args: argparse.Namespace) -> int:
    """Handle the `update-extensions` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    plan = build_extension_update_plan(
        args.stable_dir,
        args.insiders_dir,
        skip_clean=args.skip_clean,
        config=config,
        exclude_patterns=exclude_patterns,
    )

    if not args.apply:
        if args.json_output:
            return _emit_json(plan.to_dict())

        _print_section("Update Plan")
        _print_metric("Shared root", plan.stable_dir)
        if plan.skip_clean:
            _print_metric("Cleanup", "disabled")
        else:
            _print_metric("Cleanup", "enabled")
            _print_metric("Duplicate groups", plan.cleanup_plan.duplicate_group_count)
            _print_metric("Current quarantine plan", plan.cleanup_plan.planned_deletion_count)
            _print_metric(
                "Manifest guard",
                "strict" if not plan.cleanup_plan.prune_stale_references else "prune stale refs",
            )
            _print_metric("Cleanup source", "live post-update rescan")
        if plan.native_excluded_extension_ids:
            _print_metric("Excluded native checks", len(plan.native_excluded_extension_ids))
            for extension_id in plan.native_excluded_extension_ids:
                _print_list_item(extension_id)
        else:
            _print_metric("Excluded native checks", 0)
        _print_metric("Insiders root", plan.insiders_dir)
        if plan.symlink_plan.missing_count:
            _print_metric("Missing links", plan.symlink_plan.missing_count)
        if plan.symlink_plan.unmanaged_count:
            _print_metric("Unmanaged dirs", plan.symlink_plan.unmanaged_count)
        if plan.manifest_plan.update_count or plan.manifest_plan.remove_count:
            _print_metric(
                "Manifest drift",
                f"{plan.manifest_plan.update_count} update candidate(s), {plan.manifest_plan.remove_count} removal candidate(s)",
            )
        print()
        print("[OK] Dry run complete. No changes were made.")
        return 0

    try:
        report = apply_extension_update(
            plan,
            config=config,
            exclude_patterns=exclude_patterns,
        )
    except ProfileManifestSafetyError as exc:
        print(f"Update aborted: {exc}")
        return 1
    if args.json_output:
        return _emit_json({"plan": plan.to_dict(), "report": report.to_dict()})

    _print_section("Update Result")
    _print_metric("Shared update", "ok" if report.shared_update_succeeded else "failed")
    _print_metric("Shared updated", len(report.shared_updated_extension_ids))
    for extension_id in report.shared_updated_extension_ids:
        _print_list_item(f"updated {extension_id}")
    _print_metric("Cleanup quarantined", report.cleanup_quarantined_count)
    _print_metric("Cleanup failures", report.cleanup_failed_count)
    _print_metric("Excluded attempted", len(report.excluded_updates_attempted))
    _print_metric("Excluded updated", len(report.excluded_updates_applied))
    _print_metric("Excluded already current", len(report.excluded_updates_current))
    for extension_id in report.excluded_updates_applied:
        _print_list_item(f"updated {extension_id}")
    for extension_id in report.excluded_updates_current:
        _print_list_item(f"current {extension_id}")
    if report.excluded_updates_failed:
        _print_metric("Excluded failed", len(report.excluded_updates_failed))
        for extension_id in report.excluded_updates_failed:
            _print_list_item(f"failed {extension_id}")
    else:
        _print_metric("Excluded failed", 0)
    _print_metric("Linked", report.setup_report.linked_count)
    _print_metric("Relinked", report.setup_report.relinked_count)
    _print_metric("Migrated unmanaged", report.setup_report.migrated_count)
    _print_metric("Removed stale", report.setup_report.removed_stale_symlink_count)
    _print_metric("Manifest updates", report.setup_report.manifest_apply_report.updated_entries)
    _print_metric("Manifest removals", report.setup_report.manifest_apply_report.removed_entries)
    _print_metric(
        "Final links",
        f"{report.final_symlink_plan.linked_count}/{report.final_symlink_plan.expected_link_count}",
    )
    _print_metric("Final missing", report.final_symlink_plan.missing_count)
    _print_metric("Final broken", report.final_symlink_plan.broken_count)
    _print_metric("Final unmanaged", report.final_symlink_plan.unmanaged_count)
    _print_metric("Final stale", report.final_symlink_plan.stale_managed_count)
    if report.final_manifest_plan.update_count or report.final_manifest_plan.remove_count:
        _print_metric(
            "Manifest drift",
            f"{report.final_manifest_plan.update_count} update candidate(s), {report.final_manifest_plan.remove_count} removal candidate(s)",
        )
    return 0


def _run_recover_missing(args: argparse.Namespace) -> int:
    """Handle the `recover-missing` subcommand."""

    config, exclude_patterns = _resolve_shared_args(args)
    plan = plan_missing_extension_recovery(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )

    if not args.apply:
        if args.json_output:
            return _emit_json(plan.to_dict())

        print(f"Requests: {len(plan.requests)}")
        print(f"Install tasks: {len(plan.install_tasks)}")
        print(f"Alias tasks (available now): {len(plan.alias_tasks)}")
        for task in plan.install_tasks:
            print(
                f"  - install\t{task.installer}\t{task.install_root}\t"
                f"{task.install_spec}\trequests={task.request_count}\t"
                f"profile={task.profile_name or '-'}"
            )
        for task in plan.alias_tasks:
            print(f"  - alias\t{task.alias_path}\t->\t{task.target_path}")
        return 0

    report = apply_missing_extension_recovery(
        plan,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    if args.json_output:
        return _emit_json(
            {
                "plan": plan.to_dict(),
                "report": report.to_dict(),
            }
        )

    print(f"Attempted installs: {len(report.attempted_installs)}")
    print(f"Successful installs: {len(report.successful_installs)}")
    print(f"Failed installs: {len(report.failed_installs)}")
    print(f"Created aliases: {len(report.created_aliases)}")
    print(f"Failed aliases: {len(report.failed_aliases)}")
    print(f"Setup linked: {report.setup_linked_count}")
    print(f"Setup relinked: {report.setup_relinked_count}")
    print(f"Setup migrated: {report.setup_migrated_count}")
    return 0 if not report.failed_installs and not report.failed_aliases else 1


def main(argv: list[str] | None = None) -> int:
    """Run the VS Code sync Python CLI."""

    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "scan":
        return _run_scan(args)
    if args.command == "references":
        return _run_references(args)
    if args.command == "plan-cleanup":
        return _run_plan_cleanup(args)
    if args.command == "plan-links":
        return _run_plan_links(args)
    if args.command == "clean":
        return _run_clean(args)
    if args.command == "plan-manifests":
        return _run_plan_manifests(args)
    if args.command == "repair-manifests":
        return _run_repair_manifests(args)
    if args.command == "setup-extensions":
        return _run_setup_extensions(args)
    if args.command == "remove-extensions":
        return _run_remove_extensions(args)
    if args.command == "extension-status":
        return _run_extension_status(args)
    if args.command == "extension-check":
        return _run_extension_check(args)
    if args.command == "sync-status":
        return _run_sync_status(args)
    if args.command == "sync-check":
        return _run_sync_check(args)
    if args.command == "sync-setup":
        return _run_sync_setup(args)
    if args.command == "sync-remove":
        return _run_sync_remove(args)
    if args.command == "recover-missing":
        return _run_recover_missing(args)
    if args.command in {"update-extensions", "sync-update"}:
        return _run_update_extensions(args)

    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
