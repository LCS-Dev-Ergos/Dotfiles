"""Installers pinned as GitHub release assets, which move with their release.

An asset's hash and size come from downloading it when the move is applied,
and GitHub's published digest, when present, must agree with the bytes.
"""

import functools
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass

from .. import declarations
from ..declarations import PLATFORMS, baseline_edit
from ..model import Edit, Finding, SourceError, classify
from ..upstream import Source, assets, github_releases
from ..versions import stable


def release_tag(url: str) -> str:
    match = re.search(r"/releases/download/([^/]+)/", url)
    if not match:
        raise SourceError(f"not a GitHub release asset: {url}")
    return match.group(1)


def installer_scopes(name: str) -> tuple[str, ...]:
    return tuple(
        f"bootstrap.{platform}.installers.{name}" for platform in PLATFORMS
    )


def miniforge_version(tag: str) -> str | None:
    """Miniforge3 release X-N ships conda X."""
    version, _, build = tag.partition("-")
    return version if stable(version) and build.isdigit() else None


def coursier_version(tag: str) -> str | None:
    version = tag.removeprefix("v")
    return version if stable(version) else None


@dataclass(frozen=True, kw_only=True)
class ReleaseAssets:
    """One installer per platform, all assets of the same GitHub release.

    `assets` maps each platform to its asset name over `{tag}`. `moved` is
    the text that names the release in the declarations, over `{tag}`.
    With a `declaration`, the release's version is also a baseline pin;
    otherwise the pinned version is read from the release tag.
    """

    ecosystem: str
    label: str
    repository: str
    installer: str
    assets: Mapping[str, str]
    version: Callable[[str], str | None]
    moved: str
    depth: int
    declaration: str | None = None

    def __call__(
        self, upstream: Source, baseline: dict, managers: dict
    ) -> list[Finding]:
        installers = {
            platform: managers["bootstrap"][platform]["installers"][
                self.installer
            ]
            for platform in PLATFORMS
        }
        tag = release_tag(installers[PLATFORMS[0]]["url"])
        if self.declaration:
            pinned = declarations.lookup(baseline, self.declaration)
        else:
            pinned = self.version(tag) or tag
        releases = {}
        for release in github_releases(upstream, self.repository):
            version = self.version(release["tag_name"])
            names = {
                name.format(tag=release["tag_name"])
                for name in self.assets.values()
            }
            if version and names <= set(assets(release)):
                releases.setdefault(version, release)
        edits = functools.partial(
            self.edits, upstream, installers, pinned, tag, releases
        )
        return classify(
            self.ecosystem,
            self.label,
            pinned,
            set(releases),
            self.depth,
            edits=edits,
            line_edits=edits if self.depth else None,
        )

    def edits(
        self, upstream, installers, pinned, tag, releases, version
    ) -> list[Edit]:
        release = releases[version]
        new_tag = release["tag_name"]
        moves = [
            Edit(
                declarations.MANAGERS,
                self.moved.format(tag=tag),
                self.moved.format(tag=new_tag),
                installer_scopes(self.installer),
            )
        ]
        if self.declaration:
            moves.insert(
                0,
                baseline_edit(
                    pinned,
                    version,
                    self.declaration,
                    f"defaults.{self.ecosystem}",
                ),
            )
        return moves + self.asset_edits(upstream, installers, release)

    def asset_edits(self, upstream, installers, release) -> list[Edit]:
        """The new hash and size of each platform's asset."""
        published = assets(release)
        edits = []
        for platform, template in self.assets.items():
            installer = installers[platform]
            asset = published[template.format(tag=release["tag_name"])]
            digest = upstream.download(
                asset["browser_download_url"], asset["size"]
            )
            if asset.get("digest") not in (None, f"sha256:{digest}"):
                raise SourceError(
                    f"{asset['name']}: GitHub's digest disagrees with the bytes"
                )
            scope = (f"bootstrap.{platform}.installers.{self.installer}",)
            edits += [
                Edit(
                    declarations.MANAGERS,
                    f'"{installer["sha256"]}"',
                    f'"{digest}"',
                    scope,
                ),
                Edit(
                    declarations.MANAGERS,
                    f"size = {installer['size']};",
                    f"size = {asset['size']};",
                    scope,
                ),
            ]
        return edits
