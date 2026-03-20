# ============================================================================ #
"""
Command-line interface for the VS Code sync Python backend.

Author: XtremeXSPC
Version:
"""
# ============================================================================ #

from __future__ import annotations

import argparse
import json
from pathlib import Path

from vscode_config import DEFAULT_EXTENSION_EXCLUDE_PATTERNS, VscodePathsConfig
from vscode_cleanup import apply_cleanup_plan, deletable_paths_from_plan
from vscode_manifests import collect_reference_entries, collect_reference_names
from vscode_models import CleanupStrategy, ManifestAction, SymlinkAction, VscodeEdition
from vscode_planner import plan_extension_cleanup, plan_insiders_symlink_state
from vscode_profiles import (
    ProfileManifestSafetyError,
    apply_manifest_repair_plan_safely,
    is_preserved_missing_profile_decision,
    plan_manifest_repairs,
)
from vscode_recovery import apply_missing_extension_recovery, plan_missing_extension_recovery
from vscode_scanner import scan_extension_root
from vscode_sync_apply import apply_extension_setup


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
    parser = argparse.ArgumentParser(
        description="Read-only Python tools for VS Code extension sync analysis."
    )
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


def _run_scan(args: argparse.Namespace) -> int:
    """Handle the ``scan`` subcommand."""
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
    """Handle the ``references`` subcommand."""
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
    """Handle the ``plan-cleanup`` subcommand."""
    config = VscodePathsConfig.from_home(args.home) if args.home else VscodePathsConfig.from_home()
    plan = plan_extension_cleanup(
        args.extensions_dir,
        strategy=CleanupStrategy(args.strategy),
        respect_references=args.respect_references,
        config=config,
    )

    if args.json_output:
        return _emit_json(plan.to_dict())

    print(f"root={plan.root}")
    print(f"strategy={plan.strategy.value}")
    print(f"duplicate_groups={plan.duplicate_group_count}")
    print(f"planned_deletions={plan.planned_deletion_count}")
    print(f"protected_references={len(plan.protected_reference_names)}")
    print(f"stale_references={len(plan.stale_reference_names)}")
    for group in plan.groups:
        print(f"[group] {group.core_name}")
        for decision in group.decisions:
            print(
                f"  - {decision.folder_name}\t{decision.action.value}"
                f"\treason={decision.reason}"
            )
    return 0


def _run_plan_links(args: argparse.Namespace) -> int:
    """Handle the ``plan-links`` subcommand."""
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
    """Handle the ``clean`` subcommand."""
    config = VscodePathsConfig.from_home(args.home) if args.home else VscodePathsConfig.from_home()
    plan = plan_extension_cleanup(
        args.extensions_dir,
        strategy=CleanupStrategy(args.strategy),
        respect_references=args.respect_references,
        config=config,
    )

    if not args.apply:
        if args.json_output:
            return _emit_json(plan.to_dict())

        print(f"Scanning VS Code extensions in: {plan.root}")
        print(f"Strategy: {plan.strategy.value}")
        print("Running in DRY-RUN mode (no quarantine moves).")
        if plan.respect_references:
            print("Reference protection enabled.")
            print(f"Collected {len(plan.raw_reference_names)} raw reference entries.")
            print(
                f"Protected {len(plan.protected_reference_names)} installed reference entries for this directory."
            )
            if plan.stale_reference_names:
                print(
                    f"Ignored {len(plan.stale_reference_names)} stale referenced version(s) shadowed by newer installed refs."
                )
        else:
            print("Reference protection disabled.")

        print(f"Duplicate groups found: {plan.duplicate_group_count}")
        print(f"Planned quarantine moves: {plan.planned_deletion_count}")
        for path in deletable_paths_from_plan(plan):
            print(f"  - {path}")
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
        print("No extension folders selected for quarantine.")
        return 0

    if not args.yes:
        print("Folders selected for quarantine:")
        for path in deletable_paths:
            print(f"  - {path}")
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

    print(f"Quarantined: {len(report.quarantined_paths)}")
    print(f"Quarantine root: {report.quarantine_root}")
    print(f"Failed: {len(report.failed_paths)}")
    for path in report.quarantined_paths:
        print(f"  - quarantined {path}")
    for path in report.failed_paths:
        print(f"  - failed  {path}")
    return 0 if not report.failed_paths else 1


def _resolve_shared_args(args: argparse.Namespace) -> tuple[VscodePathsConfig, tuple[str, ...]]:
    """Resolve shared HOME/configuration arguments used by multi-root commands."""
    config = VscodePathsConfig.from_home(args.home) if getattr(args, "home", None) else VscodePathsConfig.from_home()
    exclude_patterns = tuple(getattr(args, "exclude", None) or DEFAULT_EXTENSION_EXCLUDE_PATTERNS)
    return config, exclude_patterns


def _run_plan_manifests(args: argparse.Namespace) -> int:
    """Handle the ``plan-manifests`` subcommand."""
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
    print(
        "manifest_preserved_missing_profiles="
        f"{plan.preserved_missing_profile_count}"
    )
    for decision in plan.decisions:
        if decision.action == ManifestAction.KEEP and not is_preserved_missing_profile_decision(decision):
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
    """Handle the ``repair-manifests`` subcommand."""
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
    print(
        "Preserved unresolved profile entries: "
        f"{plan.preserved_missing_profile_count}"
    )
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


def _run_setup_extensions(args: argparse.Namespace) -> int:
    """Handle the ``setup-extensions`` subcommand."""
    config, exclude_patterns = _resolve_shared_args(args)
    report = apply_extension_setup(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    if args.json_output:
        return _emit_json(report.to_dict())

    print(f"Linked: {report.linked_count}")
    print(f"Relinked: {report.relinked_count}")
    print(f"Migrated unmanaged dirs: {report.migrated_count}")
    print(f"Removed stale symlinks: {report.removed_stale_symlink_count}")
    print(f"Skipped excluded symlinks: {report.skipped_excluded_symlink_count}")
    print("Manifest updates: 0 (read-only mode)")
    print("Manifest removals: 0 (read-only mode)")
    plan = plan_manifest_repairs(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    print(
        "Preserved unresolved profile entries: "
        f"{plan.preserved_missing_profile_count}"
    )
    return 0


def _run_extension_status(args: argparse.Namespace) -> int:
    """Handle the ``extension-status`` subcommand."""
    symlink_plan, manifest_plan = _combined_extension_state(args)
    if args.json_output:
        return _emit_json(
            {
                "symlink_plan": symlink_plan.to_dict(),
                "manifest_plan": manifest_plan.to_dict(),
            }
        )

    print(
        "Extensions  "
        f"{symlink_plan.linked_count}/{symlink_plan.expected_link_count} linked, "
        f"{symlink_plan.missing_count} missing, "
        f"{symlink_plan.broken_count} broken, "
        f"{symlink_plan.unmanaged_count} unmanaged, "
        f"{symlink_plan.stale_managed_count} stale, "
        f"{symlink_plan.excluded_count} excluded"
    )
    if symlink_plan.excluded_symlinked_count:
        print(f"  Excluded but symlinked: {symlink_plan.excluded_symlinked_count}")
    if manifest_plan.update_count or manifest_plan.remove_count:
        print(
            "  Read-only manifest drift: "
            f"{manifest_plan.update_count} update candidate(s), "
            f"{manifest_plan.remove_count} removal candidate(s)"
        )
    if manifest_plan.preserved_missing_profile_count:
        print(
            "  Preserved unresolved profile entries: "
            f"{manifest_plan.preserved_missing_profile_count}"
        )

    for decision in symlink_plan.decisions:
        if decision.action == SymlinkAction.LINKED or decision.action == SymlinkAction.EXCLUDED:
            continue
        print(f"  - {decision.folder_name}\t{decision.action.value}\t{decision.reason}")

    for decision in manifest_plan.decisions:
        if decision.action == ManifestAction.KEEP and not is_preserved_missing_profile_decision(decision):
            continue
        label = decision.action.value
        if is_preserved_missing_profile_decision(decision):
            label = "preserve"
        print(
            f"  - manifest\t{label}\t{decision.manifest_path}\t"
            f"{decision.current_folder_name or '-'} -> {decision.desired_folder_name or '-'}"
        )
    return 0


def _run_extension_check(args: argparse.Namespace) -> int:
    """Handle the ``extension-check`` subcommand."""
    symlink_plan, manifest_plan = _combined_extension_state(args)
    issues = (
        symlink_plan.broken_count
        + manifest_plan.remove_count
    )
    warnings = (
        symlink_plan.missing_count
        + symlink_plan.wrong_target_count
        + symlink_plan.unmanaged_count
        + symlink_plan.excluded_symlinked_count
        + symlink_plan.stale_managed_count
        + manifest_plan.update_count
        + manifest_plan.preserved_missing_profile_count
    )

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

    print("Checking: Extensions")
    print(
        f"  linked={symlink_plan.linked_count}/{symlink_plan.expected_link_count} "
        f"missing={symlink_plan.missing_count} broken={symlink_plan.broken_count} "
        f"unmanaged={symlink_plan.unmanaged_count} stale={symlink_plan.stale_managed_count}"
    )
    if manifest_plan.update_count or manifest_plan.remove_count:
        print(
            f"  manifest_update_candidates={manifest_plan.update_count} "
            f"manifest_removal_candidates={manifest_plan.remove_count}"
        )
    if manifest_plan.preserved_missing_profile_count:
        print(
            "  manifest_preserved_missing_profiles="
            f"{manifest_plan.preserved_missing_profile_count}"
        )
    print(f"ISSUES={issues}")
    print(f"WARNINGS={warnings}")
    return 0 if issues == 0 else 1


def _run_recover_missing(args: argparse.Namespace) -> int:
    """Handle the ``recover-missing`` subcommand."""
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
    if args.command == "extension-status":
        return _run_extension_status(args)
    if args.command == "extension-check":
        return _run_extension_check(args)
    if args.command == "recover-missing":
        return _run_recover_missing(args)

    parser.error(f"unsupported command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
