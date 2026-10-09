#!/usr/bin/env python3
# ============================================================================ #
# +++++++++++++++++++++++++ RUNTIME BASELINE UPDATER +++++++++++++++++++++++++ #
# ============================================================================ #
"""Report or advance the exact upstream releases the runtime baseline pins.

Usage:
  scripts/update-runtime-baseline.py --check [--markdown] [ecosystem...]
  scripts/update-runtime-baseline.py --apply [--line ECOSYSTEM]... [ecosystem...]
  scripts/update-runtime-baseline.py --accept-installer NAME...

Compares home/dev/runtime-baseline.nix and the release assets and installer
scripts in home/dev/native-managers.nix with their official upstreams.
Findings are classified:

  update   a newer patch release in the declared line, or the newest stable
           release of a tool without maintenance lines, installable on both
           platforms through its manager;
  pending  upstream has it, but the manager cannot install it yet (no
           python-build or ruby-build definition in the latest release, no
           SDKMAN candidate, a missing platform asset);
  line     a newer line (a new major, or minor where lines are maintained);
  drift    an installer script's bytes no longer match the pinned hash.

Only update and drift are actionable. --apply rewrites update findings, and
line findings of the ecosystems named with --line, by exact replacement;
every source resolves first, the rewritten files are re-evaluated, and both
files are restored if anything but the intended values changed. Drifted
installer bytes are saved for review; --accept-installer records the hash of
those reviewed bytes, and refuses if upstream changed again. The updater
never builds, stages, commits or switches.

GITHUB_TOKEN, when set, is sent to api.github.com only (rate limits).

Exit status: 0 nothing actionable or applied, 1 actionable findings
(--check), 2 usage, environment or source error.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "home/dev/runtime-baseline.nix"
MANAGERS = ROOT / "home/dev/native-managers.nix"
PLATFORMS = ("aarch64-darwin", "x86_64-linux")
ECOSYSTEMS = (
    "node",
    "python",
    "ocaml",
    "rust",
    "haskell",
    "lean",
    "ruby",
    "jvm",
    "kotlin",
    "maven",
    "gradle",
    "scala",
    "julia",
    "dotnet",
    "conda",
    "coursier",
    "installers",
)
# A new line of these needs more than a version: a second declared release
# (Node, OCaml) or a nixpkgs attribute named after the line (Python).
MANUAL_LINES = {
    "node": "edit node.versions and the nodejs_<major> runtimes by hand",
    "python": "the nixpkgs backend names python3<minor>; edit by hand",
    "ocaml": "edit ocaml.versions by hand",
}
# GHCup's default metadata channel, the one a fresh installation reads.
GHCUP_METADATA = (
    "https://raw.githubusercontent.com/haskell/ghcup-metadata/master/"
    "ghcup-0.1.0.yaml"
)
RESPONSE_LIMIT = 16 * 1024 * 1024
INSTALLER_LIMIT = 1024 * 1024
TIMEOUT = 60
STABLE = re.compile(r"[0-9]+(?:\.[0-9]+)*")


class SourceError(Exception):
    """An upstream could not be read or did not say what we expected."""


# Versions ---------------------------------------------------------------------


def numeric(version):
    return tuple(int(part) for part in re.findall(r"[0-9]+", version))


def stable(version):
    return STABLE.fullmatch(version) is not None


def same_line(version, pinned, depth):
    return numeric(version)[:depth] == numeric(pinned)[:depth]


def newer(candidates, pinned):
    """Candidates above the pinned release, newest first."""
    return sorted(
        {v for v in candidates if numeric(v) > numeric(pinned)},
        key=numeric,
        reverse=True,
    )


# Findings ---------------------------------------------------------------------


@dataclass
class Edit:
    """Replace every occurrence of `old` in `path` with `new`.

    `scopes` are the evaluated attribute paths allowed to change; after the
    rewrite, anything else that changed restores both files.
    """

    path: Path
    old: str
    new: str
    scopes: tuple


@dataclass
class Finding:
    """One pin compared with its upstream.

    `edits` builds the rewrite only when applied: for release assets it
    downloads them to record their hash.
    """

    ecosystem: str
    name: str
    pinned: str
    available: str = ""
    kind: str = "current"
    note: str = ""
    edits: object = None

    @property
    def actionable(self):
        return self.kind in ("update", "drift")


def baseline_edit(old, new, *scopes):
    return Edit(BASELINE, f'"{old}"', f'"{new}"', scopes)


def classify(
    ecosystem,
    name,
    pinned,
    candidates,
    depth,
    installable=None,
    edits=None,
    line_edits=None,
    lines=True,
):
    """Findings for one pinned release among an upstream's stable releases.

    `depth` is how many leading components name the line: 1 for a major,
    2 for major.minor, 0 when any newer release is an update. `installable`
    returns None when the manager can install a release, or why not; we try
    at most three releases, newest first. With several declared lines, only
    the newest reports `lines`; the others are covered by it.
    """
    found = []
    in_line = [
        v for v in newer(candidates, pinned) if same_line(v, pinned, depth)
    ]
    if in_line:
        blocked = []
        for version in in_line[:3]:
            reason = installable(version) if installable else None
            if reason is None:
                found.append(
                    Finding(
                        ecosystem,
                        name,
                        pinned,
                        version,
                        "update",
                        edits=edits and (lambda v=version: edits(v)),
                    )
                )
                break
            blocked.append(f"{version}: {reason}")
        if blocked:
            found.append(
                Finding(
                    ecosystem,
                    name,
                    pinned,
                    in_line[0],
                    "pending",
                    "; ".join(blocked),
                )
            )
    newer_lines = [
        v for v in newer(candidates, pinned) if not same_line(v, pinned, depth)
    ]
    if newer_lines and lines and depth:
        version = newer_lines[0]
        manual = MANUAL_LINES.get(ecosystem)
        reason = None
        if not manual and installable:
            reason = installable(version)
        found.append(
            Finding(
                ecosystem,
                name,
                pinned,
                version,
                "line",
                manual or (f"not installable yet: {reason}" if reason else ""),
                edits=line_edits
                and not manual
                and reason is None
                and (lambda v=version: line_edits(v)),
            )
        )
    return found or [Finding(ecosystem, name, pinned)]


# Upstream access --------------------------------------------------------------


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    """Follow redirects to HTTPS only."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise SourceError(f"{req.full_url} redirects to {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(HttpsRedirect)


class Upstream:
    """Bounded HTTPS reads, cached for the run."""

    def __init__(self, token=None):
        self.token = token
        self.cache = {}

    def request(self, url, *, method="GET", headers=None):
        if not url.startswith("https://"):
            raise SourceError(f"refusing a non-HTTPS source: {url}")
        request = urllib.request.Request(
            url,
            method=method,
            headers={"User-Agent": "dotfiles-update-runtime-baseline"}
            | (headers or {}),
        )
        # An unredirected header never follows a redirect to another host.
        if self.token and urllib.parse.urlsplit(url).hostname == (
            "api.github.com"
        ):
            request.add_unredirected_header(
                "Authorization", f"Bearer {self.token}"
            )
        return request

    def fetch(self, url, *, limit=RESPONSE_LIMIT, headers=None):
        key = (url, limit)
        if key not in self.cache:
            try:
                with OPENER.open(
                    self.request(url, headers=headers), timeout=TIMEOUT
                ) as response:
                    data = response.read(limit + 1)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                raise SourceError(f"{url}: {error}") from error
            if len(data) > limit:
                raise SourceError(f"{url}: response exceeds {limit} bytes")
            self.cache[key] = data
        return self.cache[key]

    def json(self, url, **kwargs):
        try:
            return json.loads(self.fetch(url, **kwargs))
        except ValueError as error:
            raise SourceError(f"{url}: not JSON ({error})") from error

    def text(self, url, **kwargs):
        return self.fetch(url, **kwargs).decode("utf-8", errors="replace")

    def github(self, path):
        return self.json(
            "https://api.github.com/" + path,
            headers={"Accept": "application/vnd.github+json"},
        )

    def yaml(self, url):
        import yaml

        # BaseLoader keeps every scalar a string, so 3.10 stays "3.10".
        return yaml.load(self.text(url), Loader=yaml.BaseLoader)

    def exists(self, url):
        try:
            with OPENER.open(
                self.request(url, method="HEAD"), timeout=TIMEOUT
            ) as response:
                return response.status == 200
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return False
            raise SourceError(f"{url}: {error}") from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise SourceError(f"{url}: {error}") from error

    def redirect(self, url):
        """Where a redirecting endpoint points, or None when it does not."""
        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(self.request(url), timeout=TIMEOUT):
                return None
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308):
                return error.headers.get("Location")
            if error.code == 404:
                return None
            raise SourceError(f"{url}: {error}") from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise SourceError(f"{url}: {error}") from error

    def download(self, url, size):
        """The SHA-256 of a release asset, which must be exactly `size` bytes."""
        digest = hashlib.sha256()
        total = 0
        try:
            with OPENER.open(self.request(url), timeout=TIMEOUT) as response:
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > size:
                        break
                    digest.update(chunk)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise SourceError(f"{url}: {error}") from error
        if total != size:
            raise SourceError(f"{url}: expected {size} bytes, read {total}")
        return digest.hexdigest()


def github_releases(upstream, repository):
    """Published, non-prerelease releases, newest first as GitHub lists them."""
    return [
        release
        for release in upstream.github(
            f"repos/{repository}/releases?per_page=100"
        )
        if not release.get("draft") and not release.get("prerelease")
    ]


def assets(release):
    return {asset["name"]: asset for asset in release.get("assets", [])}


# Resolvers --------------------------------------------------------------------
# Each takes the evaluated baseline and native managers and returns findings.


def resolve_node(upstream, baseline, managers):
    index = upstream.json("https://nodejs.org/dist/index.json")
    available = {
        entry["version"].lstrip("v")
        for entry in index
        if {"osx-arm64-tar", "linux-x64"} <= set(entry.get("files", []))
    }
    found = []
    pins = baseline["node"]["versions"]
    for pinned in pins:
        found += classify(
            "node",
            f"node {numeric(pinned)[0]}",
            pinned,
            available,
            1,
            edits=lambda v, p=pinned: [
                baseline_edit(p, v, "node.versions", "defaults.node")
            ],
            lines=pinned == max(pins, key=numeric),
        )
    return found


def resolve_python(upstream, baseline, managers):
    pinned = baseline["python"]["version"]
    releases = upstream.json(
        "https://www.python.org/api/v2/downloads/release/"
        "?is_published=true&pre_release=false"
    )
    available = {
        release["name"].removeprefix("Python ")
        for release in releases
        if release["name"].startswith("Python 3.")
    }
    tag = upstream.github("repos/pyenv/pyenv/releases/latest")["tag_name"]

    def installable(version):
        url = (
            f"https://raw.githubusercontent.com/pyenv/pyenv/{tag}/plugins/"
            f"python-build/share/python-build/{version}"
        )
        return (
            None if upstream.exists(url) else f"pyenv {tag} has no definition"
        )

    return classify(
        "python",
        "python",
        pinned,
        {v for v in available if stable(v)},
        2,
        installable,
        edits=lambda v: [
            baseline_edit(pinned, v, "python.version", "defaults.python")
        ],
    )


def resolve_ocaml(upstream, baseline, managers):
    listing = upstream.github(
        "repos/ocaml/opam-repository/contents/packages/ocaml-base-compiler"
    )
    available = {
        entry["name"].removeprefix("ocaml-base-compiler.")
        for entry in listing
        if entry["name"].startswith("ocaml-base-compiler.")
    }
    found = []
    pins = baseline["ocaml"]["versions"]
    for pinned in pins:
        found += classify(
            "ocaml",
            f"ocaml {'.'.join(map(str, numeric(pinned)[:2]))}",
            pinned,
            {v for v in available if stable(v)},
            2,
            edits=lambda v, p=pinned: [
                baseline_edit(p, v, "ocaml.versions", "defaults.ocaml")
            ],
            lines=pinned == max(pins, key=numeric),
        )
    return found


def resolve_rust(upstream, baseline, managers):
    pinned = baseline["nativeToolchains"]["rust"]["version"]
    manifest = upstream.text(
        "https://static.rust-lang.org/dist/channel-rust-stable.toml"
    )
    match = re.search(
        r'^\[pkg\.rust\]\nversion = "([0-9.]+) ', manifest, re.MULTILINE
    )
    if not match:
        raise SourceError("Rust's stable channel names no rust release")
    return classify(
        "rust",
        "rust",
        pinned,
        {match.group(1)},
        1,
        edits=lambda v: [
            baseline_edit(pinned, v, "nativeToolchains.rust", "defaults.rust")
        ],
    )


def ghcup_installable(entry):
    """Both platforms have a GHCup bindist for this release."""
    architectures = entry.get("viArch", {})
    darwin = "Darwin" in architectures.get("A_ARM64", {})
    linux = any(
        key.startswith("Linux") for key in architectures.get("A_64", {})
    )
    return None if darwin and linux else "no bindist for both platforms"


def resolve_haskell(upstream, baseline, managers):
    spec = baseline["nativeToolchains"]["haskell"]
    tools = upstream.yaml(GHCUP_METADATA)["ghcupDownloads"]

    def versions(tool):
        return {
            version: entry
            for version, entry in tools[tool]["toolVersions"].items()
            if stable(version)
        }

    found = []
    ghc = versions("GHC")
    found += classify(
        "haskell",
        "haskell ghc",
        spec["version"],
        set(ghc),
        2,
        lambda v: ghcup_installable(ghc[v]),
        edits=lambda v: [
            baseline_edit(
                spec["version"],
                v,
                "nativeToolchains.haskell.version",
                "defaults.haskell",
            )
        ],
        line_edits=lambda v: [
            baseline_edit(
                spec["version"],
                v,
                "nativeToolchains.haskell.version",
                "defaults.haskell",
            )
        ],
    )
    # Cabal and HLS follow the channel's recommendation, which for HLS is a
    # release with a server for the recommended compilers.
    for tool, key in (("Cabal", "cabal"), ("HLS", "hls")):
        entries = versions(tool)
        recommended = {
            version
            for version, entry in entries.items()
            if "Recommended" in entry.get("viTags", [])
        }
        found += classify(
            "haskell",
            f"haskell {key}",
            spec[key],
            recommended,
            1,
            lambda v, e=entries: ghcup_installable(e[v]),
            edits=lambda v, k=key: [
                baseline_edit(spec[k], v, f"nativeToolchains.haskell.{k}")
            ],
            line_edits=lambda v, k=key: [
                baseline_edit(spec[k], v, f"nativeToolchains.haskell.{k}")
            ],
        )
    return found


def resolve_lean(upstream, baseline, managers):
    pinned = baseline["nativeToolchains"]["lean"]["version"]
    available = set()
    for release in github_releases(upstream, "leanprover/lean4"):
        version = release["tag_name"].removeprefix("v")
        names = assets(release)
        if stable(version) and {
            f"lean-{version}-darwin_aarch64.tar.zst",
            f"lean-{version}-linux.tar.zst",
        } <= set(names):
            available.add(version)
    edits = lambda v: [  # noqa: E731
        baseline_edit(pinned, v, "nativeToolchains.lean", "defaults.lean")
    ]
    return classify(
        "lean", "lean", pinned, available, 1, edits=edits, line_edits=edits
    )


def resolve_ruby(upstream, baseline, managers):
    pinned = baseline["nativeToolchains"]["ruby"]["version"]
    index = upstream.text("https://cache.ruby-lang.org/pub/ruby/index.txt")
    available = {
        line.split("\t")[0].removeprefix("ruby-")
        for line in index.splitlines()
        if line.startswith("ruby-")
    }
    tag = upstream.github("repos/rbenv/ruby-build/releases/latest")["tag_name"]

    def installable(version):
        url = (
            f"https://raw.githubusercontent.com/rbenv/ruby-build/{tag}/"
            f"share/ruby-build/{version}"
        )
        return (
            None
            if upstream.exists(url)
            else f"ruby-build {tag} has no definition"
        )

    edits = lambda v: [  # noqa: E731
        baseline_edit(pinned, v, "nativeToolchains.ruby", "defaults.ruby")
    ]
    return classify(
        "ruby",
        "ruby",
        pinned,
        {v for v in available if stable(v)},
        2,
        installable,
        edits=edits,
        line_edits=edits,
    )


SDKMAN_LISTS = "https://api.sdkman.io/2/candidates"
SDKMAN_BROKER = "https://broker.sdkman.io/download"
SDKMAN_PLATFORMS = ("darwinarm64", "linuxx64")
ADOPTIUM = "https://api.adoptium.net/v3"


def temurin_release(upstream, feature):
    """The latest Temurin GA of a feature release on both platforms.

    Returns the identity `java -version` reports and Adoptium's release name.
    """
    names = set()
    identity = None
    for os_name, architecture in (("mac", "aarch64"), ("linux", "x64")):
        latest = upstream.json(
            f"{ADOPTIUM}/assets/latest/{feature}/hotspot?architecture="
            f"{architecture}&image_type=jdk&os={os_name}&vendor=eclipse"
        )
        if not latest:
            return None, None
        names.add(latest[0]["release_name"])
        match = re.match(r"[0-9.]+", latest[0]["version"]["openjdk_version"])
        if not match:
            raise SourceError("Adoptium reported no Java version")
        identity = match.group()
    if len(names) != 1:
        return None, None
    return identity, names.pop()


def sdkman_candidate(upstream, feature, release_name):
    """The SDKMAN identifier whose download is exactly that Temurin release.

    SDKMAN's identifiers do not follow Adoptium's names and its per-platform
    lists disagree, so we ask its broker where each one points.
    """
    identifiers = set()
    for platform in SDKMAN_PLATFORMS:
        table = upstream.text(
            f"{SDKMAN_LISTS}/java/{platform}/versions/list?installed="
        )
        identifiers |= set(
            re.findall(rf"\b({feature}\.[0-9][^\s|]*-tem)\b", table)
        )
    target = urllib.parse.quote(release_name)
    for identifier in sorted(identifiers, key=numeric, reverse=True):
        if all(
            target
            in (
                upstream.redirect(
                    f"{SDKMAN_BROKER}/java/{identifier}/{platform}"
                )
                or ""
            )
            for platform in SDKMAN_PLATFORMS
        ):
            return identifier
    return None


def resolve_jvm(upstream, baseline, managers):
    spec = baseline["nativeToolchains"]["jvm"]
    pinned = spec["version"]
    feature = numeric(pinned)[0]

    def candidate_edits(version, feature):
        _, release_name = temurin_release(upstream, feature)
        candidate = sdkman_candidate(upstream, feature, release_name)
        return [
            baseline_edit(
                pinned, version, "nativeToolchains.jvm.version", "defaults.jvm"
            ),
            baseline_edit(
                spec["candidate"], candidate, "nativeToolchains.jvm.candidate"
            ),
        ]

    found = []
    identity, release_name = temurin_release(upstream, feature)
    if identity and numeric(identity) > numeric(pinned):
        candidate = sdkman_candidate(upstream, feature, release_name)
        if candidate:
            found.append(
                Finding(
                    "jvm",
                    f"jvm {feature}",
                    pinned,
                    identity,
                    "update",
                    f"SDKMAN {candidate}",
                    lambda: candidate_edits(identity, feature),
                )
            )
        else:
            found.append(
                Finding(
                    "jvm",
                    f"jvm {feature}",
                    pinned,
                    identity,
                    "pending",
                    f"SDKMAN has no candidate for {release_name} yet",
                )
            )
    lts = upstream.json(f"{ADOPTIUM}/info/available_releases")[
        "most_recent_lts"
    ]
    if lts > feature:
        version, release_name = temurin_release(upstream, lts)
        candidate = version and sdkman_candidate(upstream, lts, release_name)
        found.append(
            Finding(
                "jvm",
                f"jvm {feature}",
                pinned,
                version or str(lts),
                "line",
                f"LTS {lts}"
                + (
                    f", SDKMAN {candidate}"
                    if candidate
                    else ", no SDKMAN candidate"
                )
                + "; the temurin@21 cask in darwin/homebrew.nix is separate",
                candidate and (lambda: candidate_edits(version, lts)),
            )
        )
    return found or [Finding("jvm", f"jvm {feature}", pinned)]


def resolve_sdkman_tool(name):
    def resolve(upstream, baseline, managers):
        pinned = baseline["nativeToolchains"][name]["version"]
        lists = [
            set(
                upstream.text(
                    f"{SDKMAN_LISTS}/{name}/{platform}/versions/all"
                ).split(",")
            )
            for platform in SDKMAN_PLATFORMS
        ]
        available = {v.strip() for v in set.intersection(*lists)}
        edits = lambda v: [  # noqa: E731
            baseline_edit(
                pinned, v, f"nativeToolchains.{name}", f"defaults.{name}"
            )
        ]
        return classify(
            name,
            name,
            pinned,
            {v for v in available if stable(v)},
            1,
            edits=edits,
            line_edits=edits,
        )

    return resolve


def resolve_scala(upstream, baseline, managers):
    pinned = baseline["nativeToolchains"]["scala"]["version"]
    available = set()
    for release in github_releases(upstream, "scala/scala3"):
        version = release["tag_name"]
        if stable(version) and {
            f"scala3-{version}-aarch64-apple-darwin.tar.gz",
            f"scala3-{version}-x86_64-pc-linux.tar.gz",
        } <= set(assets(release)):
            available.add(version)
    edits = lambda v: [  # noqa: E731
        baseline_edit(pinned, v, "nativeToolchains.scala", "defaults.scala")
    ]
    return classify(
        "scala", "scala", pinned, available, 1, edits=edits, line_edits=edits
    )


def resolve_julia(upstream, baseline, managers):
    pinned = baseline["nativeToolchains"]["julia"]["version"]
    versions = upstream.json(
        "https://julialang-s3.julialang.org/bin/versions.json"
    )
    available = {
        version
        for version, entry in versions.items()
        if entry.get("stable")
        and {"aarch64-apple-darwin14", "x86_64-linux-gnu"}
        <= {f.get("triplet") for f in entry.get("files", [])}
    }
    edits = lambda v: [  # noqa: E731
        baseline_edit(pinned, v, "nativeToolchains.julia", "defaults.julia")
    ]
    return classify(
        "julia",
        "julia",
        pinned,
        {v for v in available if stable(v)},
        2,
        edits=edits,
        line_edits=edits,
    )


def resolve_dotnet(upstream, baseline, managers):
    """The SDK patch in the pinned feature band, and newer bands or channels.

    A feature band is the hundreds of the patch number: 10.0.401 is 10.0.4xx.
    """
    pinned = baseline["nativeToolchains"]["dotnet"]["version"]
    major, minor, patch = numeric(pinned)
    channel = f"{major}.{minor}"

    def sdks(channel):
        metadata = upstream.json(
            "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/"
            f"{channel}/releases.json"
        )
        return {
            sdk["version"]
            for release in metadata.get("releases", [])
            for sdk in release.get("sdks", [])
            if stable(sdk["version"])
            and {"osx-arm64", "linux-x64"}
            <= {f.get("rid") for f in sdk.get("files", [])}
        }

    def band(version):
        a, b, c = numeric(version)
        return (a, b, c // 100)

    edits = lambda v: [  # noqa: E731
        baseline_edit(pinned, v, "nativeToolchains.dotnet", "defaults.dotnet")
    ]
    available = sdks(channel)
    found = [
        f
        for f in classify(
            "dotnet",
            f"dotnet {channel}.{patch // 100}xx",
            pinned,
            {v for v in available if band(v) == band(pinned)},
            0,
            edits=edits,
        )
        if f.kind != "current"
    ]
    bands = newer({v for v in available if band(v) > band(pinned)}, pinned)
    index = upstream.json(
        "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/"
        "releases-index.json"
    )
    channels = sorted(
        (
            entry["channel-version"]
            for entry in index["releases-index"]
            if entry.get("support-phase") == "active"
            and numeric(entry["channel-version"]) > (major, minor)
        ),
        key=numeric,
        reverse=True,
    )
    if channels:
        newest = newer(sdks(channels[0]), pinned)
        if newest:
            found.append(
                Finding(
                    "dotnet",
                    f"dotnet {channel}.{patch // 100}xx",
                    pinned,
                    newest[0],
                    "line",
                    f".NET {channels[0]}",
                    lambda: edits(newest[0]),
                )
            )
    elif bands:
        found.append(
            Finding(
                "dotnet",
                f"dotnet {channel}.{patch // 100}xx",
                pinned,
                bands[0],
                "line",
                "a newer feature band",
                lambda: edits(bands[0]),
            )
        )
    return found or [
        Finding("dotnet", f"dotnet {channel}.{patch // 100}xx", pinned)
    ]


def release_assets(upstream, release, wanted, platforms_edits):
    """Edits that move pinned release assets to another release.

    `wanted` maps each platform to (pinned installer, new asset name); the
    new hash and size come from downloading the asset.
    """
    names = assets(release)
    edits = []
    for platform, (installer, name) in wanted.items():
        asset = names[name]
        digest = upstream.download(
            asset["browser_download_url"], asset["size"]
        )
        published = asset.get("digest")
        if published and published != f"sha256:{digest}":
            raise SourceError(
                f"{name}: GitHub's digest disagrees with the bytes"
            )
        scope = platforms_edits[platform]
        edits += [
            Edit(MANAGERS, f'"{installer["sha256"]}"', f'"{digest}"', scope),
            Edit(
                MANAGERS,
                f"size = {installer['size']};",
                f"size = {asset['size']};",
                scope,
            ),
        ]
    return edits


def release_tag(url):
    match = re.search(r"/releases/download/([^/]+)/", url)
    if not match:
        raise SourceError(f"not a GitHub release asset: {url}")
    return match.group(1)


def installer_scopes(name):
    return {
        platform: (f"bootstrap.{platform}.installers.{name}",)
        for platform in PLATFORMS
    }


def resolve_conda(upstream, baseline, managers):
    """Conda through Miniforge3, whose release X-N ships conda X."""
    pinned = baseline["nativeToolchains"]["conda"]["version"]
    installers = {
        platform: managers["bootstrap"][platform]["installers"]["conda"]
        for platform in PLATFORMS
    }
    tag = release_tag(installers["aarch64-darwin"]["url"])
    releases = {}
    for release in github_releases(upstream, "conda-forge/miniforge"):
        version, _, build = release["tag_name"].partition("-")
        names = assets(release)
        if (
            stable(version)
            and build.isdigit()
            and {
                f"Miniforge3-{release['tag_name']}-MacOSX-arm64.sh",
                f"Miniforge3-{release['tag_name']}-Linux-x86_64.sh",
            }
            <= set(names)
        ):
            releases.setdefault(version, release)

    def edits(version):
        release = releases[version]
        new_tag = release["tag_name"]
        wanted = {
            "aarch64-darwin": (
                installers["aarch64-darwin"],
                f"Miniforge3-{new_tag}-MacOSX-arm64.sh",
            ),
            "x86_64-linux": (
                installers["x86_64-linux"],
                f"Miniforge3-{new_tag}-Linux-x86_64.sh",
            ),
        }
        scopes = installer_scopes("conda")
        every = tuple(s for scope in scopes.values() for s in scope)
        return [
            baseline_edit(
                pinned, version, "nativeToolchains.conda", "defaults.conda"
            ),
            Edit(MANAGERS, tag, new_tag, every),
            *release_assets(upstream, release, wanted, scopes),
        ]

    return classify(
        "conda",
        "conda",
        pinned,
        set(releases),
        0,
        edits=edits,
    )


def resolve_coursier(upstream, baseline, managers):
    """The pinned native `cs` launcher that installs Scala."""
    installers = {
        platform: managers["bootstrap"][platform]["installers"]["scala"]
        for platform in PLATFORMS
    }
    tag = release_tag(installers["aarch64-darwin"]["url"])
    pinned = tag.removeprefix("v")
    releases = {}
    for release in github_releases(upstream, "coursier/coursier"):
        version = release["tag_name"].removeprefix("v")
        if stable(version) and {
            "cs-aarch64-apple-darwin.gz",
            "cs-x86_64-pc-linux.gz",
        } <= set(assets(release)):
            releases.setdefault(version, release)

    def edits(version):
        release = releases[version]
        wanted = {
            "aarch64-darwin": (
                installers["aarch64-darwin"],
                "cs-aarch64-apple-darwin.gz",
            ),
            "x86_64-linux": (
                installers["x86_64-linux"],
                "cs-x86_64-pc-linux.gz",
            ),
        }
        scopes = installer_scopes("scala")
        every = tuple(s for scope in scopes.values() for s in scope)
        return [
            Edit(
                MANAGERS, f"/download/{tag}/", f"/download/v{version}/", every
            ),
            *release_assets(upstream, release, wanted, scopes),
        ]

    return classify(
        "coursier",
        "coursier launcher",
        pinned,
        set(releases),
        1,
        edits=edits,
        line_edits=edits,
    )


# Installer scripts ------------------------------------------------------------


def review_directory():
    cache = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(cache) / "update-runtime-baseline" / "installers"


def review_path(name, digest):
    return review_directory() / f"{name}-{digest[:16]}"


def mutable_installers(managers):
    """Hash-pinned scripts at mutable URLs; release assets carry a size."""
    installers = managers["bootstrap"]["aarch64-darwin"]["installers"]
    return {
        name: installer
        for name, installer in sorted(installers.items())
        if "size" not in installer
    }


def save_for_review(name, data):
    digest = hashlib.sha256(data).hexdigest()
    path = review_path(name, digest)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.exists():
        path.write_bytes(data)
    return digest, path


def resolve_installers(upstream, baseline, managers):
    found = []
    for name, installer in mutable_installers(managers).items():
        data = upstream.fetch(installer["url"], limit=INSTALLER_LIMIT)
        digest = hashlib.sha256(data).hexdigest()
        if digest == installer["sha256"]:
            found.append(
                Finding(
                    "installers", f"installer {name}", installer["sha256"][:12]
                )
            )
            continue
        _, path = save_for_review(name, data)
        previous = review_path(name, installer["sha256"])
        note = f"review {path}"
        if previous.exists():
            note += f" (diff against {previous})"
        found.append(
            Finding(
                "installers",
                f"installer {name}",
                installer["sha256"][:12],
                digest[:12],
                "drift",
                note + f", then --accept-installer {name}",
            )
        )
    return found


RESOLVERS = {
    "node": resolve_node,
    "python": resolve_python,
    "ocaml": resolve_ocaml,
    "rust": resolve_rust,
    "haskell": resolve_haskell,
    "lean": resolve_lean,
    "ruby": resolve_ruby,
    "jvm": resolve_jvm,
    "kotlin": resolve_sdkman_tool("kotlin"),
    "maven": resolve_sdkman_tool("maven"),
    "gradle": resolve_sdkman_tool("gradle"),
    "scala": resolve_scala,
    "julia": resolve_julia,
    "dotnet": resolve_dotnet,
    "conda": resolve_conda,
    "coursier": resolve_coursier,
    "installers": resolve_installers,
}


# Declarations -----------------------------------------------------------------


def evaluate(path):
    try:
        output = subprocess.run(
            ["nix", "eval", "--json", "--file", str(path)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except FileNotFoundError as error:
        raise SourceError(
            "nix is required to read the declarations"
        ) from error
    except subprocess.CalledProcessError as error:
        raise SourceError(
            f"{path.name} does not evaluate: {error.stderr.strip()}"
        ) from error
    return json.loads(output)


def flatten(value, prefix=""):
    """Every leaf of an evaluated declaration by its dotted path."""
    if isinstance(value, dict):
        items = value.items()
    elif isinstance(value, list):
        items = enumerate(value)
    else:
        return {prefix: value}
    leaves = {}
    for key, item in items:
        leaves |= flatten(item, f"{prefix}.{key}" if prefix else str(key))
    return leaves


def within(path, scopes):
    return any(path == s or path.startswith(s + ".") for s in scopes)


def apply_edits(edits, evaluate=evaluate):
    """Rewrite by exact replacement; restore unless only the scopes changed."""
    files = sorted({edit.path for edit in edits})
    originals = {path: path.read_text() for path in files}
    before = {path: flatten(evaluate(path)) for path in files}
    rewritten = dict(originals)
    for edit in edits:
        if edit.old not in rewritten[edit.path]:
            raise SourceError(f"{edit.path.name}: {edit.old} not found")
        rewritten[edit.path] = rewritten[edit.path].replace(edit.old, edit.new)
    try:
        for path in files:
            path.write_text(rewritten[path])
        for path in files:
            after = flatten(evaluate(path))
            scopes = tuple(
                scope
                for edit in edits
                if edit.path == path
                for scope in edit.scopes
            )
            changed = {
                key
                for key in before[path].keys() | after.keys()
                if before[path].get(key) != after.get(key)
            }
            stray = sorted(key for key in changed if not within(key, scopes))
            if stray:
                raise SourceError(
                    f"{path.name}: the rewrite also changed {', '.join(stray)}"
                )
    except BaseException:
        for path, text in originals.items():
            path.write_text(text)
        raise


def accept_installers(names, upstream, managers):
    installers = mutable_installers(managers)
    edits, accepted = [], []
    for name in names:
        if name not in installers:
            raise SourceError(
                f"no mutable installer named {name}; "
                f"choose from {', '.join(installers)}"
            )
        pinned = installers[name]["sha256"]
        data = upstream.fetch(installers[name]["url"], limit=INSTALLER_LIMIT)
        digest = hashlib.sha256(data).hexdigest()
        if digest == pinned:
            print(f"installer {name}: unchanged")
            continue
        path = review_path(name, digest)
        if not path.exists() or path.read_bytes() != data:
            _, path = save_for_review(name, data)
            raise SourceError(
                f"installer {name}: read {path} first; upstream serves bytes "
                "nobody reviewed yet"
            )
        scopes = installer_scopes(name).values()
        edits.append(
            Edit(
                MANAGERS,
                f'"{pinned}"',
                f'"{digest}"',
                tuple(scope for group in scopes for scope in group),
            )
        )
        accepted.append(name)
    # The reviewed bytes stay in the review directory under their hash, so
    # the next drift report can name them for a diff.
    if edits:
        apply_edits(edits)
    for name in accepted:
        print(f"installer {name}: recorded the reviewed hash")


# Reporting --------------------------------------------------------------------

COLUMNS = ("ecosystem", "pinned", "available", "state", "note")


def rows(findings):
    return [
        (f.name, f.pinned, f.available or "-", f.kind, f.note)
        for f in findings
    ]


def render_text(findings, errors):
    table = rows(findings)
    widths = [
        max(len(str(row[i])) for row in [COLUMNS, *table]) for i in range(4)
    ]
    lines = []
    for row in [COLUMNS, *table]:
        cells = [
            str(cell).ljust(width)
            for cell, width in zip(row[:4], widths, strict=True)
        ]
        lines.append("  ".join([*cells, row[4]]).rstrip())
    lines += [f"error    {name}: {message}" for name, message in errors]
    return "\n".join(lines)


def render_markdown(findings, errors):
    actionable = [f for f in findings if f.actionable]
    lines = [
        "## Runtime baseline freshness",
        "",
        f"{len(actionable)} actionable, {len(errors)} source errors.",
        "",
        "| " + " | ".join(c.capitalize() for c in COLUMNS) + " |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in rows(f for f in findings if f.kind != "current"):
        cells = [str(c).replace("|", "\\|") for c in row]
        lines.append("| " + " | ".join(cells) + " |")
    lines += [f"- Error in {name}: {message}" for name, message in errors]
    return "\n".join(lines)


# Entry ------------------------------------------------------------------------


def parse_arguments(argv):
    parser = argparse.ArgumentParser(
        prog="update-runtime-baseline",
        description="Report or advance the runtime baseline's upstream pins.",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--accept-installer", metavar="NAME", action="append")
    parser.add_argument(
        "--line",
        choices=ECOSYSTEMS,
        action="append",
        default=[],
        help="Also move this ecosystem to its newest line (with --apply)",
    )
    parser.add_argument(
        "--markdown", action="store_true", help="Report as Markdown"
    )
    parser.add_argument(
        "ecosystems",
        nargs="*",
        metavar="ECOSYSTEM",
        help=f"Limit to these: {', '.join(ECOSYSTEMS)}",
    )
    args = parser.parse_args(argv)
    unknown = sorted(set(args.ecosystems) - set(ECOSYSTEMS))
    if unknown:
        parser.error(f"unknown ecosystems: {', '.join(unknown)}")
    if args.line and not args.apply:
        parser.error("--line requires --apply")
    for name in args.line:
        if name in MANUAL_LINES:
            parser.error(f"--line {name}: {MANUAL_LINES[name]}")
    return args


def needs_yaml(selected):
    if "haskell" not in selected:
        return False
    try:
        import yaml  # noqa: F401
    except ImportError:
        return True
    return False


def reexecute(argv):
    """Run again in the locked shell that provides PyYAML for GHCup's data."""
    if os.environ.get("UPDATE_RUNTIME_BASELINE_SHELL") or not shutil.which(
        "nix"
    ):
        raise SourceError(
            "GHCup's metadata needs PyYAML; run inside: nix develop --impure "
            "--expr 'import ./scripts/development-bootstrap.nix "
            '{ target = "freshness"; }\''
        )
    expression = (
        f"import {ROOT / 'scripts/development-bootstrap.nix'} "
        '{ target = "freshness"; }'
    )
    os.execvpe(
        "nix",
        [
            "nix",
            "develop",
            "--impure",
            "--expr",
            expression,
            "--command",
            "python3",
            str(Path(__file__).resolve()),
            *argv,
        ],
        os.environ | {"UPDATE_RUNTIME_BASELINE_SHELL": "1"},
    )


def resolve(selected, upstream, baseline, managers):
    findings, errors = [], []
    for name in selected:
        try:
            findings += RESOLVERS[name](upstream, baseline, managers)
        except (SourceError, KeyError, TypeError, ValueError) as error:
            errors.append((name, f"{type(error).__name__}: {error}"))
    return findings, errors


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    args = parse_arguments(argv)
    selected = args.ecosystems or list(ECOSYSTEMS)
    upstream = Upstream(os.environ.get("GITHUB_TOKEN"))
    try:
        managers = evaluate(MANAGERS)
        if args.accept_installer:
            accept_installers(args.accept_installer, upstream, managers)
            return 0
        if needs_yaml(selected):
            reexecute(argv)
        baseline = evaluate(BASELINE)
        findings, errors = resolve(selected, upstream, baseline, managers)
    except SourceError as error:
        print(f"update-runtime-baseline: {error}", file=sys.stderr)
        return 2
    render = render_markdown if args.markdown else render_text
    print(render(findings, errors))
    if errors:
        return 2
    if args.check:
        return 1 if any(f.actionable for f in findings) else 0
    chosen = [
        f
        for f in findings
        if f.edits
        and (
            f.kind == "update"
            or (f.kind == "line" and f.ecosystem in args.line)
        )
    ]
    if not chosen:
        print("Nothing to apply.")
        return 0
    try:
        # Build every rewrite, downloads included, before writing anything.
        edits = [edit for f in chosen for edit in f.edits()]
        apply_edits(edits)
    except SourceError as error:
        print(f"update-runtime-baseline: {error}", file=sys.stderr)
        return 2
    print()
    for f in chosen:
        print(f"applied  {f.name}: {f.pinned} -> {f.available}")
    print(
        "Next: build, run the native CI adapters for these ecosystems, then "
        "apply on each host (see home/dev/README.md)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
