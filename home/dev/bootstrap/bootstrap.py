#!/usr/bin/env python3
"""Plan, bootstrap and verify the declared workstation runtime baseline."""

import sys
from pathlib import Path

# Named explicitly: the package runs this with -I, which, like -P and
# PYTHONSAFEPATH, leaves the script's own directory off the import path.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from core.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
