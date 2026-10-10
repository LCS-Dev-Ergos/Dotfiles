"""Every pinned ecosystem and how its upstream is read, in bootstrap order.

Most entries are a `Track`: the declaration, the listing and the line depth
are the whole difference between them. The JVM, the .NET SDK, release assets
and installer scripts need logic of their own.
"""

from . import dotnet, installers, jvm, sources
from .assets import ReleaseAssets, coursier_version, miniforge_version
from .tracks import Resolver, Track, combine


def toolchain(name: str, releases: sources.Listing, depth: int, **options):
    """A native toolchain pinned at nativeToolchains.<name>.version."""
    return Track(
        ecosystem=name,
        declaration=f"nativeToolchains.{name}.version",
        releases=releases,
        depth=depth,
        **options,
    )


def haskell(tool: str, key: str, depth: int, **options) -> Track:
    return Track(
        ecosystem="haskell",
        label=f"haskell {tool.lower()}",
        declaration=f"nativeToolchains.haskell.{key}",
        releases=sources.ghcup(tool, recommended=tool != "GHC"),
        installable=sources.ghcup_bindists(tool),
        depth=depth,
        **options,
    )


RESOLVERS: dict[str, Resolver] = {
    "node": Track(
        ecosystem="node",
        declaration="node.versions",
        releases=sources.nodejs,
        depth=1,
    ),
    "python": Track(
        ecosystem="python",
        declaration="python.version",
        releases=sources.python_org,
        installable=sources.pyenv_definition,
        depth=2,
    ),
    "ocaml": Track(
        ecosystem="ocaml",
        declaration="ocaml.versions",
        releases=sources.opam_compilers,
        depth=2,
    ),
    "rust": toolchain("rust", sources.rust_stable, 1, movable_lines=False),
    "haskell": combine(
        haskell("GHC", "version", 2),
        haskell("Cabal", "cabal", 1, default=False),
        haskell("HLS", "hls", 1, default=False),
    ),
    "lean": toolchain(
        "lean",
        sources.github_assets(
            "leanprover/lean4",
            "lean-{version}-darwin_aarch64.tar.zst",
            "lean-{version}-linux.tar.zst",
        ),
        1,
    ),
    "ruby": toolchain(
        "ruby",
        sources.ruby_lang,
        2,
        installable=sources.ruby_build_definition,
    ),
    "jvm": jvm.resolve,
    **{
        name: toolchain(name, sources.sdkman(name), 1)
        for name in ("kotlin", "maven", "gradle")
    },
    "scala": toolchain(
        "scala",
        sources.github_assets(
            "scala/scala3",
            "scala3-{version}-aarch64-apple-darwin.tar.gz",
            "scala3-{version}-x86_64-pc-linux.tar.gz",
        ),
        1,
    ),
    "julia": toolchain("julia", sources.julia_versions, 2),
    "dotnet": dotnet.resolve,
    "conda": ReleaseAssets(
        ecosystem="conda",
        label="conda",
        repository="conda-forge/miniforge",
        installer="conda",
        assets={
            "aarch64-darwin": "Miniforge3-{tag}-MacOSX-arm64.sh",
            "x86_64-linux": "Miniforge3-{tag}-Linux-x86_64.sh",
        },
        version=miniforge_version,
        # The tag names both the download directory and the assets.
        moved="{tag}",
        depth=0,
        declaration="nativeToolchains.conda.version",
    ),
    # The pinned native `cs` launcher that installs Scala.
    "coursier": ReleaseAssets(
        ecosystem="coursier",
        label="coursier launcher",
        repository="coursier/coursier",
        installer="scala",
        assets={
            "aarch64-darwin": "cs-aarch64-apple-darwin.gz",
            "x86_64-linux": "cs-x86_64-pc-linux.gz",
        },
        version=coursier_version,
        moved="/download/{tag}/",
        depth=1,
    ),
    "installers": installers.resolve,
}
ECOSYSTEMS = tuple(RESOLVERS)
# Resolvers that read GHCup's YAML metadata, which needs PyYAML.
NEEDS_YAML = frozenset({"haskell"})
