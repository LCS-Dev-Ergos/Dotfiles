"""The command line: ``status``, ``check``, ``setup``, ``update``, ``remove``
and ``clean``.

Every command first reports. A changing command then takes the lock, refuses
while VS Code runs, undoes a run an interruption left behind, asks, backs up
the files it may change, downloads the builds a repair needs and applies its
plan in a transaction that is checked by planning again; ``--dry-run`` stops
after the report.
"""

import argparse
import dataclasses
import json
import sys
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path

import terminal_style as ui

from . import PROG, __version__
from .errors import SyncError
from .host import TARGETS, Edition, Host
from .plan import (
    Downloads,
    Finding,
    Install,
    Plan,
    Quarantine,
    Snapshot,
    interrupted_runs,
    plan_clean,
    plan_remove,
    plan_setup,
    read_downloads,
    read_side,
    take_snapshot,
    unusable,
)
from .report import event, notice, render, to_json
from .safety import confirm, locked, running_editions
from .storage import (
    backup,
    count_stamped,
    new_workspace,
    private_dir,
    remove_tree,
    stamp,
)
from .transaction import Transaction, quarantine, recover
from .update import find_command, install_extension, update_extensions

Planner = Callable[[Snapshot, Downloads | None], Plan]


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
            "Share VS Code Stable's extensions with VS Code Insiders and "
            "VS Code Server through links, and Stable's settings, "
            "keybindings, snippets and MCP servers with Insiders."
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
        _targets(command)
    for name, text in (
        ("setup", "make each consumer share what it can with Stable"),
        ("remove", "give each consumer its own copy of everything shared"),
    ):
        command = commands.add_parser(name, help=text, description=text)
        _targets(command)
        _changing(command)
    update = commands.add_parser(
        "update",
        help="update every edition's extensions, then share again",
        description=(
            "Run VS Code's own extension update for Stable, let each "
            "consumer follow, update each consumer's own extensions, share "
            "again and clean up duplicates."
        ),
    )
    update.add_argument(
        "--skip-clean", action="store_true", help="leave duplicates in place"
    )
    _targets(update)
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
        choices=["all", *(edition.value for edition in Edition)],
        default="all",
        help="which extensions directory to clean (default: every one here)",
    )
    _changing(clean)
    return parser


def _targets(command: argparse.ArgumentParser) -> None:
    """The option that picks the consumers a command works on."""
    command.add_argument(
        "--target",
        action="append",
        choices=[edition.value for edition in TARGETS],
        help=(
            "the consumer to work on, repeatable "
            "(default: every one installed here)"
        ),
    )


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


def _snapshots(args: argparse.Namespace, context: Context) -> list[Snapshot]:
    """One snapshot per consumer the command works on.

    Without ``--target``, every consumer installed here; when there is
    none, Insiders, so that the report says it is not installed.
    """
    host = context.host
    if args.target:
        chosen = dict.fromkeys(Edition(value) for value in args.target)
        return [take_snapshot(host, edition) for edition in chosen]
    snapshots = [take_snapshot(host, edition) for edition in TARGETS]
    return [s for s in snapshots if s.consumer.installed] or snapshots[:1]


def _editions(snapshots: Sequence[Snapshot]) -> list[Edition]:
    """Stable and the consumers of ``snapshots``: what a run touches."""
    return [Edition.STABLE, *(s.consumer.edition for s in snapshots)]


def _report(args: argparse.Namespace, context: Context) -> ExitCode:
    """``status`` and ``check``: what setup would do, changing nothing."""
    snapshots = _snapshots(args, context)
    plans = [
        dataclasses.replace(plan_setup(snapshot), command=args.command)
        for snapshot in snapshots
    ]
    plans[-1] = dataclasses.replace(
        plans[-1],
        findings=plans[-1].findings + tuple(_environment(context)),
    )
    if args.json:
        print(json.dumps([to_json(plan) for plan in plans], indent=2))
    else:
        _print_all(_status_lines(plan, context) for plan in plans)
    due = any(plan.changed or plan.problems for plan in plans)
    if args.command == "check" and (due or snapshots[0].interrupted):
        return ExitCode.ATTENTION
    return ExitCode.OK


def _status_lines(plan: Plan, context: Context) -> list[str]:
    """A status report, without the list of changes."""
    return render(plan, context.style, changes=False)


def _environment(context: Context) -> list[Finding]:
    """Notes on what a change would meet: running editors and backups."""
    findings: list[Finding] = []
    try:
        running = running_editions(context.host, context.processes)
    except SyncError as error:
        findings.append(Finding("warn", "VS Code", str(error)))
    else:
        findings += [
            Finding(
                "muted",
                f"VS Code {edition.label}",
                "running; a change waits until it is closed",
            )
            for edition in Edition
            if edition in running
        ]
    backups = context.host.state_dir() / "backups"
    count = count_stamped(backups)
    if count:
        findings.append(Finding("muted", "backups", f"{count} in {backups}"))
    return findings


def _change(
    args: argparse.Namespace, context: Context, planner: Planner
) -> ExitCode:
    """``setup`` and ``remove``: report, then apply unless it is a dry run.

    The plans of all consumers are shown first and confirmed together; each
    is then applied in a transaction of its own.
    """
    style = context.style
    if args.dry_run:
        plans = [planner(s, None) for s in _snapshots(args, context)]
        _print_all(render(plan, style, context="dry run") for plan in plans)
        changed = any(plan.changed for plan in plans)
        return ExitCode.ATTENTION if changed else ExitCode.OK
    with locked(context.host.state_dir()):
        _guard(context, _editions(_snapshots(args, context)))
        _recover(context)
        snapshots = _snapshots(args, context)
        plans = [planner(snapshot, None) for snapshot in snapshots]
        _print_all(render(plan, style) for plan in plans)
        due = [
            (snapshot, plan)
            for snapshot, plan in zip(snapshots, plans, strict=True)
            if plan.changed
        ]
        if not due:
            return ExitCode.OK
        size = sum(plan.size for _, plan in due)
        question = f"Apply {size} change{'s' * (size != 1)}?"
        if not args.yes and not _ask(context, question):
            _print(notice(style, "muted", "Nothing was changed."))
            return ExitCode.OK
        _backup(context, [snapshot for snapshot, _ in due], args.command)
        code = ExitCode.OK
        for _, plan in due:
            code = max(code, _apply(context, plan, planner))
        return ExitCode(code)


def _clean(args: argparse.Namespace, context: Context) -> ExitCode:
    """``clean``: quarantine unused duplicates of the editions here."""
    host = context.host
    sides = {edition: read_side(host, edition) for edition in Edition}
    if args.edition == "all":
        editions = [e for e, side in sides.items() if side.root.is_dir()]
    else:
        editions = [Edition(args.edition)]
    if args.dry_run:
        plan = plan_clean(sides, editions, interrupted_runs(host))
        _print(render(plan, context.style, context="dry run"))
        return ExitCode.ATTENTION if plan.changed else ExitCode.OK
    with locked(host.state_dir()):
        _guard(context, editions)
        _recover(context)
        sides = {edition: read_side(host, edition) for edition in Edition}
        plan = plan_clean(sides, editions)
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
    if args.dry_run:
        snapshots = _snapshots(args, context)
        plans = [
            dataclasses.replace(plan_setup(snapshot), command="update")
            for snapshot in snapshots
        ]
        _print_all(render(plan, style, context="dry run") for plan in plans)
        steps = _update_steps(context, snapshots, args.skip_clean)
        _print(["", *notice(style, "muted", "An update runs:", steps)])
        return ExitCode.OK
    with locked(host.state_dir()):
        _guard(context, _editions(_snapshots(args, context)))
        _recover(context)
        snapshots = _snapshots(args, context)
        stable = find_command(host, Edition.STABLE)
        if stable is None:
            raise SyncError(f"{Edition.STABLE.command} is not on PATH")
        plans = [
            dataclasses.replace(plan_setup(snapshot), command="update")
            for snapshot in snapshots
        ]
        _print_all(render(plan, style, changes=False) for plan in plans)
        steps = _update_steps(context, snapshots, args.skip_clean)
        _print(["", *notice(style, "muted", "An update runs:", steps)])
        if not args.yes and not _ask(context, "Run the update?"):
            _print(notice(style, "muted", "Nothing was changed."))
            return ExitCode.OK
        _backup(context, snapshots, "update")
        sharing = [
            s.consumer.edition for s in snapshots if unusable(s) is None
        ]
        code = ExitCode.OK
        for edition in sharing:
            code = max(code, _share(context, edition))
        _vscode_update(context, Edition.STABLE, stable)
        for edition in sharing:
            code = max(code, _share(context, edition))
        for edition in sharing:
            command = _own_command(context, edition)
            if command is not None:
                _vscode_update(context, edition, command)
                code = max(code, _share(context, edition))
        if not args.skip_clean:
            editions = [Edition.STABLE, *sharing]
            _guard(context, editions)
            sides = {edition: read_side(host, edition) for edition in Edition}
            code = max(code, _quarantine(plan_clean(sides, editions), context))
    return ExitCode(code)


def _own_command(context: Context, edition: Edition) -> Path | None:
    """A consumer's command line, when it has extensions of its own."""
    if not context.host.extensions_dir(edition).is_dir():
        return None
    return find_command(context.host, edition)


def _update_steps(
    context: Context, snapshots: Sequence[Snapshot], skip_clean: bool
) -> list[str]:
    """What an update will run here, numbered.

    Without a consumer only Stable is updated and cleaned; a consumer
    without its command line still follows Stable, but its own extensions
    stay as they are.
    """
    sharing = [s for s in snapshots if unusable(s) is None]
    names = " and ".join(s.label for s in sharing)
    steps: list[str] = []
    if sharing:
        steps.append(
            f"share what is due with {names}, so Stable's update meets "
            "consistent lists"
        )
    steps.append(f"run {Edition.STABLE.command} --update-extensions")
    if sharing:
        steps.append(f"let {names} follow Stable's builds")
    for snapshot in sharing:
        edition = snapshot.consumer.edition
        if _own_command(context, edition) is not None:
            steps.append(
                f"run {edition.command} --update-extensions for "
                f"{edition.label}, then share again"
            )
        else:
            steps.append(
                f"skip the update of {edition.label}'s own builds: "
                f"{edition.command} is not available"
            )
    if not skip_clean:
        which = ", ".join(["Stable", *(s.label for s in sharing)])
        steps.append(f"quarantine unused duplicates in {which}")
    return [f"{index}. {step}" for index, step in enumerate(steps, 1)]


def _vscode_update(context: Context, edition: Edition, command: Path) -> None:
    """Run one edition's update, showing what it prints."""
    style = context.style
    _guard(context, [edition])
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


def _share(context: Context, edition: Edition) -> ExitCode:
    """Apply what setup would do now for one consumer, if anything."""
    _guard(context, [Edition.STABLE, edition])
    plan = plan_setup(take_snapshot(context.host, edition))
    if not plan.changed:
        text = f"{edition.label} already follows Stable"
        print(event(context.style, "ok", text))
        return ExitCode.OK
    return _apply(context, plan, plan_setup)


def _apply(context: Context, plan: Plan, planner: Planner) -> ExitCode:
    """Download the builds a plan needs, then apply it.

    A download that fails leaves its entries as they are and makes the run
    end with an error, after everything else was applied.
    """
    state_dir = context.host.state_dir()
    edition = plan.consumer or Edition.INSIDERS
    failed: list[str] = []
    stage: Path | None = None
    try:
        if plan.installs:
            stage = private_dir(state_dir / "downloads") / stamp("download")
            downloads, failed = _download(
                context, edition, plan.installs, stage
            )
            _guard(context, [Edition.STABLE, edition])
            plan = planner(take_snapshot(context.host, edition), downloads)
        if plan.operations:
            _done(context, plan, _execute(plan, context, planner))
    finally:
        if stage is not None and stage.exists():
            remove_tree(stage)
    if failed:
        _print(["", *notice(context.style, "error", "Not downloaded", failed)])
        return ExitCode.ERROR
    return ExitCode.OK


def _download(
    context: Context,
    edition: Edition,
    installs: Sequence[Install],
    stage: Path,
) -> tuple[Downloads, list[str]]:
    """Download each build with the consumer's command line into ``stage``.

    The consumer's own command line downloads builds that run on it: for a
    server, its newest build's. The build an entry named is tried first,
    then the latest one.

    Returns:
        What was downloaded, and a reason for each build that was not.
    """
    host, style = context.host, context.style
    root = stage / "extensions"
    command = find_command(host, edition)
    if command is None:
        missing = f"{edition.command} is not available for {edition.label}"
        return Downloads(root), [
            f"{item.extension_id}: {missing}" for item in installs
        ]
    _print(["", *ui.section(style, "Downloads", str(len(installs)))])
    failed: list[str] = []
    for item in installs:
        specs = [item.extension_id]
        if item.version:
            specs.insert(0, f"{item.extension_id}@{item.version}")
        error: SyncError | None = None
        for spec in specs:
            try:
                install_extension(
                    command,
                    edition,
                    stage,
                    spec,
                    host.env,
                    lambda line: print(
                        event(style, "muted", line), flush=True
                    ),
                    pre_release=item.pre_release and "@" not in spec,
                )
            except SyncError as failure:
                error = failure
                continue
            error = None
            break
        if error is not None:
            failed.append(f"{item.extension_id}: {error}")
    return read_downloads(root), failed


def _execute(plan: Plan, context: Context, planner: Planner) -> list[str]:
    """Apply a plan in a transaction and verify it by planning again.

    Raises:
        SyncError: If a step or the verification fails; every applied step
            has been undone by then, or the error says where the originals
            are.
    """
    workspace = new_workspace(context.host.state_dir(), plan.command)
    transaction = Transaction(workspace)
    try:
        for operation in plan.operations:
            transaction.apply(operation)
        consumer = plan.consumer or Edition.INSIDERS
        after = planner(take_snapshot(context.host, consumer), None)
        if after.operations:
            raise SyncError(
                f"{len(after.operations)} changes were still due afterwards"
            )
    except BaseException as error:
        undone = transaction.rollback()
        what = str(error) or "interrupted"
        if undone.failures:
            raise SyncError(
                f"{what}; undoing it failed ({'; '.join(undone.failures)}); "
                f"the next run retries from {workspace}"
            ) from error
        if not isinstance(error, SyncError | KeyboardInterrupt):
            raise
        raise SyncError(f"{what}; every change was undone") from None
    return transaction.commit()


def _recover(context: Context) -> None:
    """Undo what an interrupted run left, and drop its downloads.

    Raises:
        SyncError: If a step of it cannot be undone.
    """
    state_dir = context.host.state_dir()
    for directory in ("downloads", "runs"):
        try:
            entries = sorted((state_dir / directory).iterdir())
        except FileNotFoundError:
            continue
        for entry in entries:
            if directory == "downloads":
                remove_tree(entry)
                continue
            undone = recover(entry)
            if undone.failures:
                raise SyncError(
                    f"cannot undo the interrupted run in {entry}: "
                    + "; ".join(undone.failures)
                )
            steps = f"{undone.steps} step{'s' * (undone.steps != 1)}"
            title = f"Undid an interrupted run ({steps})"
            _print(notice(context.style, "ok", title, list(undone.notes)))


def _backup(
    context: Context, snapshots: Sequence[Snapshot], label: str
) -> None:
    """Back up every file a run may change, before it changes any.

    One backup covers every consumer of the run, so a run counts once
    against the retention.

    Raises:
        SyncError: If a file cannot be copied; nothing has changed yet.
    """
    paths: list[Path] = []
    for snapshot in snapshots:
        for side in (snapshot.stable, snapshot.consumer):
            paths += [manifest.path for manifest in side.manifests]
            paths.append(side.obsolete.path)
        paths += [item.target for item in snapshot.items]
    paths = list(dict.fromkeys(paths))
    host = context.host
    directory, warnings = backup(host.state_dir(), host.home, label, paths)
    if directory is not None:
        print(event(context.style, "ok", f"Backed up to {directory}"))
    for warning in warnings:
        print(f"{PROG}: warning: {warning}", file=sys.stderr)


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


def _done(context: Context, plan: Plan, warnings: list[str]) -> None:
    """Report an applied plan."""
    count = len(plan.operations)
    title = f"Applied {count} change{'s' * (count != 1)}"
    _print(["", *notice(context.style, "ok", title)])
    for warning in warnings:
        print(f"{PROG}: warning: {warning}", file=sys.stderr)


def _guard(context: Context, editions: Sequence[Edition]) -> None:
    """Refuse to go on while one of ``editions`` runs.

    A server runs while a remote client is connected to it.

    Raises:
        SyncError: If one of them is running.
    """
    running = running_editions(context.host, context.processes)
    busy = [edition for edition in Edition if edition in running]
    busy = [edition for edition in busy if edition in editions]
    if busy:
        names = " and ".join(edition.label for edition in busy)
        raise SyncError(f"close VS Code {names} first")


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
    return f"{plan.size} change{'s' * (plan.size != 1)}"


def _print_all(reports: Iterable[Sequence[str]]) -> None:
    """Print reports one after the other, a blank line apart."""
    for index, lines in enumerate(reports):
        _print(["", *lines] if index else lines)


def _print(lines: Sequence[str]) -> None:
    """Print report lines."""
    print("\n".join(lines), flush=True)
