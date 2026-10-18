"""Tests of security-scan.

Every test works in a temporary folder with files it writes itself; ClamAV
is a fake ``clamscan`` on a private PATH, and YARA and pikepdf are the real
libraries. Run them from the directory above with
``python3 -m unittest discover -s tests -t .``.

The package is imported first: it loads the shared terminal style, which the
tests import by its own name, whatever order they import in.
"""

import importlib

importlib.import_module("core")
