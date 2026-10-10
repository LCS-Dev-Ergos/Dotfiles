"""Upstream release listings and the probes that say a manager can install one.

A listing returns the releases an upstream publishes for both supported
platforms; filtering to stable releases happens in the tracks. A probe
factory reads what it needs once and returns a check: None when the native
manager can install a release, otherwise why not.
"""

import re
from collections.abc import Callable

from ..model import SourceError
from ..upstream import Source, assets, github_releases

Listing = Callable[[Source], set[str]]
Check = Callable[[str], str | None]
Probe = Callable[[Source], Check]

NODE_INDEX = "https://nodejs.org/dist/index.json"
PYTHON_RELEASES = (
    "https://www.python.org/api/v2/downloads/release/"
    "?is_published=true&pre_release=false"
)
RUST_CHANNEL = "https://static.rust-lang.org/dist/channel-rust-stable.toml"
RUBY_INDEX = "https://cache.ruby-lang.org/pub/ruby/index.txt"
JULIA_VERSIONS = "https://julialang-s3.julialang.org/bin/versions.json"
# GHCup's default metadata channel, the one a fresh installation reads.
GHCUP_METADATA = (
    "https://raw.githubusercontent.com/haskell/ghcup-metadata/master/"
    "ghcup-0.1.0.yaml"
)
SDKMAN_LISTS = "https://api.sdkman.io/2/candidates"
SDKMAN_BROKER = "https://broker.sdkman.io/download"
SDKMAN_PLATFORMS = ("darwinarm64", "linuxx64")
ADOPTIUM = "https://api.adoptium.net/v3"


def nodejs(upstream: Source) -> set[str]:
    return {
        entry["version"].lstrip("v")
        for entry in upstream.json(NODE_INDEX)
        if {"osx-arm64-tar", "linux-x64"} <= set(entry.get("files", []))
    }


def python_org(upstream: Source) -> set[str]:
    return {
        release["name"].removeprefix("Python ")
        for release in upstream.json(PYTHON_RELEASES)
        if release["name"].startswith("Python 3.")
    }


def opam_compilers(upstream: Source) -> set[str]:
    listing = upstream.github(
        "repos/ocaml/opam-repository/contents/packages/ocaml-base-compiler"
    )
    return {
        entry["name"].removeprefix("ocaml-base-compiler.")
        for entry in listing
        if entry["name"].startswith("ocaml-base-compiler.")
    }


def rust_stable(upstream: Source) -> set[str]:
    manifest = upstream.text(RUST_CHANNEL)
    match = re.search(
        r'^\[pkg\.rust\]\nversion = "([0-9.]+) ', manifest, re.MULTILINE
    )
    if not match:
        raise SourceError("Rust's stable channel names no rust release")
    return {match.group(1)}


def ruby_lang(upstream: Source) -> set[str]:
    return {
        line.split("\t")[0].removeprefix("ruby-")
        for line in upstream.text(RUBY_INDEX).splitlines()
        if line.startswith("ruby-")
    }


def julia_versions(upstream: Source) -> set[str]:
    return {
        version
        for version, entry in upstream.json(JULIA_VERSIONS).items()
        if entry.get("stable")
        and {"aarch64-apple-darwin14", "x86_64-linux-gnu"}
        <= {f.get("triplet") for f in entry.get("files", [])}
    }


def sdkman(candidate: str) -> Listing:
    """Versions SDKMAN lists for the candidate on both platforms."""

    def listing(upstream: Source) -> set[str]:
        lists = [
            set(
                upstream.text(
                    f"{SDKMAN_LISTS}/{candidate}/{platform}/versions/all"
                ).split(",")
            )
            for platform in SDKMAN_PLATFORMS
        ]
        return {version.strip() for version in set.intersection(*lists)}

    return listing


def github_assets(
    repository: str, *names: str, tag_prefix: str = "v"
) -> Listing:
    """Releases whose GitHub release carries every named asset.

    `names` are templates over `{version}`, one per supported platform.
    """

    def listing(upstream: Source) -> set[str]:
        available = set()
        for release in github_releases(upstream, repository):
            version = release["tag_name"].removeprefix(tag_prefix)
            published = set(assets(release))
            if {name.format(version=version) for name in names} <= published:
                available.add(version)
        return available

    return listing


def build_definition(repository: str, directory: str, manager: str) -> Probe:
    """A source build needs a definition in the manager's latest release."""

    def probe(upstream: Source) -> Check:
        tag = upstream.github(f"repos/{repository}/releases/latest")[
            "tag_name"
        ]

        def check(version: str) -> str | None:
            url = (
                f"https://raw.githubusercontent.com/{repository}/{tag}/"
                f"{directory}/{version}"
            )
            if upstream.exists(url):
                return None
            return f"{manager} {tag} has no definition"

        return check

    return probe


pyenv_definition = build_definition(
    "pyenv/pyenv", "plugins/python-build/share/python-build", "pyenv"
)
ruby_build_definition = build_definition(
    "rbenv/ruby-build", "share/ruby-build", "ruby-build"
)


def ghcup_versions(upstream: Source, tool: str) -> dict[str, dict]:
    tools = upstream.yaml(GHCUP_METADATA)["ghcupDownloads"]
    return dict(tools[tool]["toolVersions"])


def ghcup(tool: str, *, recommended: bool = False) -> Listing:
    """GHCup's releases of a tool, or only those it recommends.

    Cabal and HLS follow the channel's recommendation, which for HLS is a
    release with a server for the recommended compilers.
    """

    def listing(upstream: Source) -> set[str]:
        return {
            version
            for version, entry in ghcup_versions(upstream, tool).items()
            if not recommended or "Recommended" in entry.get("viTags", [])
        }

    return listing


def ghcup_bindists(tool: str) -> Probe:
    """GHCup installs a release only where it has a bindist for it."""

    def probe(upstream: Source) -> Check:
        versions = ghcup_versions(upstream, tool)

        def check(version: str) -> str | None:
            architectures = versions[version].get("viArch", {})
            darwin = "Darwin" in architectures.get("A_ARM64", {})
            linux = any(
                key.startswith("Linux")
                for key in architectures.get("A_64", {})
            )
            return (
                None if darwin and linux else "no bindist for both platforms"
            )

        return check

    return probe
