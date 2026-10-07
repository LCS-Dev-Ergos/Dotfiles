#!/usr/bin/env python3
"""Discover fixture tests; package checks also exercise CLI and shell adapters."""

import argparse
import os
import subprocess
import sys
import unittest
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("source", "package"))
    parser.add_argument(
        "--category", choices=("unit", "integration", "bootstrap")
    )
    parser.add_argument(
        "--manifest", default=os.environ.get("DEVRESTORE_MANIFEST")
    )
    args = parser.parse_args()
    if args.phase == "package" and not args.manifest:
        parser.error(
            "package checks require --manifest or DEVRESTORE_MANIFEST"
        )
    if args.manifest:
        os.environ["DEVRESTORE_MANIFEST"] = str(Path(args.manifest).resolve())
    elif args.phase == "source":
        # Source checks evaluate tests/manifest.nix (see tests/declaration.py).
        os.environ.pop("DEVRESTORE_MANIFEST", None)

    directory = Path(__file__).resolve().parent
    categories = (
        (args.category,)
        if args.category
        else ("unit", "integration", "bootstrap")
    )
    loader = unittest.TestLoader()
    suite = unittest.TestSuite(
        loader.discover(
            str(directory / category),
            pattern="test_*.py",
            top_level_dir=str(directory.parent),
        )
        for category in categories
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        return 1
    if args.phase == "package":
        environment = dict(os.environ, DEVRESTORE_PYTHON=sys.executable)
        shell = os.environ.get("DEV_BOOTSTRAP_TEST_ZSH", "zsh")
        scripts = {
            "integration": "test-shell.zsh",
            "bootstrap": "test-recovery.zsh",
        }
        for category in categories:
            if category in scripts:
                process = subprocess.run(
                    [shell, str(directory / category / scripts[category])],
                    env=environment,
                    check=False,
                )
                if process.returncode:
                    return process.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
