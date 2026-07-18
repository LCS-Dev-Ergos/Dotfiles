# ============================================================================ #
"""
Backup directory helpers for the VS Code sync backend.

This module centralizes retention for timestamped backup directories stored
under `~/.local/share/vscode-sync-backups`. The retention policy keeps the
most recent backup directories per backup subtype, so frequent subtypes (for
example sync-item backups) cannot evict rarer ones such as cleanup quarantine
data.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import re
import shutil
from pathlib import Path

from vscode_fs import canonicalize_path, is_path_location_within_directory

DEFAULT_BACKUP_RETENTION_LIMIT = 5

_BACKUP_NAME_PREFIX_RE = re.compile(r"^[0-9]{8}_[0-9]{6}(?:_[0-9]+)*_")


def _backup_subtype(name: str) -> str:
    """Return the retention group for one backup directory name."""

    stripped = _BACKUP_NAME_PREFIX_RE.sub("", name)
    return stripped or name


def default_backup_root(home: str | Path) -> Path:
    """Return the canonical shared backup root for a HOME directory."""

    return canonicalize_path(
        Path(home).expanduser() / ".local/share/vscode-sync-backups"
    )


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
            if entry.is_dir()
            and is_path_location_within_directory(entry, canonical_backup_root)
        ),
        key=lambda entry: entry.name,
    )

    grouped: dict[str, list[Path]] = {}
    for entry in entries:
        grouped.setdefault(_backup_subtype(entry.name), []).append(entry)

    removed_paths: list[Path] = []
    for group_entries in grouped.values():
        for entry in group_entries[:-keep_limit]:
            if entry.is_symlink() or not entry.is_dir():
                entry.unlink()
            else:
                shutil.rmtree(entry)
            removed_paths.append(entry)
    return tuple(removed_paths)
