"""The .NET SDK: patches within the pinned feature band, then newer ones.

A feature band is the hundreds of the patch number: 10.0.401 is 10.0.4xx.
dotnet-install fetches any SDK by version, so every release Microsoft lists
for both platforms is installable.
"""

from ..declarations import baseline_edit
from ..model import Finding, Kind, classify
from ..upstream import Source
from ..versions import newer, numeric, stable

METADATA = "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/"
DECLARATION = "nativeToolchains.dotnet.version"


def band(version: str) -> tuple[int, int, int]:
    major, minor, patch = numeric(version)
    return (major, minor, patch // 100)


def sdks(upstream: Source, channel: str) -> set[str]:
    releases = upstream.json(f"{METADATA}{channel}/releases.json")
    return {
        sdk["version"]
        for release in releases.get("releases", [])
        for sdk in release.get("sdks", [])
        if stable(sdk["version"])
        and {"osx-arm64", "linux-x64"}
        <= {f.get("rid") for f in sdk.get("files", [])}
    }


def resolve(upstream: Source, baseline: dict, managers: dict) -> list:
    pinned = baseline["nativeToolchains"]["dotnet"]["version"]
    major, minor, patch = numeric(pinned)
    channel = f"{major}.{minor}"
    name = f"dotnet {channel}.{patch // 100}xx"
    retires = ((DECLARATION, pinned),)

    def edits(version):
        return [baseline_edit(pinned, version, DECLARATION, "defaults.dotnet")]

    available = sdks(upstream, channel)
    found = [
        finding
        for finding in classify(
            "dotnet",
            name,
            pinned,
            {v for v in available if band(v) == band(pinned)},
            0,
            edits=edits,
            retires=retires,
        )
        if finding.kind != Kind.CURRENT
    ]
    bands = newer({v for v in available if band(v) > band(pinned)}, pinned)
    index = upstream.json(f"{METADATA}releases-index.json")
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
        newest = newer(sdks(upstream, channels[0]), pinned)
        if newest:
            found.append(
                Finding(
                    "dotnet",
                    name,
                    pinned,
                    newest[0],
                    Kind.LINE,
                    f".NET {channels[0]}",
                    lambda: edits(newest[0]),
                    retires,
                )
            )
    elif bands:
        found.append(
            Finding(
                "dotnet",
                name,
                pinned,
                bands[0],
                Kind.LINE,
                "a newer feature band",
                lambda: edits(bands[0]),
                retires,
            )
        )
    return found or [Finding("dotnet", name, pinned)]
