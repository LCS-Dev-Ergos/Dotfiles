"""The Android SDK, as Google's repository index lists it for sdkmanager.

A package counts when it has an archive for macOS and Linux and needs only
the Android SDK License: release candidates and betas carry the preview
license or a suffix. The command-line tools that provide sdkmanager are
declared by release; their archives' names carry the matching build number
and move with it.
"""

import functools
import re
import xml.etree.ElementTree as ElementTree
from dataclasses import replace

from .. import declarations
from ..declarations import PLATFORMS, baseline_edit, lookup
from ..model import Edit, Kind, SourceError, classify
from ..upstream import Source
from .assets import installer_scopes

REPOSITORY = "https://dl.google.com/android/repository/"
INDEX = REPOSITORY + "repository2-3.xml"
LICENSE = "android-sdk-license"
# The archive each supported platform downloads, by host-os and host-arch.
HOSTS = {
    "aarch64-darwin": ("macosx", "aarch64"),
    "x86_64-linux": ("linux", None),
}
# The package path each declaration follows, with the release it names.
PATHS = {
    "platform-tools": re.compile(r"platform-tools()"),
    "build-tools": re.compile(r"build-tools;([0-9]+\.[0-9]+\.[0-9]+)"),
    "platform": re.compile(r"platforms;android-([0-9]+(?:\.[0-9]+)?)"),
}
BUILD = re.compile(r"-([0-9]+)_latest\.zip$")
DECLARATION = "nativeToolchains.android.tools"
SHIM = (
    "from 23.0 sdkmanager hands its commands to the Android CLI; "
    "keep the pinned release until that is reviewed"
)


def text(element, name):
    child = element.find(name)
    return child.text.strip() if child is not None and child.text else None


def archives(package) -> dict[str, dict]:
    """The package's archive per supported platform, where it has one."""
    found = {}
    for archive in package.iter("archive"):
        system, architecture = (
            text(archive, "host-os"),
            text(archive, "host-arch"),
        )
        complete = archive.find("complete")
        url = text(complete, "url") if complete is not None else None
        size = text(complete, "size") if complete is not None else None
        if not url or not size or not size.isdigit():
            continue
        for platform, (wanted, wanted_architecture) in HOSTS.items():
            # An archive without a host serves every platform.
            if system not in (None, wanted):
                continue
            if architecture not in (None, wanted_architecture):
                continue
            found.setdefault(
                platform,
                {
                    "url": REPOSITORY + url,
                    "size": int(size),
                    "sha1": text(complete, "checksum"),
                },
            )
    return found


def packages(upstream: Source) -> dict[str, list]:
    """Every remote package path with its license and archives."""
    try:
        root = ElementTree.fromstring(upstream.fetch(INDEX))
    except (ElementTree.ParseError, ValueError, TypeError) as error:
        raise SourceError(
            f"{INDEX}: not the repository index ({error})"
        ) from error
    listed = {}
    for package in root.iter("remotePackage"):
        license = package.find("uses-license")
        revision = package.find("revision")
        parts = [] if revision is None else list(revision)
        listed.setdefault(package.get("path", ""), []).append(
            {
                "license": license.get("ref") if license is not None else None,
                "revision": ".".join(
                    part.text
                    for part in parts
                    if part.tag in ("major", "minor", "micro") and part.text
                ),
                "preview": any(part.tag == "preview" for part in parts),
                "archives": archives(package),
            }
        )
    return listed


def listing(component: str):
    """The releases of a component installable on both platforms."""

    def releases(upstream: Source) -> set[str]:
        found = set()
        for path, entries in packages(upstream).items():
            matched = PATHS[component].fullmatch(path)
            if not matched:
                continue
            for entry in entries:
                if (
                    entry["license"] == LICENSE
                    and not entry["preview"]
                    and set(HOSTS) <= set(entry["archives"])
                ):
                    found.add(matched.group(1) or entry["revision"])
        return found

    return releases


def build(url: str) -> str:
    found = BUILD.search(url)
    if not found:
        raise SourceError(f"not a command-line tools archive: {url}")
    return found.group(1)


def tools(upstream: Source, baseline: dict, managers: dict) -> list:
    """The pinned command-line tools release against the index's releases.

    A newer major is reported, never moved: from 23.0 on, sdkmanager hands
    its commands to the Android CLI, which the bootstrap does not run.
    """
    pinned = lookup(baseline, DECLARATION)
    installers = {
        platform: managers["bootstrap"][platform]["installers"]["android"]
        for platform in PLATFORMS
    }
    releases = {}
    for path, entries in packages(upstream).items():
        found = re.fullmatch(r"cmdline-tools;([0-9]+\.[0-9]+)", path)
        for entry in entries if found else ():
            if entry["license"] == LICENSE and set(PLATFORMS) <= set(
                entry["archives"]
            ):
                releases[found.group(1)] = entry
    found = classify(
        "android-tools",
        "android command-line tools",
        pinned,
        set(releases),
        1,
        edits=functools.partial(moves, upstream, installers, pinned, releases),
        retires=((DECLARATION, pinned),),
    )
    return [
        replace(finding, note=SHIM) if finding.kind == Kind.LINE else finding
        for finding in found
    ]


def moves(upstream, installers, pinned, releases, version) -> list[Edit]:
    """The declared release and its archives, from the downloaded bytes."""
    entry = releases[version]
    builds = {build(archive["url"]) for archive in entry["archives"].values()}
    if len(builds) != 1:
        raise SourceError(f"command-line tools {version} builds differ")
    (new,) = builds
    found = [
        baseline_edit(pinned, version, DECLARATION),
        Edit(
            declarations.MANAGERS,
            f"-{build(installers[PLATFORMS[0]]['url'])}_latest.zip",
            f"-{declarations.release_identifier(new)}_latest.zip",
            installer_scopes("android"),
        ),
    ]
    for platform, installer in installers.items():
        archive = entry["archives"][platform]
        digest = upstream.download(
            archive["url"], archive["size"], sha1=archive["sha1"]
        )
        scope = (f"bootstrap.{platform}.installers.android",)
        found += [
            Edit(
                declarations.MANAGERS,
                f'"{installer["sha256"]}"',
                f'"{digest}"',
                scope,
            ),
            Edit(
                declarations.MANAGERS,
                f"size = {installer['size']};",
                f"size = {archive['size']};",
                scope,
            ),
        ]
    return found
