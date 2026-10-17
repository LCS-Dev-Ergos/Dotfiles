"""Tests of vscode-sync.

Every test works in a temporary home built by ``support.Machine``; nothing
reads the real home directory or the real VS Code files. Run them from the
directory above with ``python3 -m unittest discover -s tests -t .``.

The package is imported first: it loads the shared terminal style, which the
tests import by its own name, whatever order they import in.
"""

import importlib

importlib.import_module("core")
