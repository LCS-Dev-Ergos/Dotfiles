#!/usr/bin/env python3
"""Share VS Code Stable's extensions and user files with VS Code Insiders.

The entry point of ``vscode-sync``; the implementation is the ``core``
package next to this file. The package directory is put on the import path
explicitly because the installed command runs this file with ``-I``, which,
like ``-P`` and PYTHONSAFEPATH, leaves the script's own directory off it. The
version check comes first so that an older Python reports the requirement
instead of a syntax error.
"""

import sys
from pathlib import Path

if sys.version_info < (3, 10):
    sys.exit("vscode-sync needs Python 3.10 or newer")

sys.path.insert(0, str(Path(__file__).resolve().parent))

from core.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
