"""
Test support module.

Ensures the package root is on `sys.path` so that test files can import
modules directly (e.g. `from vscode_models import ...`) without requiring
a formal package install or `PYTHONPATH` gymnastics.
"""

from __future__ import annotations

import sys
from pathlib import Path

MODULE_ROOT = Path(__file__).resolve().parents[1]

if str(MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(MODULE_ROOT))
