"""Tests of blog.

Every test works in a temporary folder with a vault, a site in a Git
repository and a bare remote it builds itself; Hugo is a fake on a private
PATH and Git is the real one. Run them from the directory above with
``python3 -m unittest discover -s tests -t .``.

The package is imported first: it loads the shared terminal style, which the
tests import by its own name, whatever order they import in.
"""

import importlib

importlib.import_module("core")
