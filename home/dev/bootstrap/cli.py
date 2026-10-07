"""Command-line parsing, orchestration and stable JSON/text reporting."""

import argparse
import os
import sys
import json
import tarfile
from pathlib import Path
from engine import Bootstrap, MANAGERS
from manifest import load_manifest
from support import BootstrapError
from setup import BootstrapSetup


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
    parser.add_argument("--only", choices=tuple(MANAGERS), action="append")
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
        recovery = Bootstrap(load_manifest(args.manifest), args.only)
        rows = recovery.plan()
        setup = None
        selections = None
        if (
            not args.runtimes_only
            and recovery.data.get("setup")
            and recovery.data["backend"] == "native"
        ):
            setup = BootstrapSetup(recovery)
        if args.action == "apply":
            if setup:
                selections = setup.apply()
            else:
                recovery.apply(rows)
            rows = recovery.plan()
        if args.health:
            if setup:
                rows = setup.selections()
            elif recovery.data["backend"] == "native":
                raise BootstrapError(
                    "Health verification requires the generated setup policy"
                )
        if args.action in ("apply", "verify"):
            for row in rows:
                if row["state"] == "present":
                    try:
                        if args.health or (setup and args.action == "apply"):
                            row["actualVersion"] = (
                                recovery.verify_healthy_runtime(row)
                            )
                        else:
                            recovery.verify_runtime(row)
                        if row[
                            "language"
                        ] == "ocaml" and recovery.ocaml.read_pending(row):
                            raise BootstrapError(
                                "Repository handover is still pending"
                            )
                        row["state"] = "ok"
                    except BootstrapError as error:
                        row.update(state="conflict", reason=str(error))
        result = {
            "action": args.action,
            "platform": recovery.data["platform"],
            "backend": recovery.data["backend"],
            "defaults": recovery.data["defaults"],
            "observed": recovery.observed_state(),
            "runtimes": rows,
        }
        if setup:
            result["setup"] = setup.plan()
        if selections is not None:
            # Manager-owned selections are reported; they never fail apply.
            result["selections"] = selections
        if args.health:
            result["verification"] = "health"
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            for row in rows:
                print(
                    f"{row['state']:8} {row['language']:6} "
                    f"{row['version']:8} {row['path']}"
                )
                if row.get("reason"):
                    print(f"         {row['reason']}")
            for row in selections or []:
                if row["state"] != "ok":
                    print(
                        f"{row['state']:8} {row['language']:6} "
                        f"{'selected':8} {row['path'] or '-'}"
                    )
                    print(f"         {row['reason']}")
        return (
            0
            if args.action == "plan"
            # External selections belong to the host, not to a native manager.
            or all(row["state"] in ("ok", "external") for row in rows)
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
