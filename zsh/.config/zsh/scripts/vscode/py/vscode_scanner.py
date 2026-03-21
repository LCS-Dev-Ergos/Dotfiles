# ============================================================================ #
"""
Filesystem scanners for VS Code extension install directories.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import os
import re
from pathlib import Path

from vscode_fs import canonicalize_path, safe_mtime
from vscode_models import ExtensionInstall, ParsedExtensionFolder, VscodeEdition

_VERSION_SUFFIX_RE = re.compile(r"^(.*)-([0-9][0-9A-Za-z._+-]*)$")
_PLATFORM_SUFFIX_RE = re.compile(
    r"^(.+)-(darwin|linux|win32|alpine)-(arm64|x64|ia32|armhf)$"
)


def parse_extension_folder_name(folder_name: str) -> ParsedExtensionFolder:
    """Parse a versioned VS Code extension folder name into structured fields."""
    core_name = folder_name
    version: str | None = None
    extension_id = folder_name

    version_match = _VERSION_SUFFIX_RE.match(folder_name)
    if version_match:
        core_name = version_match.group(1)
        version = version_match.group(2)
        extension_id = version_match.group(1)

        platform_match = _PLATFORM_SUFFIX_RE.match(version)
        if platform_match:
            version = platform_match.group(1)
            core_name = f"{core_name}-{platform_match.group(2)}-{platform_match.group(3)}"

    extension_platform_match = _PLATFORM_SUFFIX_RE.match(extension_id)
    if extension_platform_match:
        extension_id = extension_platform_match.group(1)

    return ParsedExtensionFolder(
        folder_name=folder_name,
        extension_id=extension_id,
        core_name=core_name,
        version=version,
    )


def _resolve_symlink_target(entry: Path, raw_target: str) -> Path:
    """Resolve a symlink target relative to the entry that owns the link."""
    target_path = Path(raw_target)
    if target_path.is_absolute():
        return canonicalize_path(target_path)
    return canonicalize_path(entry.parent / target_path)


def scan_extension_root(
    extensions_dir: str | Path,
    *,
    edition: VscodeEdition = VscodeEdition.LOCAL,
) -> list[ExtensionInstall]:
    """Scan an extension root and return normalized install metadata."""
    root = canonicalize_path(extensions_dir)
    if not root.exists() or not root.is_dir():
        return []

    installs: list[ExtensionInstall] = []
    for entry in sorted(root.iterdir(), key=lambda candidate: candidate.name):
        if not (entry.is_dir() or entry.is_symlink()):
            continue

        parsed = parse_extension_folder_name(entry.name)
        is_symlink = entry.is_symlink()
        raw_target: str | None = None
        resolved_target: Path | None = None
        target_exists = True

        if is_symlink:
            raw_target = os.readlink(entry)
            resolved_target = _resolve_symlink_target(entry, raw_target)
            target_exists = entry.exists()

        installs.append(
            ExtensionInstall(
                folder_name=parsed.folder_name,
                extension_id=parsed.extension_id,
                core_name=parsed.core_name,
                version=parsed.version,
                path=entry,
                edition=edition,
                is_symlink=is_symlink,
                symlink_target=raw_target,
                resolved_symlink_target=resolved_target,
                target_exists=target_exists,
                mtime=safe_mtime(entry, follow_symlinks=not is_symlink),
            )
        )

    return installs
