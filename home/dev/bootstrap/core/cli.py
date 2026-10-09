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
from .engine import Bootstrap
from .errors import BootstrapError, Interrupted
from .manifest import load_manifest
from .setup import BootstrapSetup


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
    parser.add_argument("--only", choices=tuple(ADAPTERS), action="append")
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
            f"dev-bootstrap: interrupted{stage}; the lock is released. Run "
            "plan to find any incomplete prefix, then apply again.",
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
        context = Bootstrap(
            load_manifest(args.manifest), args.only, accepted=args.accept
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
