#!/usr/bin/env python3
# ============================================================================ #
# +++++++++++++++++++++++++ RUNTIME BASELINE UPDATER +++++++++++++++++++++++++ #
# ============================================================================ #
"""Report or advance the exact upstream releases the runtime baseline pins.

Usage:
  scripts/updates/update-runtime-baseline.py --check [--markdown] [ecosystem...]
  scripts/updates/update-runtime-baseline.py --apply [--line ECOSYSTEM]... [ecosystem...]
  scripts/updates/update-runtime-baseline.py --accept-installer NAME...

The implementation is the update_runtime_baseline package beside this file;
its docstring describes the finding classes and the rewrite rules.
GITHUB_TOKEN, when set, is sent to api.github.com only (rate limits).

Exit status: 0 nothing actionable or applied, 1 actionable findings
(--check), 2 usage, environment or source error.
"""

import sys

# A checkout is not a place for bytecode caches.
sys.dont_write_bytecode = True

from update_runtime_baseline.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
