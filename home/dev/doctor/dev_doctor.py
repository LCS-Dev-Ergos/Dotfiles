#!/usr/bin/env python3
"""Report the health of the development environment: ``dev-doctor``.

The implementation is the ``core`` package next to this file. The package
directory is put on the import path explicitly because the installed
command runs this file with ``-I``, which leaves the script's own directory
off it. The version check comes first so that an older Python reports the
requirement instead of a syntax error.
"""

import sys
from pathlib import Path

if sys.version_info < (3, 12):
    sys.exit("dev-doctor needs Python 3.12 or newer")

sys.path.insert(0, str(Path(__file__).resolve().parent))

from core.cli import doctor_main

if __name__ == "__main__":
    raise SystemExit(doctor_main())
