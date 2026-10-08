"""Command-line parsing, orchestration and stable JSON/text reporting."""

import argparse
import json
import os
import sys
import tarfile
from pathlib import Path

from .adapters import ADAPTERS
from .engine import Bootstrap
from .errors import BootstrapError
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
    for row in result.get("selections", []):
        if row["state"] != "ok":
            print(
                f"{row['state']:8} {row['language']:6} "
                f"{'selected':8} {row['path'] or '-'}"
            )
            print(f"         {row['reason']}")
