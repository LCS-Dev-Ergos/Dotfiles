"""Temurin through SDKMAN: Adoptium names the release, SDKMAN serves it.

SDKMAN's identifiers do not follow Adoptium's release names and its
per-platform lists disagree, so a candidate counts only when SDKMAN's broker
redirects to exactly that Temurin release on both platforms.
"""

import functools
import re
import urllib.parse

from ..declarations import baseline_edit
from ..model import Finding, Kind, SourceError
from ..upstream import Source
from ..versions import numeric
from .sources import ADOPTIUM, SDKMAN_BROKER, SDKMAN_LISTS, SDKMAN_PLATFORMS

VERSION = "nativeToolchains.jvm.version"
CANDIDATE = "nativeToolchains.jvm.candidate"


def temurin_release(upstream: Source, feature: int) -> tuple[str, str] | None:
    """The latest Temurin GA of a feature release on both platforms.

    Returns the identity `java -version` reports and Adoptium's release name.
    """
    names = set()
    identity = ""
    for os_name, architecture in (("mac", "aarch64"), ("linux", "x64")):
        latest = upstream.json(
            f"{ADOPTIUM}/assets/latest/{feature}/hotspot?architecture="
            f"{architecture}&image_type=jdk&os={os_name}&vendor=eclipse"
        )
        if not latest:
            return None
        names.add(latest[0]["release_name"])
        match = re.match(r"[0-9.]+", latest[0]["version"]["openjdk_version"])
        if not match:
            raise SourceError("Adoptium reported no Java version")
        identity = match.group()
    if len(names) != 1:
        return None
    return identity, names.pop()


def sdkman_candidate(
    upstream: Source, feature: int, release_name: str
) -> str | None:
    """The SDKMAN identifier whose download is exactly that Temurin release."""
    identifiers = set()
    for platform in SDKMAN_PLATFORMS:
        table = upstream.text(
            f"{SDKMAN_LISTS}/java/{platform}/versions/list?installed="
        )
        identifiers |= set(
            re.findall(rf"\b({feature}\.[0-9][0-9A-Za-z.+_-]*-tem)\b", table)
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


def resolve(upstream: Source, baseline: dict, managers: dict) -> list:
    spec = baseline["nativeToolchains"]["jvm"]
    pinned = spec["version"]
    feature = numeric(pinned)[0]
    name = f"jvm {feature}"
    retires = ((VERSION, pinned), (CANDIDATE, spec["candidate"]))

    def edits(version, candidate):
        return [
            baseline_edit(pinned, version, VERSION, "defaults.jvm"),
            baseline_edit(spec["candidate"], candidate, CANDIDATE),
        ]

    found = []
    release = temurin_release(upstream, feature)
    if release and numeric(release[0]) > numeric(pinned):
        identity, release_name = release
        candidate = sdkman_candidate(upstream, feature, release_name)
        if candidate:
            found.append(
                Finding(
                    "jvm",
                    name,
                    pinned,
                    identity,
                    Kind.UPDATE,
                    f"SDKMAN {candidate}",
                    functools.partial(edits, identity, candidate),
                    retires,
                )
            )
        else:
            found.append(
                Finding(
                    "jvm",
                    name,
                    pinned,
                    identity,
                    Kind.PENDING,
                    f"SDKMAN has no candidate for {release_name} yet",
                )
            )
    lts = upstream.json(f"{ADOPTIUM}/info/available_releases")[
        "most_recent_lts"
    ]
    if lts > feature:
        release = temurin_release(upstream, lts)
        candidate = release and sdkman_candidate(upstream, lts, release[1])
        found.append(
            Finding(
                "jvm",
                name,
                pinned,
                release[0] if release else str(lts),
                Kind.LINE,
                f"LTS {lts}"
                + (
                    f", SDKMAN {candidate}"
                    if candidate
                    else ", no SDKMAN candidate"
                )
                + "; the temurin@21 cask in darwin/homebrew.nix is separate",
                functools.partial(edits, release[0], candidate)
                if release and candidate
                else None,
                retires if candidate else (),
            )
        )
    return found or [Finding("jvm", name, pinned)]
