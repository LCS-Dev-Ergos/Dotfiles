"""The command line: ``resolve`` and ``apply``, run by hand only."""

import argparse
import sys
from collections.abc import Sequence
from enum import IntEnum
from pathlib import Path

from . import PROG, __version__
from .errors import SettingsError
from .host import Edition, Host
from .plan import build_plan
from .report import render_diff, render_plan, render_resolution, render_write
from .storage import Backups, commit, load


class ExitCode(IntEnum):
    """The exit status; ``USAGE`` is what argparse exits with."""

    OK = 0
    DRIFT = 1
    USAGE = 2
    ERROR = 3


def build_parser() -> argparse.ArgumentParser:
    """The argument parser of the command."""
    parser = argparse.ArgumentParser(
        prog=PROG,
        description=(
            "Resolve the host-bound paths in VS Code's user settings.json for "
            "this machine. Run it by hand; nothing calls it automatically."
        ),
    )
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser(
        "resolve", help="show what each managed key resolves to here"
    )
    apply = commands.add_parser(
        "apply",
        help="write the resolved values",
        description=(
            "Write the resolved values. With --dry-run nothing is written "
            "and the exit status is 1 when the file would change."
        ),
    )
    apply.add_argument(
        "--settings",
        action="append",
        default=[],
        type=Path,
        metavar="FILE",
        help="settings.json to process (repeatable; default: the user file)",
    )
    apply.add_argument(
        "--edition",
        choices=[edition.value for edition in Edition],
        default=Edition.STABLE.value,
        help="which VS Code edition's default file to use",
    )
    apply.add_argument(
        "--diff", action="store_true", help="show the exact text change"
    )
    apply.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would change without writing; exit 1 if anything",
    )
    return parser


def settings_files(
    given: Sequence[Path], edition: Edition, host: Host
) -> list[Path]:
    """The settings files to process, each real file once.

    Without explicit files, the edition's user settings file of the host.

    Raises:
        SettingsError: If the default location cannot be inspected here.
    """
    if not given:
        default = host.user_data_dir(edition) / "settings.json"
        return [host.concrete(default)]
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in (path.expanduser() for path in given):
        try:
            identity = path.resolve(strict=True)
        except (OSError, RuntimeError):
            identity = path
        if identity not in seen:
            seen.add(identity)
            unique.append(path)
    return unique


def run_apply(args: argparse.Namespace, host: Host) -> ExitCode:
    """Plan, report and, unless it is a dry run, write each file.

    An error in one file is reported and the next file is still processed.
    """
    try:
        paths = settings_files(args.settings, Edition(args.edition), host)
    except SettingsError as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        return ExitCode.ERROR
    code = ExitCode.OK
    for path in paths:
        try:
            file = load(path)
            plan = build_plan(file.path, file.text, host)
            print(render_plan(plan, dry_run=args.dry_run))
            if args.diff and plan.changed:
                sys.stdout.write(render_diff(plan))
            if args.dry_run:
                if plan.changed:
                    code = max(code, ExitCode.DRIFT)
                continue
            result = commit(file, plan.new_text, Backups.for_host(host))
            if result.written:
                print(render_write(result))
            for warning in result.warnings:
                print(f"{PROG}: warning: {warning}", file=sys.stderr)
        except SettingsError as error:
            print(f"{PROG}: {error}", file=sys.stderr)
            code = ExitCode.ERROR
    return code


def main(argv: Sequence[str] | None = None, host: Host | None = None) -> int:
    """Run the command line.

    Args:
        argv: The arguments without the program name; default: sys.argv.
        host: The machine to resolve for; default: the running one.

    Returns:
        The exit status, an ``ExitCode``.
    """
    args = build_parser().parse_args(argv)
    host = host or Host.detect()
    if args.command == "resolve":
        print(render_resolution(host))
        return ExitCode.OK
    return run_apply(args, host)
