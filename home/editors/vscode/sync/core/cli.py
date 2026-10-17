"""The command line: ``status``, ``check``, ``setup``, ``update``, ``remove``
and ``clean``.

Every command first reports. A changing command then takes the lock, refuses
while VS Code runs, asks, and applies its plan in a transaction that is
checked by planning again; ``--dry-run`` stops after the report.
"""

import argparse
import dataclasses
import json
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path

import terminal_style as ui

from . import PROG, __version__
from .errors import SyncError
from .host import Edition, Host
from .plan import (
    Plan,
    Quarantine,
    Snapshot,
    plan_clean,
    plan_remove,
    plan_setup,
    take_snapshot,
)
from .report import event, notice, render, to_json
from .safety import confirm, locked, running_editions
from .storage import KEPT_RUNS, new_workspace, prune
from .transaction import Transaction, quarantine
from .update import find_command, update_extensions

Planner = Callable[[Snapshot], Plan]


class ExitCode(IntEnum):
    """The exit status; ``USAGE`` is what argparse exits with."""

    OK = 0
    ATTENTION = 1
    USAGE = 2
    ERROR = 3


@dataclass(frozen=True, slots=True)
class Context:
    """What a run needs from its surroundings; tests supply their own.

    ``processes`` replaces the process list and ``terminal`` the answer to
    whether stdin is a terminal.
    """

    host: Host
    style: ui.Style
    processes: Sequence[str] | None = None
    terminal: bool | None = None


def build_parser() -> argparse.ArgumentParser:
    """The argument parser of the command."""
    parser = argparse.ArgumentParser(
        prog=PROG,
        description=(
            "Share VS Code Stable's extensions, settings, keybindings, "
            "snippets and MCP servers with VS Code Insiders, through links."
        ),
    )
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )
    commands = parser.add_subparsers(dest="command", required=True)
    for name, text in (
        ("status", "show what is shared and what is due"),
        ("check", "like status; exit 1 when anything is due or broken"),
    ):
        command = commands.add_parser(name, help=text, description=text)
        command.add_argument(
            "--json", action="store_true", help="print the report as JSON"
        )
    for name, text in (
        ("setup", "make Insiders share what it can with Stable"),
        ("remove", "give Insiders its own copy of everything shared"),
    ):
        command = commands.add_parser(name, help=text, description=text)
        _changing(command)
    update = commands.add_parser(
        "update",
        help="update both editions' extensions, then share again",
        description=(
            "Run VS Code's own extension update for Stable, let Insiders "
            "follow, update Insiders' own extensions, share again and "
            "clean up duplicates."
        ),
    )
    update.add_argument(
        "--skip-clean", action="store_true", help="leave duplicates in place"
    )
    _changing(update)
    clean = commands.add_parser(
        "clean",
        help="quarantine duplicate builds no profile uses",
        description=(
            "Move older builds of an extension that no profile lists into "
            "the state directory's quarantine."
        ),
    )
    clean.add_argument(
        "--edition",
        choices=["stable", "insiders", "both"],
        default="both",
        help="which extensions directory to clean (default: both)",
    )
    _changing(clean)
    return parser


def _changing(command: argparse.ArgumentParser) -> None:
    """The options every changing command takes."""
    command.add_argument(
        "--dry-run",
        action="store_true",
        help="only report; exit 1 when the run would change something",
    )
    command.add_argument(
        "--yes", action="store_true", help="do not ask before changing"
    )


def main(
    argv: Sequence[str] | None = None, context: Context | None = None
) -> int:
    """Run the command line.

    Args:
        argv: The arguments without the program name; default: sys.argv.
        context: The machine and terminal; default: the running ones.

    Returns:
        The exit status, an ``ExitCode``.
    """
    args = build_parser().parse_args(argv)
    try:
        context = context or Context(Host.detect(), ui.Style.detect())
        return _run(args, context)
    except SyncError as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return ExitCode.ERROR
    except KeyboardInterrupt:
        print(f"{PROG}: interrupted", file=sys.stderr)
        return ExitCode.ERROR


def _run(args: argparse.Namespace, context: Context) -> ExitCode:
    """Dispatch to the command."""
    if args.command in ("status", "check"):
        return _report(args, context)
    if args.command == "setup":
        return _change(args, context, plan_setup)
    if args.command == "remove":
        return _change(args, context, plan_remove)
    if args.command == "clean":
        return _clean(args, context)
    return _update(args, context)


def _report(args: argparse.Namespace, context: Context) -> ExitCode:
    """``status`` and ``check``: what setup would do, changing nothing."""
    plan = dataclasses.replace(
        plan_setup(take_snapshot(context.host)), command=args.command
    )
    if args.json:
        print(json.dumps(to_json(plan), indent=2))
    else:
        _print(render(plan, context.style, changes=False))
    if args.command == "check" and (plan.changed or plan.problems):
        return ExitCode.ATTENTION
    return ExitCode.OK


def _change(
    args: argparse.Namespace, context: Context, planner: Planner
) -> ExitCode:
    """``setup`` and ``remove``: report, then apply unless it is a dry run."""
    if args.dry_run:
        plan = planner(take_snapshot(context.host))
        _print(render(plan, context.style, context="dry run"))
        return ExitCode.ATTENTION if plan.changed else ExitCode.OK
    with locked(context.host.state_dir()):
        _guard(context)
        snapshot = take_snapshot(context.host)
        plan = planner(snapshot)
        _print(render(plan, context.style))
        if not plan.changed:
            return ExitCode.OK
        _refuse_interrupted(snapshot)
        if not args.yes and not _ask(context, f"Apply {_count(plan)}?"):
            _print(notice(context.style, "muted", "Nothing was changed."))
            return ExitCode.OK
        kept, warnings = _execute(plan, context, planner)
        _done(context, plan, kept, warnings)
    return ExitCode.OK


def _clean(args: argparse.Namespace, context: Context) -> ExitCode:
    """``clean``: quarantine unused duplicates of one or both editions."""
    editions = {
        "stable": (Edition.STABLE,),
        "insiders": (Edition.INSIDERS,),
        "both": (Edition.STABLE, Edition.INSIDERS),
    }[args.edition]
    if args.dry_run:
        plan = plan_clean(take_snapshot(context.host), editions)
        _print(render(plan, context.style, context="dry run"))
        return ExitCode.ATTENTION if plan.changed else ExitCode.OK
    with locked(context.host.state_dir()):
        _guard(context)
        snapshot = take_snapshot(context.host)
        plan = plan_clean(snapshot, editions)
        _print(render(plan, context.style))
        if not plan.changed:
            return ExitCode.OK
        if not args.yes and not _ask(context, f"Quarantine {_count(plan)}?"):
            _print(notice(context.style, "muted", "Nothing was changed."))
            return ExitCode.OK
        return _quarantine(plan, context)


def _update(args: argparse.Namespace, context: Context) -> ExitCode:
    """``update``: VS Code's updates, sharing after each, then cleaning."""
    host, style = context.host, context.style
    steps = [
        f"run {Edition.STABLE.command} --update-extensions",
        "let Insiders follow Stable's builds",
        f"run {Edition.INSIDERS.command} --update-extensions",
        "share again",
    ]
    if not args.skip_clean:
        steps.append("quarantine unused duplicates in both editions")
    numbered = [f"{index}. {step}" for index, step in enumerate(steps, 1)]
    if args.dry_run:
        plan = dataclasses.replace(
            plan_setup(take_snapshot(host)), command="update"
        )
        _print(render(plan, style, context="dry run"))
        _print(["", *notice(style, "muted", "An update runs:", numbered)])
        return ExitCode.OK
    with locked(host.state_dir()):
        _guard(context)
        snapshot = take_snapshot(host)
        _refuse_interrupted(snapshot)
        stable = find_command(host, Edition.STABLE)
        if stable is None:
            raise SyncError(f"{Edition.STABLE.command} is not on PATH")
        insiders = find_command(host, Edition.INSIDERS)
        plan = dataclasses.replace(plan_setup(snapshot), command="update")
        _print(render(plan, style, changes=False))
        _print(["", *notice(style, "muted", "An update runs:", numbered)])
        if not args.yes and not _ask(context, "Run the update?"):
            _print(notice(style, "muted", "Nothing was changed."))
            return ExitCode.OK
        _vscode_update(context, Edition.STABLE, stable)
        _share(context)
        if (
            insiders is not None
            and host.extensions_dir(Edition.INSIDERS).is_dir()
        ):
            _vscode_update(context, Edition.INSIDERS, insiders)
            _share(context)
        else:
            _print(notice(style, "muted", "Insiders is not installed here."))
        code = ExitCode.OK
        if not args.skip_clean:
            _guard(context)
            plan = plan_clean(take_snapshot(host), tuple(Edition))
            code = _quarantine(plan, context)
    return code


def _vscode_update(context: Context, edition: Edition, command: Path) -> None:
    """Run one edition's update, showing what it prints."""
    style = context.style
    _guard(context)
    _print(["", *ui.section(style, f"{edition.label} update")])
    updated = update_extensions(
        command,
        context.host.extensions_dir(edition),
        context.host.env,
        lambda line: print(event(style, "muted", line), flush=True),
    )
    count = len(updated)
    text = f"{count} extension{'s' * (count != 1)} updated"
    print(event(style, "ok", text), flush=True)


def _share(context: Context) -> None:
    """Apply what setup would do now, if anything."""
    _guard(context)
    plan = plan_setup(take_snapshot(context.host))
    if not plan.changed:
        print(event(context.style, "ok", "Insiders already follows"))
        return
    kept, warnings = _execute(plan, context, plan_setup)
    _done(context, plan, kept, warnings)


def _execute(
    plan: Plan, context: Context, planner: Planner
) -> tuple[list[Path], list[str]]:
    """Apply a plan in a transaction and verify it by planning again.

    Raises:
        SyncError: If a step or the verification fails; every applied step
            has been undone by then, or the error says where the originals
            are.
    """
    state_dir = context.host.state_dir()
    workspace = new_workspace(state_dir, plan.command)
    transaction = Transaction(workspace, state_dir / "kept" / workspace.name)
    try:
        for operation in plan.operations:
            transaction.apply(operation)
        after = planner(take_snapshot(context.host))
        if after.changed:
            raise SyncError(
                f"{len(after.operations)} changes were still due afterwards"
            )
    except BaseException as error:
        failures = transaction.rollback()
        what = str(error) or "interrupted"
        if failures:
            raise SyncError(
                f"{what}; undoing it failed ({'; '.join(failures)}); the "
                f"original files are in {workspace}"
            ) from error
        if not isinstance(error, SyncError | KeyboardInterrupt):
            raise
        raise SyncError(f"{what}; every change was undone") from None
    kept, warnings = transaction.commit()
    warnings += prune(state_dir / "kept", KEPT_RUNS)
    return kept, warnings


def _quarantine(plan: Plan, context: Context) -> ExitCode:
    """Move the planned folders into the quarantine and report."""
    host = context.host
    roots = {edition: host.extensions_dir(edition) for edition in Edition}
    operations = [
        operation
        for operation in plan.operations
        if isinstance(operation, Quarantine)
    ]
    result = quarantine(operations, roots, host.state_dir())
    lines: list[str] = []
    if result.directory is not None:
        count = len(result.moved)
        lines = notice(
            context.style,
            "ok",
            f"Quarantined {count} folder{'s' * (count != 1)}",
            [f"in {result.directory}"],
        )
    if result.failed:
        lines += notice(
            context.style, "error", "Not quarantined", list(result.failed)
        )
    if lines:
        _print(["", *lines])
    for warning in result.warnings:
        print(f"{PROG}: warning: {warning}", file=sys.stderr)
    return ExitCode.ERROR if result.failed else ExitCode.OK


def _done(
    context: Context, plan: Plan, kept: list[Path], warnings: list[str]
) -> None:
    """Report an applied plan."""
    lines = [f"kept Insiders' own {path.name} in {path}" for path in kept]
    _print(
        ["", *notice(context.style, "ok", f"Applied {_count(plan)}", lines)]
    )
    for warning in warnings:
        print(f"{PROG}: warning: {warning}", file=sys.stderr)


def _guard(context: Context) -> None:
    """Refuse to go on while VS Code runs.

    Raises:
        SyncError: If an edition is running.
    """
    running = running_editions(context.host, context.processes)
    if running:
        names = " and ".join(
            edition.label for edition in Edition if edition in running
        )
        raise SyncError(f"close VS Code {names} first")


def _refuse_interrupted(snapshot: Snapshot) -> None:
    """Refuse to change anything after an interrupted run.

    Raises:
        SyncError: If a workspace of an earlier run is left over.
    """
    if snapshot.interrupted:
        raise SyncError(
            "an earlier run was interrupted; its original files are in "
            f"{snapshot.interrupted[0]}. Check them, put back what is "
            "missing, then remove that directory"
        )


def _ask(context: Context, question: str) -> bool:
    """Ask before changing anything."""
    return confirm(
        question,
        context.style,
        context.host.env,
        stdin_is_terminal=context.terminal,
    )


def _count(plan: Plan) -> str:
    """The number of changes, in words."""
    count = len(plan.operations)
    return f"{count} change{'s' * (count != 1)}"


def _print(lines: Sequence[str]) -> None:
    """Print report lines."""
    print("\n".join(lines), flush=True)
