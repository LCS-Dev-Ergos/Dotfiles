# ============================================================================ #
"""
Configuration helpers for VS Code extension roots and profile discovery.

Centralises the platform-agnostic paths used by the sync backend.  On macOS
the user-data lives under `~/Library/Application Support/` while on Linux
it lives under `~/.config/`.  Both candidates are stored so the backend
can detect which one is active at runtime.

Author: XtremeXSPC
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

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
    stable_profile_roots: tuple[Path, ...]
    insiders_profile_roots: tuple[Path, ...]

    @classmethod
    def from_home(cls, home: str | Path | None = None) -> "VscodePathsConfig":
        """Build a configuration object from a HOME directory."""

        home_path = canonicalize_path(home or Path.home())

        return cls(
            home=home_path,
            stable_extensions_dir=canonicalize_path(home_path / ".vscode/extensions"),
            insiders_extensions_dir=canonicalize_path(home_path / ".vscode-insiders/extensions"),
            stable_profile_roots=(
                canonicalize_path(home_path / "Library/Application Support/Code/User/profiles"),
                canonicalize_path(home_path / ".config/Code/User/profiles"),
            ),
            insiders_profile_roots=(
                canonicalize_path(
                    home_path / "Library/Application Support/Code - Insiders/User/profiles"
                ),
                canonicalize_path(home_path / ".config/Code - Insiders/User/profiles"),
            ),
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
