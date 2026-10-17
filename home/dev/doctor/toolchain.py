#!/usr/bin/env python3
"""Explain and select the C/C++ compilers of this shell: ``toolchain``.

The implementation is the ``core`` package next to this file, put on the
import path explicitly because the installed command runs this file with
``-I``. The version check comes first so that an older Python reports the
requirement instead of a syntax error.
"""

import sys
from pathlib import Path

if sys.version_info < (3, 12):
    sys.exit("toolchain needs Python 3.12 or newer")

sys.path.insert(0, str(Path(__file__).resolve().parent))

from core.cli import toolchain_main

if __name__ == "__main__":
    raise SystemExit(toolchain_main())
