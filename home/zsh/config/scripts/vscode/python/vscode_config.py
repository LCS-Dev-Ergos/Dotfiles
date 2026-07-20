# ============================================================================ #
"""
Configuration helpers for VS Code extension roots and profile discovery.

Centralises the platform-aware paths used by the sync backend. On macOS
the user-data lives under `~/Library/Application Support/` while on Linux
it lives under `~/.config/`. The active user/profile roots are selected
once per HOME so shell and Python workflows can agree on the same scope.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

from vscode_fs import canonicalize_path
from vscode_models import VscodeEdition

DEFAULT_EXTENSION_EXCLUDE_PATTERNS = (
    "anthropic.claude-code-*",
    "github.copilot-*",
)


@dataclass(frozen=True, slots=True)
class VscodePathsConfig:
    """Describe the filesystem roots used by the VS Code sync backend."""

    home: Path
    stable_extensions_dir: Path
    insiders_extensions_dir: Path
    stable_user_dir: Path
    insiders_user_dir: Path
    stable_profile_roots: tuple[Path, ...]
    insiders_profile_roots: tuple[Path, ...]

    @staticmethod
    def _select_user_dirs(home_path: Path) -> tuple[Path, Path]:
        """Select the active Stable and Insiders user-data roots for this platform."""

        mac_stable = home_path / "Library/Application Support/Code/User"
        mac_insiders = home_path / "Library/Application Support/Code - Insiders/User"
        linux_stable = home_path / ".config/Code/User"
        linux_insiders = home_path / ".config/Code - Insiders/User"

        if sys.platform == "darwin":
            return (
                canonicalize_path(mac_stable),
                canonicalize_path(mac_insiders),
            )
        if sys.platform.startswith("linux"):
            return (
                canonicalize_path(linux_stable),
                canonicalize_path(linux_insiders),
            )

        if mac_stable.exists() or mac_insiders.exists():
            return (
                canonicalize_path(mac_stable),
                canonicalize_path(mac_insiders),
            )
        return (
            canonicalize_path(linux_stable),
            canonicalize_path(linux_insiders),
        )

    @classmethod
    def from_home(cls, home: str | Path | None = None) -> "VscodePathsConfig":
        """Build a configuration object from a HOME directory."""

        home_path = canonicalize_path(home or Path.home())
        stable_user_dir, insiders_user_dir = cls._select_user_dirs(home_path)

        return cls(
            home=home_path,
            stable_extensions_dir=canonicalize_path(home_path / ".vscode/extensions"),
            insiders_extensions_dir=canonicalize_path(home_path / ".vscode-insiders/extensions"),
            stable_user_dir=stable_user_dir,
            insiders_user_dir=insiders_user_dir,
            stable_profile_roots=(canonicalize_path(stable_user_dir / "profiles"),),
            insiders_profile_roots=(canonicalize_path(insiders_user_dir / "profiles"),),
        )

    def scope_for_extensions_dir(self, extensions_dir: str | Path) -> VscodeEdition:
        """Return the VS Code edition associated with an extensions directory."""

        canonical_extensions_dir = canonicalize_path(extensions_dir)
        if canonical_extensions_dir == self.stable_extensions_dir:
            return VscodeEdition.STABLE
        if canonical_extensions_dir == self.insiders_extensions_dir:
            return VscodeEdition.INSIDERS
        return VscodeEdition.LOCAL

    def profile_roots_for_extensions_dir(self, extensions_dir: str | Path) -> tuple[Path, ...]:
        """Return the profile roots relevant to the given extensions directory."""

        scope = self.scope_for_extensions_dir(extensions_dir)
        if scope == VscodeEdition.STABLE:
            return self.stable_profile_roots
        if scope == VscodeEdition.INSIDERS:
            return self.insiders_profile_roots
        return ()
