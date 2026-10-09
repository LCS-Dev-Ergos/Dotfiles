"""Command-line parsing, orchestration and stable JSON/text reporting."""

import argparse
import json
import os
import signal
import sys
import tarfile
from contextlib import contextmanager
from pathlib import Path

from .adapters import ADAPTERS
from .engine import Bootstrap, select
from .errors import BootstrapError, Interrupted
from .manifest import load_manifest
from .selection import load_selection, save_selection, selection_path
from .setup import BootstrapSetup

# The JSON report's schema; Interfaces.md says what changes it.
REPORT_SCHEMA = 1


def main():
    parser = argparse.ArgumentParser(
        prog="dev-bootstrap",
        description="Plan, bootstrap and verify the declared runtime baseline.",
    )
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "action",
        nargs="?",
        default="plan",
        choices=("plan", "apply", "verify"),
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
    parser.add_argument("--json", action="store_true")
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
    args = parser.parse_args()
    if args.health and args.action != "verify":
        parser.error("--health requires verify")
    if args.save_selection and not (args.only or args.all):
        parser.error("--save-selection requires --only or --all")
    os.umask(0o077)
    # The setup in use, so an interruption can name its stage.
    setups = []
    try:
        with termination():
            return run(args, setups)
    except (KeyboardInterrupt, Interrupted) as error:
        signum = getattr(error, "signum", signal.SIGINT)
        stage = ""
        if args.action == "apply" and setups:
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
    """Execute the parsed command; expected failures exit 2."""
    try:
        manifest = load_manifest(args.manifest)
        only, origin = choose(args, manifest)
        context = Bootstrap(manifest, only, accepted=args.accept)
        if origin["source"] == "file" and not args.json:
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
        setup = None
        if (
            not args.runtimes_only
            and context.data.get("setup")
            and context.backend == "native"
        ):
            setup = BootstrapSetup(context)
            setups.append(setup)
        result = execute(context, setup, args)
        result["selection"] = origin
        report(result, args.json)
        return (
            0
            if args.action == "plan"
            # External selections belong to the host, not to a native manager.
            or all(
                row["state"] in ("ok", "external")
                for row in result["runtimes"]
            )
            else 1
        )
    except (
        BootstrapError,
        OSError,
        ValueError,
        tarfile.TarError,
    ) as error:
        print(f"dev-bootstrap: {error}", file=sys.stderr)
        return 2


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


def execute(context, setup, args):
    """Run the requested action and build the stable JSON result."""
    rows = context.plan()
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
    if selections is not None:
        # Manager-owned selections are reported; they never fail apply.
        result["selections"] = selections
    if args.health:
        result["verification"] = "health"
    return result


def report(result, as_json):
    if as_json:
        print(json.dumps(result, indent=2))
        return
    for row in result["runtimes"]:
        print(
            f"{row['state']:8} {row['language']:6} {row['version']:8} {row['path']}"
        )
        if row.get("reason"):
            print(f"         {row['reason']}")
        if row.get("remediation"):
            print(f"         remedy: {row['remediation']}")
    for row in result.get("selections", []):
        if row["state"] != "ok":
            print(
                f"{row['state']:8} {row['language']:6} "
                f"{'selected':8} {row['path'] or '-'}"
            )
            print(f"         {row['reason']}")
            if row.get("remediation"):
                print(f"         remedy: {row['remediation']}")
