# ============================================================================ #
"""
Backup directory helpers for the VS Code sync backend.

This module centralizes retention for timestamped backup directories stored
under `~/.local/share/vscode-sync-backups`. The retention policy keeps only the
most recent backup directories, regardless of backup subtype.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import shutil
from pathlib import Path

from vscode_fs import canonicalize_path, is_path_location_within_directory

DEFAULT_BACKUP_RETENTION_LIMIT = 5


def default_backup_root(home: str | Path) -> Path:
    """Return the canonical shared backup root for a HOME directory."""

    return canonicalize_path(Path(home).expanduser() / ".local/share/vscode-sync-backups")


def prune_backup_directories(
    backup_root: str | Path,
    *,
    keep_count: int = DEFAULT_BACKUP_RETENTION_LIMIT,
) -> tuple[Path, ...]:
    """Prune old backup directories and return the removed paths."""

    canonical_backup_root = canonicalize_path(backup_root)
    if not canonical_backup_root.exists():
        return ()

    keep_limit = max(1, int(keep_count))
    entries = sorted(
        (
            entry
            for entry in canonical_backup_root.iterdir()
            if entry.is_dir() and is_path_location_within_directory(entry, canonical_backup_root)
        ),
        key=lambda entry: entry.name,
    )
    if len(entries) <= keep_limit:
        return ()

    removed_paths: list[Path] = []
    for entry in entries[:-keep_limit]:
        if entry.is_symlink() or not entry.is_dir():
            entry.unlink()
        else:
            shutil.rmtree(entry)
        removed_paths.append(entry)
    return tuple(removed_paths)
