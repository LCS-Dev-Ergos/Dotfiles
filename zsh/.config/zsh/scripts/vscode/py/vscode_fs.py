# ============================================================================ #
"""
Low-level filesystem helpers for the VS Code sync Python backend.

All path-aware helpers in the codebase delegate to: `canonicalize_path`
for consistent, strict=False resolution so that paths referring to
not-yet-created directories are handled uniformly.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

from pathlib import Path


def canonicalize_path(path: str | Path) -> Path:
    """Return a normalized absolute path without requiring the target to exist."""

    return Path(path).expanduser().resolve(strict=False)


def canonicalize_path_location(path: str | Path) -> Path:
    """Return a canonical location path without resolving the final path component."""

    candidate = Path(path).expanduser()
    if candidate == candidate.parent:
        return canonicalize_path(candidate)
    return canonicalize_path(candidate.parent) / candidate.name


def is_within_directory(path: str | Path, root: str | Path) -> bool:
    """Return `True` when `path` is equal to or contained within `root`."""

    canonical_path = canonicalize_path(path)
    canonical_root = canonicalize_path(root)
    return canonical_path == canonical_root or canonical_root in canonical_path.parents


def is_path_location_within_directory(path: str | Path, root: str | Path) -> bool:
    """Return `True` when the path location is equal to or contained within `root`."""

    canonical_path = canonicalize_path_location(path)
    canonical_root = canonicalize_path(root)
    return canonical_path == canonical_root or canonical_root in canonical_path.parents


def safe_mtime(path: Path, *, follow_symlinks: bool = True) -> int | None:
    """Return the integer mtime for `path` or `None` when it cannot be read."""

    try:
        return int(path.stat(follow_symlinks=follow_symlinks).st_mtime)
    except OSError:
        return None
