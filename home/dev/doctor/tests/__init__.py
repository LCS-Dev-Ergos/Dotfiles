"""Tests of dev-doctor and toolchain.

Every test works on a ``support.Machine``: a temporary home whose PATH holds
only the fake programs the test writes, so nothing reads the real home or
starts a real compiler. Run them from the directory above with
``python3 -m unittest discover -s tests -t .``.

The package is imported first: it loads the shared terminal style, which the
tests import by its own name, whatever order they import in.
"""

import importlib

importlib.import_module("core")
