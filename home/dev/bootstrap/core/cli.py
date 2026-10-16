"""Command-line parsing, orchestration and stable JSON/text reporting."""

import argparse
import json
import os
import signal
import sys
from contextlib import contextmanager
from pathlib import Path

from . import process
from .adapters import ADAPTERS
from .engine import Bootstrap, select
from .errors import BootstrapError, Interrupted
from .guided import Guide
from .manifest import load_manifest
from .prompt import Cancelled, prompter
from .progress import Progress
from .prune import Prune
from .render import render
from .runs import Recorder, recorded_runs, runs_directory, stored_report
from .selection import load_selection, save_selection, selection_path
from .setup import BootstrapSetup
from .ui import Style, sanitize_lines

# The JSON report's schema; Interfaces.md says what changes it.
REPORT_SCHEMA = 1
# What the guided setup reads before each step: plan --preflight.
PREFLIGHT = argparse.Namespace(action="plan", health=False, preflight=True)


def command_line():
    """The argument parser; main() checks how options combine."""
    parser = argparse.ArgumentParser(
        prog="dev-bootstrap",
        description="Plan, bootstrap and verify the declared runtime baseline.",
    )
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "action",
        nargs="?",
        default="plan",
        choices=("plan", "apply", "verify", "prune", "report", "setup"),
    )
    chosen = parser.add_mutually_exclusive_group()
    chosen.add_argument(
        "--only",
        choices=tuple(ADAPTERS),
        action="append",
        help="Select an ecosystem instead of the saved selection; repeatable",
    )
    chosen.add_argument(
        "--all",
        action="store_true",
        help="Select every default ecosystem, ignoring the saved selection",
    )
    parser.add_argument(
        "--save-selection",
        action="store_true",
        help="Save the --only selection for later runs, or forget it with --all",
    )
    parser.add_argument(
        "--accept",
        choices=sorted(
            {
                name
                for adapter in ADAPTERS.values()
                for name in adapter.consents
            }
        ),
        action="append",
        default=[],
        help="Accept terms a selected ecosystem requires before installation",
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="Report as text for a person or as JSON for programs",
    )
    output.add_argument(
        "--json",
        dest="format",
        action="store_const",
        const="json",
        help="Alias of --format json",
    )
    parser.add_argument(
        "--runtimes-only",
        action="store_true",
        help="Skip native provisioning, initial defaults and shell qualification",
    )
    parser.add_argument(
        "--health",
        action="store_true",
        help="Verify selected evolved runtimes instead of exact baseline identities",
    )
    parser.add_argument(
        "--preflight",
        action="store_true",
        help="Also report, read-only, the native packages, privilege and "
        "releases apply would need",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Remove the retired releases prune lists, instead of listing "
        "them; accept setup's review without asking",
    )
    parser.add_argument(
        "--events",
        type=Path,
        metavar="PATH",
        help="Write the progress of apply, setup or prune --yes to PATH as "
        "JSON Lines",
    )
    shown = parser.add_mutually_exclusive_group()
    shown.add_argument(
        "--last",
        action="store_true",
        help="Show the newest recorded run's report again",
    )
    shown.add_argument(
        "--run",
        metavar="ID",
        help="Show that recorded run's report again",
    )
    return parser


def main():
    parser = command_line()
    args = parser.parse_args()
    if args.health and args.action != "verify":
        parser.error("--health requires verify")
    if args.preflight and args.action != "plan":
        parser.error("--preflight requires plan")
    if args.yes and args.action not in ("prune", "setup"):
        parser.error("--yes requires prune or setup")
    if args.save_selection and not (args.only or args.all):
        parser.error("--save-selection requires --only or --all")
    if args.events and not (
        args.action in ("apply", "setup")
        or args.action == "prune"
        and args.yes
    ):
        parser.error("--events requires apply, setup or prune --yes")
    if (args.last or args.run) and args.action != "report":
        parser.error("--last and --run require report")
    if args.action == "report" and (
        args.only or args.all or args.accept or args.runtimes_only
    ):
        parser.error("report shows recorded runs; it selects nothing")
    if args.action == "setup" and (
        args.format == "json" or args.save_selection or args.runtimes_only
    ):
        parser.error(
            "setup guides a person through the whole native setup; "
            "plan --preflight --json reports it for programs"
        )
    os.umask(0o077)
    # The setup in use, so an interruption can name its stage.
    setups = []
    try:
        with termination():
            return run(args, setups)
    except Cancelled:
        print(
            "dev-bootstrap: setup cancelled; nothing changed", file=sys.stderr
        )
        return 130
    except (KeyboardInterrupt, Interrupted) as error:
        signum = getattr(error, "signum", signal.SIGINT)
        if args.action == "setup" and not setups:
            print(
                "dev-bootstrap: setup interrupted before any change",
                file=sys.stderr,
            )
            return 128 + signum
        stage = ""
        if setups:
            stage = f" during {setups[0].stage}"
        print(
            f"dev-bootstrap: interrupted{stage}; the lock is released. Apply "
            "again to finish: it replaces what the interrupted installation "
            "left.",
            file=sys.stderr,
        )
        return 128 + signum


@contextmanager
def termination():
    """Turn SIGTERM and SIGHUP into an exception, like Ctrl-C.

    Unwinding releases the lock, removes temporary directories and stops the
    running child's process group; the default action would skip all three.
    A signal the caller ignores (nohup ignores SIGHUP) stays ignored, as
    Python itself leaves an ignored SIGINT alone.
    """

    def interrupt(signum, frame):
        raise Interrupted(signum)

    previous = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGTERM, signal.SIGHUP)
        if signal.getsignal(signum) != signal.SIG_IGN
    }
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def run(args, setups):
    """Execute the parsed command; expected failures exit 2.

    apply and prune --yes keep a record of the run (core.runs), also when
    they fail or are interrupted.
    """
    context = recorder = None
    origin = {}
    try:
        if args.action == "report":
            return show_runs(args)
        manifest = load_manifest(args.manifest)
        only, origin = choose(args, manifest)
        if args.action == "setup":
            return guide(manifest, only, origin, args, setups)
        context = Bootstrap(manifest, only, accepted=args.accept)
        if args.action == "apply" or args.yes:
            recorder = Recorder(
                "prune --yes" if args.yes else args.action, events=args.events
            )
            if args.format == "text":
                recorder.listeners.append(
                    Progress(context.catalog(), Style.detect(sys.stderr))
                )
            context.recorder = recorder
        if origin["source"] == "file" and args.format == "text":
            print(
                f"dev-bootstrap: selection saved in {origin['path']}; "
                "--all ignores it",
                file=sys.stderr,
            )
        if args.save_selection:
            # Saved once the selection is known to be valid here, whatever
            # the action then reports.
            save_selection(
                selection_path(), context.only if args.only else None
            )
        if args.action == "prune":
            result = prune(context, args)
            result["selection"] = origin
            # Listing never fails; removal fails unless every release went.
            code = (
                0
                if not args.yes
                or all(row["state"] == "removed" for row in result["retired"])
                else 1
            )
            if recorder:
                recorder.finish(result, code)
            report(result, args.format, applied=args.yes)
            return code
        setup = None
        if (
            not args.runtimes_only
            and context.data.get("setup")
            and context.backend == "native"
        ):
            setup = BootstrapSetup(context)
            setups.append(setup)
        if args.preflight and setup is None:
            raise BootstrapError(
                "--preflight inspects the native setup, which this run "
                "does not use (nixpkgs backend or --runtimes-only)"
            )
        result = execute(context, setup, args)
        result["selection"] = origin
        code = (
            0
            if args.action == "plan"
            # External selections belong to the host, not to a native manager.
            or all(
                row["state"] in ("ok", "external")
                for row in result["runtimes"]
            )
            else 1
        )
        if recorder:
            recorder.finish(result, code)
        report(result, args.format)
        return code
    except (BootstrapError, OSError, ValueError) as error:
        # The message may quote a child's output: its control characters
        # must not drive the terminal.
        print(f"dev-bootstrap: {sanitize_lines(error)}", file=sys.stderr)
        if recorder:
            stopped(recorder, context, args, origin, setups, 2, str(error))
            if recorder.failed_log:
                print(
                    f"dev-bootstrap: the full output is in {recorder.failed_log}",
                    file=sys.stderr,
                )
        return 2
    except (KeyboardInterrupt, Interrupted) as error:
        if recorder:
            signum = getattr(error, "signum", signal.SIGINT)
            stopped(
                recorder,
                context,
                args,
                origin,
                setups,
                128 + signum,
                f"interrupted by {signal.Signals(signum).name}",
            )
        raise


def stopped(recorder, context, args, origin, setups, code, message):
    """Record a run that ended without its report, with what it left.

    The runtimes are planned again, read-only, so the record shows what is
    installed now; a run that cannot even plan keeps its error alone.
    """
    result = {
        "schema": REPORT_SCHEMA,
        "action": args.action,
        "platform": context.data["platform"],
        "backend": context.backend,
        "defaults": context.data["defaults"],
        "catalog": context.catalog(),
        "selection": origin,
        "runtimes": [],
    }
    try:
        result["runtimes"] = context.plan()
        result["observed"] = context.observed_state()
    except (BootstrapError, OSError, ValueError):
        pass
    error = {"message": message}
    if args.action == "apply" and setups:
        error["stage"] = setups[0].stage
    recorder.finish(result, code, error)


def show_runs(args):
    """`report`: list the kept runs, or show one run's report again."""
    if args.last or args.run:
        result = stored_report(args.run)
        if result.get("schema") != REPORT_SCHEMA:
            raise BootstrapError(
                f"The run's report has schema {result.get('schema')}; this "
                f"dev-bootstrap reads schema {REPORT_SCHEMA}"
            )
        command = result.get("run", {}).get("command")
        report(result, args.format, applied=command == "prune --yes")
        return 0
    report(
        {
            "schema": REPORT_SCHEMA,
            "action": "report",
            "directory": str(runs_directory()),
            "runs": recorded_runs(),
        },
        args.format,
    )
    return 0


def choose(args, manifest):
    """The ecosystems this run selects, and where that choice came from.

    --only replaces the saved selection and --all ignores it; without
    either, a saved selection applies to every action.
    """
    if args.only:
        return args.only, {"source": "only"}
    if args.all:
        return None, {"source": "all"}
    path = selection_path()
    saved = load_selection(path)
    if saved is None:
        return None, {"source": "default"}
    try:
        select(manifest, saved)
    except BootstrapError as error:
        raise BootstrapError(
            f"{error} (saved selection {path}; --all ignores it)"
        ) from error
    return saved, {"source": "file", "path": str(path)}


def guide(manifest, only, origin, args, setups):
    """`setup`: detect, choose, review, then apply in this process."""
    if manifest["backend"] != "native" or not manifest.get("setup"):
        raise BootstrapError(
            "setup guides the native setup, which this baseline does not use "
            "(nixpkgs backend)"
        )

    def planner(selection):
        context = Bootstrap(manifest, selection, accepted=args.accept)
        return execute(context, BootstrapSetup(context), PREFLIGHT)

    def executor(selection, accepted):
        # The same run `dev-bootstrap apply` makes with these options.
        applying = argparse.Namespace(**vars(args))
        applying.action = "apply"
        applying.only = selection["only"]
        applying.all = selection["all"]
        applying.accept = list(accepted)
        applying.yes = False
        return run(applying, setups)

    style = Style.detect()
    asker = prompter(
        manifest.get("frontend", {}), style, attended=process.attended()
    )
    return Guide(
        manifest,
        planner,
        asker,
        style,
        executor=executor,
        selection_file=selection_path(),
    ).run(only, origin, args.accept, yes=args.yes)


def execute(context, setup, args):
    """Run the requested action and build the stable JSON result."""
    rows = context.plan()
    if setup and args.action == "plan":
        rows = setup.installable(rows)
    selections = None
    if args.action == "apply":
        if setup:
            selections = setup.apply()
        else:
            context.apply(rows)
        rows = context.plan()
    if args.health and setup:
        rows = setup.selections()
    elif args.health and context.backend == "native":
        raise BootstrapError(
            "Health verification requires the generated setup policy"
        )
    elif args.action != "plan":
        # After a setup apply, baseline rows may carry evolved runtimes.
        exact = not (args.health or (setup and args.action == "apply"))
        context.qualify(rows, exact=exact)
    result = {
        "schema": REPORT_SCHEMA,
        "action": args.action,
        "platform": context.data["platform"],
        "backend": context.backend,
        "defaults": context.data["defaults"],
        "catalog": context.catalog(),
        "observed": context.observed_state(),
        "runtimes": rows,
    }
    if setup:
        result["setup"] = setup.plan()
    if args.preflight:
        result["preflight"] = setup.preflight()
    if selections is not None:
        # Manager-owned selections are reported; they never fail apply.
        result["selections"] = selections
    if args.health:
        result["verification"] = "health"
    return result


def prune(context, args):
    """List, or with --yes remove, the installed releases the baseline retired."""
    if context.backend != "native":
        raise BootstrapError("prune removes native releases only")
    pruning = Prune(context)
    retirements = pruning.apply() if args.yes else pruning.plan()
    return {
        "schema": REPORT_SCHEMA,
        "action": "prune",
        "platform": context.data["platform"],
        "backend": context.backend,
        "defaults": context.data["defaults"],
        "catalog": context.catalog(),
        "observed": context.observed_state(),
        "runtimes": context.plan(),
        "retired": [retirement.report() for retirement in retirements],
    }


def report(result, output_format, *, applied=False):
    """Print the report: JSON for programs, or text drawn for the terminal."""
    if output_format == "json":
        print(json.dumps(result, indent=2))
        return
    for line in render(result, Style.detect(), applied=applied):
        print(line)
