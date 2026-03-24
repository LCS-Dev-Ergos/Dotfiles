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
import os
import sys
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
    extension_health_counts,
)
from vscode_update import apply_extension_update, build_extension_update_plan


_FORCE_COLOR_ENV = "VSCODE_SYNC_FORCE_COLOR"
_ANSI_RESET = "\033[0m"
_ANSI_BOLD = "\033[1m"
_ANSI_RED = "\033[31m"
_ANSI_GREEN = "\033[32m"
_ANSI_YELLOW = "\033[33m"
_ANSI_BLUE = "\033[34m"
_ANSI_CYAN = "\033[36m"

_STATUS_LABELS = {
    "ok": "valid",
    "valid": "valid",
    "warn": "warning",
    "warning": "warning",
    "error": "error",
    "info": "info",
}

_STATUS_STYLES = {
    "valid": (_ANSI_BOLD, _ANSI_GREEN),
    "warning": (_ANSI_BOLD, _ANSI_YELLOW),
    "error": (_ANSI_BOLD, _ANSI_RED),
    "info": (_ANSI_BOLD, _ANSI_CYAN),
}

_REASON_LABELS = {
    "symlink_valid": "symlink valid",
    "broken_symlink": "broken symlink",
    "wrong_symlink": "wrong symlink target",
    "wrong_target": "wrong symlink target",
    "independent_path": "independent path",
    "target_missing": "target missing",
    "source_missing": "source missing",
    "unmanaged_real_dir": "independent directory",
    "excluded_but_symlinked": "excluded extension still linked",
    "stale_managed_symlink": "stale managed symlink",
    "linked": "symlink valid",
}


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


def _colors_enabled() -> bool:
    """Return whether human-readable output should use ANSI styling."""

    if os.environ.get("NO_COLOR"):
        return False
    force_value = os.environ.get(_FORCE_COLOR_ENV, "").strip().lower()
    if force_value in {"1", "true", "yes", "on"}:
        return True
    return sys.stdout.isatty()


def _style(text: object, *styles: str) -> str:
    """Apply ANSI styles to text when color output is enabled."""

    rendered = str(text)
    if not styles or not _colors_enabled():
        return rendered
    return f"{''.join(styles)}{rendered}{_ANSI_RESET}"


def _pretty_path(value: Path | str | None) -> str:
    """Render a path-like value using ``~`` for the current HOME prefix."""

    if value is None:
        return "-"
    text = str(value)
    home = str(Path.home())
    if text == home:
        return "~"
    if text.startswith(f"{home}/"):
        return f"~{text[len(home):]}"
    return text


def _render_value(value: object) -> str:
    """Render one human-readable metric value."""

    if isinstance(value, Path):
        return _pretty_path(value)
    return str(value)


def _render_status(status: str) -> str:
    """Render a semantic status label with consistent casing and color."""

    normalized = _STATUS_LABELS.get(status, status.replace("_", " ").lower())
    return _style(normalized, *_STATUS_STYLES.get(normalized, ()))


def _render_toggle(
    enabled: bool,
    *,
    enabled_label: str = "enabled",
    disabled_label: str = "disabled",
    disabled_status: str = "warning",
) -> str:
    """Render one enabled/disabled-style value with semantic coloring."""

    if enabled:
        return _style(enabled_label, *_STATUS_STYLES["valid"])
    return _style(disabled_label, *_STATUS_STYLES.get(disabled_status, ()))


def _humanize_reason(reason: str) -> str:
    """Convert internal reason tokens into cleaner human-readable text."""

    token, sep, details = reason.partition(" (")
    human = _REASON_LABELS.get(token, token.replace("_", " ").replace("-", " "))
    if not sep:
        return human
    return f"{human} ({details}"


def _print_section(title: str) -> None:
    """Print a consistently formatted section title."""

    print(_style(title, _ANSI_BOLD, _ANSI_BLUE))


def _print_subsection(title: str, *, indent: int = 2) -> None:
    """Print a compact subsection heading inside a larger report."""

    prefix = " " * indent
    print(f"{prefix}{_style(f'{title}:', _ANSI_BOLD, _ANSI_CYAN)}")


def _print_metric(label: str, value: object, *, indent: int = 2) -> None:
    """Print one aligned key/value metric."""

    prefix = " " * indent
    print(f"{prefix}{label:<24} {_render_value(value)}")


def _print_list_item(value: object, *, prefix: str = "-", indent: int = 4) -> None:
    """Print one indented list item."""

    print(f"{' ' * indent}{prefix} {_render_value(value)}")


def _print_notice(level: str, message: str, *, indent: int = 0) -> None:
    """Print one styled informational line."""

    level_styles = {
        "info": (_ANSI_CYAN,),
        "success": (_ANSI_GREEN,),
        "warning": (_ANSI_YELLOW,),
        "error": (_ANSI_RED,),
    }
    prefix = " " * indent
    print(f"{prefix}{_style(message, *level_styles.get(level, ()))}")


def _sync_item_status(item: object) -> str:
    """Map one sync item decision to a human-facing status label."""

    if item.status == SyncItemStatus.SYNCED:
        return "valid"
    if item.status == SyncItemStatus.SYMLINK_WRONG:
        return "warning"
    if item.status in {SyncItemStatus.SYMLINK_BROKEN, SyncItemStatus.SOURCE_MISSING}:
        return "error"
    return "info"


def _sync_item_reason(item: object) -> str:
    """Map one sync item decision to a concise human-facing reason."""

    if item.status == SyncItemStatus.SYNCED:
        return "symlink_valid"
    if item.status == SyncItemStatus.SYMLINK_BROKEN:
        return "target_missing"
    if item.status == SyncItemStatus.SYMLINK_WRONG:
        return "wrong_symlink"
    if item.status == SyncItemStatus.INDEPENDENT:
        return "independent_path"
    if item.status == SyncItemStatus.MISSING:
        return "target_missing"
    return "source_missing"


def _sync_item_details(item: object, *, include_source: bool = False) -> list[tuple[str, str]]:
    """Return detail lines that help explain one sync item decision."""

    details: list[tuple[str, str]] = []
    if item.status == SyncItemStatus.SYNCED:
        if include_source:
            details.append(("source", _pretty_path(item.source_path)))
    elif item.status == SyncItemStatus.SYMLINK_BROKEN:
        details.append(("target", _pretty_path(item.target_path)))
        if item.link_target:
            details.append(("link target", _pretty_path(item.link_target)))
    elif item.status == SyncItemStatus.SYMLINK_WRONG:
        details.append(("current target", _pretty_path(item.link_target or "-")))
        details.append(("expected target", _pretty_path(item.source_path)))
    elif item.status == SyncItemStatus.INDEPENDENT:
        if include_source:
            details.append(("target", _pretty_path(item.target_path)))
    elif item.status == SyncItemStatus.MISSING:
        details.append(("target", _pretty_path(item.target_path)))
    else:
        details.append(("source", _pretty_path(item.source_path)))
    return details


def _print_sync_item_block(item: object, *, include_source: bool = False) -> None:
    """Render one sync item as a compact subsection block."""

    _print_subsection(item.label)
    _print_metric("status", _render_status(_sync_item_status(item)), indent=4)
    _print_metric("reason", _humanize_reason(_sync_item_reason(item)), indent=4)
    for label, value in _sync_item_details(item, include_source=include_source):
        _print_metric(label, value, indent=4)


def _symlink_decisions_for(plan: object, action: SymlinkAction) -> list[object]:
    """Return all symlink decisions matching the requested action."""

    return [decision for decision in plan.decisions if decision.action == action]


def _manifest_update_lines(plan: object) -> list[str]:
    """Build human-readable lines for manifest update candidates."""

    lines: list[str] = []
    for decision in plan.decisions:
        if decision.action != ManifestAction.UPDATE:
            continue
        lines.append(
            f"{_pretty_path(decision.manifest_path)}: "
            f"{decision.current_folder_name or '-'} -> {decision.desired_folder_name or '-'}"
        )
    return lines


def _manifest_preserved_lines(plan: object) -> list[str]:
    """Build human-readable lines for preserved unresolved profile entries."""

    lines: list[str] = []
    for decision in plan.decisions:
        if not is_preserved_missing_profile_decision(decision):
            continue
        lines.append(
            f"{_pretty_path(decision.manifest_path)}: "
            f"{decision.current_folder_name or '-'}"
        )
    return lines


def _print_extensions_overview(symlink_plan: object, manifest_plan: object) -> None:
    """Render the shared extension health summary and any important details."""

    _print_section("Extensions")
    _print_metric("Linked", f"{symlink_plan.linked_count}/{symlink_plan.expected_link_count}")
    _print_metric("Missing", symlink_plan.missing_count)
    _print_metric("Broken", symlink_plan.broken_count)
    _print_metric("Wrong target", symlink_plan.wrong_target_count)
    _print_metric("Unmanaged", symlink_plan.unmanaged_count)
    _print_metric("Stale", symlink_plan.stale_managed_count)
    _print_metric("Excluded", symlink_plan.excluded_count)
    if symlink_plan.excluded_symlinked_count:
        _print_metric("Excluded linked", symlink_plan.excluded_symlinked_count)
    if manifest_plan.update_count or manifest_plan.remove_count:
        _print_metric("Manifest updates", manifest_plan.update_count)
        _print_metric("Manifest removals", manifest_plan.remove_count)
    if manifest_plan.preserved_missing_profile_count:
        _print_metric("Preserved profile drift", manifest_plan.preserved_missing_profile_count)

    detail_groups = (
        ("Missing links", _symlink_decisions_for(symlink_plan, SymlinkAction.MISSING)),
        ("Broken links", _symlink_decisions_for(symlink_plan, SymlinkAction.BROKEN)),
        ("Wrong targets", _symlink_decisions_for(symlink_plan, SymlinkAction.WRONG_TARGET)),
        (
            "Unmanaged directories",
            _symlink_decisions_for(symlink_plan, SymlinkAction.UNMANAGED_REAL_DIR),
        ),
        (
            "Excluded links",
            _symlink_decisions_for(symlink_plan, SymlinkAction.EXCLUDED_BUT_SYMLINKED),
        ),
        (
            "Stale managed links",
            _symlink_decisions_for(symlink_plan, SymlinkAction.STALE_MANAGED_SYMLINK),
        ),
    )

    for title, decisions in detail_groups:
        if not decisions:
            continue
        print()
        _print_subsection(title)
        for decision in decisions:
            description = decision.folder_name
            if decision.action == SymlinkAction.WRONG_TARGET and decision.target_path:
                description = f"{decision.folder_name} -> {_pretty_path(decision.target_path)}"
            _print_list_item(description, indent=4)

    manifest_updates = _manifest_update_lines(manifest_plan)
    if manifest_updates:
        print()
        _print_subsection("Manifest updates")
        for line in manifest_updates:
            _print_list_item(line, indent=4)

    preserved_lines = _manifest_preserved_lines(manifest_plan)
    if preserved_lines:
        print()
        _print_subsection("Preserved profile drift")
        for line in preserved_lines:
            _print_list_item(line, indent=4)


def _build_update_progress_reporter(plan: object):
    """Create a step-based progress reporter for the update workflow."""

    total_steps = 2
    if plan.cleanup_plan is not None:
        total_steps += 1
    if plan.native_excluded_extension_ids:
        total_steps += 1

    state = {
        "index": 0,
        "phase": None,
    }

    def _start_step(phase: str, label: str) -> None:
        if state["phase"] == phase:
            return
        state["index"] += 1
        state["phase"] = phase
        marker = _style(f"[{state['index']}/{total_steps}]", _ANSI_BOLD, _ANSI_CYAN)
        print(f"  {marker} {label}", flush=True)

    def _detail(message: str, *, level: str = "info") -> None:
        _print_notice(level, message, indent=6)
        sys.stdout.flush()

    def _report(message: str) -> None:
        if message == "Updating shared Stable extensions.":
            _start_step("shared", "Updating shared Stable extensions")
            return
        if message.startswith("Shared extension updating: "):
            extension_id = message.removeprefix("Shared extension updating: ").removesuffix(".")
            _detail(f"Updating {extension_id}")
            return
        if message.startswith("Shared extension updated: "):
            extension_id = message.removeprefix("Shared extension updated: ").removesuffix(".")
            _detail(f"Updated {extension_id}.", level="success")
            return
        if message.startswith("Shared Stable update completed:"):
            _detail(message.removesuffix(".").replace("Shared Stable ", "").capitalize())
            return
        if message == "Shared Stable root is already current.":
            _detail("Shared root already current.")
            return
        if message == "Scanning the shared root for duplicate leftovers.":
            _start_step("cleanup", "Cleaning duplicate leftovers")
            return
        if message.startswith("Quarantined "):
            _detail(message.removesuffix("."))
            return
        if message == "No shared-root leftovers detected.":
            _detail("No shared-root leftovers detected.")
            return
        if message.startswith("Cleanup could not quarantine "):
            _detail(message.removesuffix("."), level="warning")
            return
        if message == "Checking Insiders-native excluded extensions.":
            _start_step("excluded", "Checking Insiders-native excluded extensions")
            return
        if message.startswith("Checking excluded extension: "):
            extension_id = message.removeprefix("Checking excluded extension: ").removesuffix(".")
            _detail(f"Checking {extension_id}.")
            return
        if message.startswith("Updated excluded extension: "):
            extension_id = message.removeprefix("Updated excluded extension: ").removesuffix(".")
            _detail(f"Updated {extension_id}.", level="success")
            return
        if message.startswith("Excluded extension already current: "):
            extension_id = message.removeprefix("Excluded extension already current: ").removesuffix(".")
            _detail(f"{extension_id} is already current.")
            return
        if message.startswith("Excluded extension update failed: "):
            extension_id = message.removeprefix("Excluded extension update failed: ").removesuffix(".")
            _detail(f"Failed to update {extension_id}.", level="warning")
            return
        if message == "Reconciling Insiders links and manifest drift.":
            _start_step("reconcile", "Reconciling links and manifests")
            return
        if message == "Update workflow completed.":
            _detail("Workflow completed.", level="success")
            return
        _detail(message)

    return _report


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
    _print_subsection("Overview")
    _print_metric("Root", plan.root, indent=4)
    _print_metric("Strategy", plan.strategy.value, indent=4)
    _print_metric("Respect references", _render_toggle(plan.respect_references), indent=4)
    _print_metric("Prune stale refs", _render_toggle(plan.prune_stale_references), indent=4)
    _print_metric("Duplicate groups", plan.duplicate_group_count, indent=4)
    _print_metric("Planned quarantine", plan.planned_deletion_count, indent=4)
    _print_metric("Protected refs", len(plan.protected_reference_names), indent=4)
    _print_metric("Stale refs", len(plan.stale_reference_names), indent=4)
    for group in plan.groups:
        print()
        _print_subsection(f"Group {group.core_name}")
        for decision in group.decisions:
            _print_list_item(
                f"{decision.folder_name:<52} {decision.action.value} "
                f"({_humanize_reason(decision.reason)})",
                indent=4,
            )
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
        _print_subsection("Overview")
        _print_metric("Root", plan.root, indent=4)
        _print_metric("Strategy", plan.strategy.value, indent=4)
        _print_metric("Mode", _style("dry run", _ANSI_BOLD, _ANSI_CYAN), indent=4)
        if plan.respect_references:
            _print_metric("Reference guard", _render_toggle(True), indent=4)
            _print_metric("Raw references", len(plan.raw_reference_names), indent=4)
            _print_metric("Protected refs", len(plan.protected_reference_names), indent=4)
            if plan.stale_reference_names:
                mode = _render_toggle(plan.prune_stale_references)
                _print_metric("Stale ref pruning", mode, indent=4)
                _print_metric("Detected stale refs", len(plan.stale_reference_names), indent=4)
        else:
            _print_metric("Reference guard", _render_toggle(False), indent=4)

        _print_metric("Duplicate groups", plan.duplicate_group_count, indent=4)
        _print_metric("Planned quarantine", plan.planned_deletion_count, indent=4)
        deletable_paths = deletable_paths_from_plan(plan)
        if deletable_paths:
            print()
            _print_subsection("Quarantine candidates")
            for path in deletable_paths:
                _print_list_item(path, indent=4)
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
        response = input(f"{_style('Proceed with quarantine move? [y/N] ', _ANSI_YELLOW)}").strip().lower()
        if response not in {"y", "yes"}:
            _print_notice("warning", "Aborted by user.")
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
    _print_subsection("Overview")
    _print_metric("Quarantined", len(report.quarantined_paths), indent=4)
    _print_metric("Quarantine root", report.quarantine_root, indent=4)
    _print_metric("Failed", len(report.failed_paths), indent=4)
    if report.quarantined_paths:
        print()
        _print_subsection("Quarantined folders")
        for path in report.quarantined_paths:
            _print_list_item(path, indent=4)
    if report.failed_paths:
        print()
        _print_subsection("Failed folders")
        for path in report.failed_paths:
            _print_list_item(path, indent=4)
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

    _print_section("Manifest Plan")
    _print_subsection("Overview")
    _print_metric("Manifest updates", plan.update_count, indent=4)
    _print_metric("Manifest removals", plan.remove_count, indent=4)
    _print_metric("Manifest keeps", plan.keep_count, indent=4)
    _print_metric("Preserved profile drift", plan.preserved_missing_profile_count, indent=4)
    for decision in plan.decisions:
        if decision.action == ManifestAction.KEEP and not is_preserved_missing_profile_decision(
            decision
        ):
            continue
        label = decision.action.value
        if is_preserved_missing_profile_decision(decision):
            label = "preserve"
        _print_list_item(
            f"{label:<8} {_pretty_path(decision.manifest_path)} "
            f"{decision.current_folder_name or '-'} -> {decision.desired_folder_name or '-'}",
            indent=4,
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
        _print_notice("error", f"Manifest repair aborted: {exc}")
        return 1

    if args.json_output:
        return _emit_json({"plan": plan.to_dict(), "apply_report": report.to_dict()})

    _print_section("Manifest Repair Result")
    _print_subsection("Overview")
    _print_metric("Updated entries", report.updated_entries, indent=4)
    _print_metric("Removed entries", report.removed_entries, indent=4)
    _print_metric("Preserved profile drift", plan.preserved_missing_profile_count, indent=4)
    _print_metric("Touched manifests", len(report.touched_manifests), indent=4)
    if report.touched_manifests:
        print()
        _print_subsection("Touched manifests")
        for path in report.touched_manifests:
            _print_list_item(path, indent=4)
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
        _print_notice("error", f"Setup aborted: {exc}")
        return 1
    if args.json_output:
        return _emit_json(report.to_dict())

    _print_section("Setup Result")
    _print_subsection("Extensions")
    _print_metric("Linked", report.linked_count, indent=4)
    _print_metric("Relinked", report.relinked_count, indent=4)
    _print_metric("Migrated unmanaged", report.migrated_count, indent=4)
    _print_metric("Removed stale", report.removed_stale_symlink_count, indent=4)
    _print_metric("Skipped excluded", report.skipped_excluded_symlink_count, indent=4)
    _print_metric("Manifest updates", report.manifest_apply_report.updated_entries, indent=4)
    _print_metric("Manifest removals", report.manifest_apply_report.removed_entries, indent=4)
    plan = plan_manifest_repairs(
        args.stable_dir,
        args.insiders_dir,
        config=config,
        exclude_patterns=exclude_patterns,
    )
    _print_metric("Preserved profile drift", plan.preserved_missing_profile_count, indent=4)
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

    _print_section("Remove Result")
    _print_subsection("Extensions")
    _print_metric("Removed root symlink", report.removed_root_symlink_count, indent=4)
    _print_metric("Removed entry symlinks", report.removed_entry_symlink_count, indent=4)
    _print_metric("Skipped real directories", report.skipped_real_dir_count, indent=4)
    _print_metric("Failed paths", len(report.failed_paths), indent=4)
    if report.failed_paths:
        print()
        _print_subsection("Failed paths")
        for path in report.failed_paths:
            _print_list_item(path, indent=4)
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

    _print_extensions_overview(symlink_plan, manifest_plan)
    return 0


def _run_extension_check(args: argparse.Namespace) -> int:
    """Handle the `extension-check` subcommand."""

    symlink_plan, manifest_plan = _combined_extension_state(args)
    issues, warnings = extension_health_counts(symlink_plan, manifest_plan)

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

    _print_extensions_overview(symlink_plan, manifest_plan)
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
    for index, item in enumerate(report.items):
        if index:
            print()
        _print_sync_item_block(item, include_source=True)

    print()
    _print_extensions_overview(report.symlink_plan, report.manifest_plan)
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
    for index, item in enumerate(report.items):
        if index:
            print()
        _print_sync_item_block(item)

    print()
    _print_extensions_overview(report.symlink_plan, report.manifest_plan)
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
        _print_notice("error", f"Setup aborted: {exc}")
        return 1
    if args.json_output:
        return _emit_json(report.to_dict())

    _print_section("Setup Result")
    _print_subsection("Items")
    _print_metric("Synced items", report.synced_count, indent=4)
    _print_metric("Skipped items", report.skipped_count, indent=4)
    _print_metric("Failed items", report.failed_count, indent=4)
    print()
    _print_subsection("Extensions")
    _print_metric("Linked", report.extension_report.linked_count, indent=4)
    _print_metric("Relinked", report.extension_report.relinked_count, indent=4)
    _print_metric("Migrated unmanaged", report.extension_report.migrated_count, indent=4)
    _print_metric("Removed stale", report.extension_report.removed_stale_symlink_count, indent=4)
    _print_metric("Skipped excluded", report.extension_report.skipped_excluded_symlink_count, indent=4)
    _print_metric(
        "Manifest updates",
        report.extension_report.manifest_apply_report.updated_entries,
        indent=4,
    )
    _print_metric(
        "Manifest removals",
        report.extension_report.manifest_apply_report.removed_entries,
        indent=4,
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
    _print_subsection("Items")
    _print_metric("Restored items", report.restored_count, indent=4)
    _print_metric("Removed broken", report.removed_broken_count, indent=4)
    _print_metric("Skipped items", report.skipped_count, indent=4)
    _print_metric("Failed items", report.failed_count, indent=4)
    print()
    _print_subsection("Extensions")
    _print_metric("Removed root symlink", report.extension_report.removed_root_symlink_count, indent=4)
    _print_metric("Removed entry symlinks", report.extension_report.removed_entry_symlink_count, indent=4)
    _print_metric("Skipped real dirs", report.extension_report.skipped_real_dir_count, indent=4)
    _print_metric("Failed paths", len(report.extension_report.failed_paths), indent=4)
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
        _print_subsection("Shared")
        _print_metric("Shared root", plan.stable_dir, indent=4)
        _print_metric("Mode", "apply update + reconcile", indent=4)
        print()
        _print_subsection("Cleanup")
        if plan.skip_clean:
            _print_metric("Cleanup", _render_toggle(False), indent=4)
        else:
            assert plan.cleanup_plan is not None
            _print_metric("Cleanup", _render_toggle(True), indent=4)
            _print_metric("Duplicate groups", plan.cleanup_plan.duplicate_group_count, indent=4)
            _print_metric("Current quarantine plan", plan.cleanup_plan.planned_deletion_count, indent=4)
            _print_metric(
                "Manifest guard",
                "strict" if not plan.cleanup_plan.prune_stale_references else "prune stale refs",
                indent=4,
            )
            _print_metric("Cleanup source", "live post-update rescan", indent=4)
        print()
        _print_subsection("Excluded")
        _print_metric("Native checks", len(plan.native_excluded_extension_ids), indent=4)
        for extension_id in plan.native_excluded_extension_ids:
            _print_list_item(extension_id, indent=4)
        print()
        _print_subsection("Reconcile")
        _print_metric("Insiders root", plan.insiders_dir, indent=4)
        _print_metric("Missing links", plan.symlink_plan.missing_count, indent=4)
        _print_metric("Unmanaged dirs", plan.symlink_plan.unmanaged_count, indent=4)
        _print_metric("Manifest updates", plan.manifest_plan.update_count, indent=4)
        _print_metric("Manifest removals", plan.manifest_plan.remove_count, indent=4)
        print()
        _print_notice("success", "Preview complete. No changes were made.")
        return 0

    try:
        _print_section("Progress")
        report = apply_extension_update(
            plan,
            config=config,
            exclude_patterns=exclude_patterns,
            progress=_build_update_progress_reporter(plan),
        )
    except ProfileManifestSafetyError as exc:
        _print_notice("error", f"Update aborted: {exc}")
        return 1
    if args.json_output:
        return _emit_json({"plan": plan.to_dict(), "report": report.to_dict()})

    _print_section("Update Result")
    _print_subsection("Shared")
    _print_metric(
        "Update status",
        _render_status("valid" if report.shared_update_succeeded else "error"),
        indent=4,
    )
    _print_metric("Updated", len(report.shared_updated_extension_ids), indent=4)
    for extension_id in report.shared_updated_extension_ids:
        _print_list_item(f"updated {extension_id}", indent=4)
    print()
    _print_subsection("Cleanup")
    _print_metric("Quarantined", report.cleanup_quarantined_count, indent=4)
    _print_metric("Failures", report.cleanup_failed_count, indent=4)
    print()
    _print_subsection("Excluded")
    _print_metric("Attempted", len(report.excluded_updates_attempted), indent=4)
    _print_metric("Updated", len(report.excluded_updates_applied), indent=4)
    _print_metric("Already current", len(report.excluded_updates_current), indent=4)
    _print_metric("Failed", len(report.excluded_updates_failed), indent=4)
    for extension_id in report.excluded_updates_applied:
        _print_list_item(f"updated {extension_id}", indent=4)
    for extension_id in report.excluded_updates_current:
        _print_list_item(f"current {extension_id}", indent=4)
    for extension_id in report.excluded_updates_failed:
        _print_list_item(f"failed {extension_id}", indent=4)
    print()
    _print_subsection("Reconcile")
    _print_metric("Linked", report.setup_report.linked_count, indent=4)
    _print_metric("Relinked", report.setup_report.relinked_count, indent=4)
    _print_metric("Migrated unmanaged", report.setup_report.migrated_count, indent=4)
    _print_metric("Removed stale", report.setup_report.removed_stale_symlink_count, indent=4)
    _print_metric("Manifest updates", report.setup_report.manifest_apply_report.updated_entries, indent=4)
    _print_metric("Manifest removals", report.setup_report.manifest_apply_report.removed_entries, indent=4)
    print()
    _print_subsection("Final state")
    _print_metric(
        "Links",
        f"{report.final_symlink_plan.linked_count}/{report.final_symlink_plan.expected_link_count}",
        indent=4,
    )
    _print_metric("Missing", report.final_symlink_plan.missing_count, indent=4)
    _print_metric("Broken", report.final_symlink_plan.broken_count, indent=4)
    _print_metric("Wrong target", report.final_symlink_plan.wrong_target_count, indent=4)
    _print_metric("Unmanaged", report.final_symlink_plan.unmanaged_count, indent=4)
    _print_metric("Stale", report.final_symlink_plan.stale_managed_count, indent=4)
    if report.final_manifest_plan.update_count or report.final_manifest_plan.remove_count:
        _print_metric("Manifest updates", report.final_manifest_plan.update_count, indent=4)
        _print_metric("Manifest removals", report.final_manifest_plan.remove_count, indent=4)
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

        _print_section("Recovery Plan")
        _print_subsection("Overview")
        _print_metric("Requests", len(plan.requests), indent=4)
        _print_metric("Install tasks", len(plan.install_tasks), indent=4)
        _print_metric("Alias tasks", len(plan.alias_tasks), indent=4)
        for task in plan.install_tasks:
            _print_list_item(
                f"install {task.installer} {_pretty_path(task.install_root)} "
                f"{task.install_spec} requests={task.request_count} "
                f"profile={task.profile_name or '-'}",
                indent=4,
            )
        for task in plan.alias_tasks:
            _print_list_item(
                f"alias {_pretty_path(task.alias_path)} -> {_pretty_path(task.target_path)}",
                indent=4,
            )
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

    _print_section("Recovery Result")
    _print_subsection("Installs")
    _print_metric("Attempted", len(report.attempted_installs), indent=4)
    _print_metric("Successful", len(report.successful_installs), indent=4)
    _print_metric("Failed", len(report.failed_installs), indent=4)
    print()
    _print_subsection("Aliases")
    _print_metric("Created", len(report.created_aliases), indent=4)
    _print_metric("Failed", len(report.failed_aliases), indent=4)
    print()
    _print_subsection("Setup")
    _print_metric("Linked", report.setup_linked_count, indent=4)
    _print_metric("Relinked", report.setup_relinked_count, indent=4)
    _print_metric("Migrated", report.setup_migrated_count, indent=4)
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
