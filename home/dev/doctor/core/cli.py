"""The ``dev-doctor`` and ``toolchain`` command lines.

``dev-doctor`` exits 0 when every check passed, 1 when one is inconclusive
or PATH needs attention, and 2 when something is broken or the command line
is wrong. ``toolchain`` exits 0 on success, 1 when it found nothing usable
and 2 for a usage error.
"""

import argparse
import json
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import terminal_style as ui

from . import DOCTOR, TOOLCHAIN, __version__
from .compilers import command, identify, inspect
from .deep import Deep, deep
from .doctor import (
    Conflict,
    Record,
    State,
    apply_updates,
    binary_of,
    check_all,
    npm_conflict,
    order,
    path_conflicts,
    updates,
)
from .errors import DoctorError
from .host import Host, Origin
from .registry import applicable
from .report import (
    doctor_json,
    doctor_report,
    doctor_status,
    info_report,
    log,
    sdk_report,
)
from .sdk import survey
from .selection import State as Kept
from .selection import Toolchain, find, switch

COMPILER_TIMEOUT = 10.0
"""Seconds a compiler may take to print its banner."""


@dataclass(frozen=True)
class Context:
    """The machine, the clock and the two output streams' styles."""

    host: Host
    style: ui.Style
    errors: ui.Style
    now: Callable[[], datetime] = datetime.now

    @classmethod
    def detect(cls) -> "Context":
        """The running machine and terminal."""
        return cls(
            Host.detect(), ui.Style.detect(), ui.Style.detect(sys.stderr)
        )


# Health Report ----------------------------------------------------------------

_STATES = (
    "States: ok, outdated, dormant (a per-shell manager not activated here), "
    "unused, shadowed, broken, absent, unknown. Runtime startup is checked "
    "where declared; ok is not a full build test. CC and CXX overrides are "
    f"honoured; '{TOOLCHAIN} info' details the C/C++ compilers."
)


def doctor_parser() -> argparse.ArgumentParser:
    """The ``dev-doctor`` options."""
    parser = argparse.ArgumentParser(
        prog=DOCTOR,
        description="Report the health of the development environment.",
        epilog=_STATES,
    )
    parser.add_argument(
        "-u",
        "--updates",
        action="store_true",
        help="query the managers that have a native update check",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="ignore the cached update signals (implies --updates)",
    )
    parser.add_argument(
        "--only",
        metavar="IDS",
        help="check only these comma-separated runtime ids",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="include runtimes that are not installed",
    )
    parser.add_argument(
        "--deep",
        action="store_true",
        help="also run dev-bootstrap verify --health",
    )
    parser.add_argument(
        "--json", action="store_true", help="print the report as JSON"
    )
    parser.add_argument(
        "--version", action="version", version=f"{DOCTOR} {__version__}"
    )
    return parser


def doctor_main(
    argv: Sequence[str] | None = None, context: Context | None = None
) -> int:
    """Run ``dev-doctor``; the exit status."""
    parser = doctor_parser()
    args = parser.parse_args(argv)
    try:
        context = context or Context.detect()
        return _doctor(args, context, parser)
    except DoctorError as error:
        print(f"{DOCTOR}: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print(f"{DOCTOR}: Interrupted", file=sys.stderr)
        return 130


def _doctor(
    args: argparse.Namespace,
    context: Context,
    parser: argparse.ArgumentParser,
) -> int:
    """Check, then report as text or JSON."""
    host = context.host
    timeout = _number(host, "DEVDOCTOR_TIMEOUT", 5)
    jobs = int(_number(host, "DEVDOCTOR_JOBS", 0, integer=True))
    runtimes = applicable(host.platform)
    if args.only:
        known = {runtime.id: runtime for runtime in runtimes}
        wanted = [part for part in args.only.split(",") if part]
        unknown = [part for part in wanted if part not in known]
        if unknown or not wanted:
            parser.error(f"Unknown runtime id: {', '.join(unknown) or '-'}")
        runtimes = [known[part] for part in dict.fromkeys(wanted)]

    records = check_all(runtimes, host, timeout, jobs)
    if args.updates or args.refresh:
        print(
            log(context.errors, "info", "Querying update sources"),
            file=sys.stderr,
        )
        found = updates(
            host,
            refresh=args.refresh,
            ttl=_number(host, "DEVDOCTOR_UPDATE_TTL", 21600),
            timeout=_number(host, "DEVDOCTOR_NET_TIMEOUT", 30),
        )
        records = apply_updates(records, found)
    conflicts = _conflicts(host, records, timeout)
    health: Deep | None = None
    if args.deep:
        message = "Running dev-bootstrap verify --health"
        print(log(context.errors, "info", message), file=sys.stderr)
        health = deep(host)

    shown = order(
        r for r in records if args.all or r.state is not State.ABSENT
    )
    if args.json:
        print(json.dumps(doctor_json(shown, conflicts, health), indent=2))
    else:
        lines = doctor_report(
            context.style,
            host,
            shown,
            conflicts,
            health,
            updates=args.updates or args.refresh,
            now=context.now(),
        )
        print("\n".join(lines))
    return doctor_status(shown, conflicts, health)


def _conflicts(
    host: Host, records: Sequence[Record], timeout: float
) -> list[Conflict]:
    """PATH conflicts and a misplaced npm prefix."""
    binaries: list[str] = []
    managed: list[str] = []
    roots: list[Path] = []
    for record in records:
        binary = binary_of(record.runtime, host)
        if binary:
            binaries.append(binary)
            if record.origin == Origin.MANAGER.value:
                managed.append(binary)
        roots += record.runtime.resolve_roots(host)
    conflicts = path_conflicts(host, binaries, managed)
    npm = npm_conflict(host, dict.fromkeys(roots), timeout)
    return [*conflicts, *([npm] if npm else [])]


def _number(
    host: Host, name: str, default: float, *, integer: bool = False
) -> float:
    """A positive number from the environment, or the default when unset.

    Raises:
        DoctorError: If the variable is set to anything else.
    """
    text = host.get(name)
    if not text:
        return default
    try:
        value = int(text) if integer else float(text)
    except ValueError:
        value = -1
    if value <= 0:
        kind = "a positive integer" if integer else "a positive number"
        raise DoctorError(f"{name} must be {kind}, not {text!r}")
    return value


# Compilers --------------------------------------------------------------------


def toolchain_parser() -> argparse.ArgumentParser:
    """The ``toolchain`` subcommands."""
    parser = argparse.ArgumentParser(
        prog=TOOLCHAIN,
        description="Explain and select the C/C++ compilers of this shell.",
    )
    parser.add_argument(
        "--version", action="version", version=f"{TOOLCHAIN} {__version__}"
    )
    commands = parser.add_subparsers(dest="command", metavar="COMMAND")
    info = commands.add_parser(
        "info", help="show what each compiler name resolves to (default)"
    )
    info.add_argument(
        "--debug",
        action="store_true",
        help="also show what each wrapper reports",
    )
    sdk = commands.add_parser(
        "sdk", help="show which SDK headers the active compiler reaches"
    )
    sdk.add_argument(
        "-a",
        "--all",
        action="store_true",
        help="list every header, not only the divergent ones",
    )
    env = commands.add_parser(
        "env",
        help="print shell code that selects a toolchain (use_llvm, use_gnu)",
    )
    env.add_argument("toolchain", choices=[t.value for t in Toolchain])
    env.add_argument(
        "--state",
        default="",
        help="what the previous switch left in $_TOOLCHAIN_STATE",
    )
    return parser


def toolchain_main(
    argv: Sequence[str] | None = None, context: Context | None = None
) -> int:
    """Run ``toolchain``; the exit status."""
    args = toolchain_parser().parse_args(argv)
    try:
        context = context or Context.detect()
        if args.command == "sdk":
            return _sdk(args, context)
        if args.command == "env":
            return _env(args, context)
        return _info(args, context)
    except DoctorError as error:
        print(f"{TOOLCHAIN}: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(f"{TOOLCHAIN}: Interrupted", file=sys.stderr)
        return 130


def _info(args: argparse.Namespace, context: Context) -> int:
    """``toolchain info``."""
    host = context.host
    flag = host.get("TOOLCHAIN_INFO_DEBUG")
    debug = bool(getattr(args, "debug", False)) or flag not in ("", "0")
    entries = inspect(host, COMPILER_TIMEOUT)
    print("\n".join(info_report(context.style, host, entries, debug)))
    return 0


def _sdk(args: argparse.Namespace, context: Context) -> int:
    """``toolchain sdk``."""
    host = context.host
    found = survey(host)
    print("\n".join(sdk_report(context.style, host, found, args.all)))
    return 0


def _env(args: argparse.Namespace, context: Context) -> int:
    """``toolchain env``: report on standard error, code on standard output.

    Nothing reaches standard output unless the selection is complete, so
    the function that evaluates it never applies half a change.
    """
    host, style = context.host, context.errors
    toolchain = Toolchain(args.toolchain)
    state = Kept.decode(args.state) if args.state else None

    def say(*lines: str) -> None:
        """Report to the person, never to the shell evaluating stdout."""
        for line in lines:
            print(line, file=sys.stderr)

    if args.state and state is None:
        say(log(style, "warn", "Ignoring an unreadable _TOOLCHAIN_STATE."))
    if toolchain is Toolchain.SYSTEM:
        subtitle = "Restoring CC and CXX from before the first switch"
    else:
        subtitle = "Activating for the current shell"
    say(*ui.header(style, TOOLCHAIN, f"{toolchain.title} toolchain", subtitle))

    if toolchain is Toolchain.SYSTEM:
        change = switch(host, toolchain, state, None)
        environment = {**host.env, **change.environment}
        for label, name, fallback in (
            ("C", "CC", "cc"),
            ("C++", "CXX", "c++"),
        ):
            value = environment.get(name) or fallback
            say(_compiler_line(style, host, label, value, environment))
        sys.stdout.write(change.shell())
        say(log(style, "ok", "System toolchain restored."))
        return 0

    pair = find(host, toolchain, COMPILER_TIMEOUT)
    if pair is None:
        hint = "install it with the platform package manager"
        missing = "Clang" if toolchain is Toolchain.LLVM else "GCC"
        say(log(style, "error", f"No working {missing} pair found; {hint}."))
        return 1
    say(
        log(style, "ok", f"C: {pair.c.name} · {pair.c_identity.banner}"),
        log(style, "ok", f"C++: {pair.cxx.name} · {pair.cxx_identity.banner}"),
    )
    sys.stdout.write(switch(host, toolchain, state, pair).shell())
    say(log(style, "ok", f"{toolchain.title} is active for this shell."))
    return 0


def _compiler_line(
    style: ui.Style,
    host: Host,
    label: str,
    value: str,
    environment: dict[str, str | None],
) -> str:
    """A line naming the compiler a variable now selects, or its absence."""
    argv = command(value)
    restored = Host(
        host.platform,
        host.home,
        {k: v for k, v in environment.items() if v is not None},
    )
    path = restored.which(argv[0])
    if path is None:
        return log(style, "warn", f"No {label} compiler {value!r} on PATH.")
    identity = identify(restored, (str(path), *argv[1:]), COMPILER_TIMEOUT)
    if not identity.ran:
        return log(style, "warn", f"{label}: {path.name} does not run.")
    return log(style, "ok", f"{label}: {path.name} · {identity.banner}")
