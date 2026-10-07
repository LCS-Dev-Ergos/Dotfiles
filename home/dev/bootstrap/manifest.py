"""Validate the Nix-generated baseline before constructing runtime adapters."""

import json
import re
from support import BootstrapError
from native_toolchains import validate as validate_native


def version(value):
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", value
    ):
        raise BootstrapError(
            "Runtime versions must be exact three-part releases"
        )
    return value


def load_manifest(path):
    """Validate identifiers before they can reach paths, URLs or arguments."""
    try:
        data = json.loads(path.read_text())
        validate_manifest(data)
    except (KeyError, TypeError, AttributeError, ValueError) as error:
        raise BootstrapError(f"Invalid baseline {path}: {error}") from error
    return data


def validate_manifest(data):
    """Reject malformed declarations at the input boundary, before any work."""
    if data["schema"] != 1 or data["backend"] not in ("native", "nixpkgs"):
        raise BootstrapError("Unsupported baseline schema or backend")
    if data["platform"] not in ("aarch64-darwin", "x86_64-linux"):
        raise BootstrapError("No bootstrap adapter for this platform")
    versions = [version(item["version"]) for item in data["node"]]
    if len(set(versions)) != len(versions):
        raise BootstrapError("Duplicate Node identity")
    for item in data["node"]:
        digest = item["hashes"].get(data["platform"], "")
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise BootstrapError("Missing pinned Node artifact hash")
    version(data["python"]["version"])
    version(data["python"]["pythonBuildVersion"])
    for release in data["ocaml"]["versions"]:
        version(release)
    if (
        data["ocaml"]["repository"]
        != "https://github.com/ocaml/opam-repository.git"
    ):
        raise BootstrapError("Unsupported opam repository")
    if not re.fullmatch(r"[a-f0-9]{40}", data["ocaml"]["revision"]):
        raise BootstrapError("opam repository must use an immutable revision")
    validate_native(data, BootstrapError)
    declared = {
        "node": versions,
        "python": [data["python"]["version"]],
        "ocaml": data["ocaml"]["versions"],
        **{
            language: [spec["version"]]
            for language, spec in data.get("nativeToolchains", {}).items()
        },
    }
    for language, releases in declared.items():
        if data["defaults"][language] not in releases:
            raise BootstrapError(
                f"Default {language} version is absent from the baseline"
            )
