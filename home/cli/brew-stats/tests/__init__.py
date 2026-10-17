"""Tests of brew-stats.

Every test works with a fake ``brew`` over a temporary Cellar and Caskroom;
sizes come from the real ``du``. Run them from the directory above with
``python3 -m unittest discover -s tests -t .``.

The package is imported first: it loads the shared terminal style, which the
tests import by its own name, whatever order they import in.
"""

import importlib

importlib.import_module("core")
