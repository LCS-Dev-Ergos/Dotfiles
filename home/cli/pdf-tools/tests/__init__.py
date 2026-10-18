"""Tests of pdf-tools.

Every test works in a temporary folder with PDFs it builds with pikepdf;
Ghostscript and ddjvu are fakes on a private PATH. Run them from the
directory above with ``python3 -m unittest discover -s tests -t .``.

The package is imported first: it loads the shared terminal style, which the
tests import by its own name, whatever order they import in.
"""

import importlib

importlib.import_module("core")
