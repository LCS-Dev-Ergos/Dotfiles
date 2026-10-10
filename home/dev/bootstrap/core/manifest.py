"""Validate the Nix-generated baseline before constructing runtime adapters."""

import json
import re

from .adapters import ADAPTERS, TOOLCHAINS
from .adapters.base import PLATFORMS
from .errors import BootstrapError


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


def validate_toolchains(data):
    for language, spec in data.get("nativeToolchains", {}).items():
        if language not in TOOLCHAINS:
            raise BootstrapError("Unsupported native toolchain")
        TOOLCHAINS[language].validate_declaration(spec)
    for spec in data.get("setup", {}).get("installers", {}).values():
        if not spec["url"].startswith("https://") or not re.fullmatch(
            r"[a-f0-9]{64}", spec["sha256"]
        ):
            raise BootstrapError(
                "Native installers require HTTPS and an exact SHA256"
            )
        size = spec.get("size", 1)
        if type(size) is not int or size <= 0:
            raise BootstrapError(
                "Installer sizes must be positive byte counts"
            )
        if spec.get("format", "gzip") != "gzip":
            raise BootstrapError("Unsupported installer format")


# Retired releases reach manager arguments and paths below a manager root.
RETIRED_RELEASE = re.compile(r"[0-9][0-9A-Za-z.+_-]*")


def validate_retired(retired):
    """Every retired release is an exact identifier, at any depth."""
    if not isinstance(retired, dict):
        raise BootstrapError("Retired releases must mirror the declarations")
    for value in retired.values():
        if isinstance(value, dict):
            validate_retired(value)
        elif not isinstance(value, list) or not all(
            isinstance(release, str) and RETIRED_RELEASE.fullmatch(release)
            for release in value
        ):
            raise BootstrapError("Retired releases must be exact identifiers")


def validate_manifest(data):
    """Reject malformed declarations at the input boundary, before any work."""
    if data["schema"] != 1 or data["backend"] not in ("native", "nixpkgs"):
        raise BootstrapError("Unsupported baseline schema or backend")
    if data["platform"] not in PLATFORMS:
        raise BootstrapError("No bootstrap adapter for this platform")
    versions = [version(release) for release in data["node"]["versions"]]
    if len(set(versions)) != len(versions):
        raise BootstrapError("Duplicate Node identity")
    version(data["python"]["version"])
    for release in data["ocaml"]["versions"]:
        version(release)
    validate_toolchains(data)
    validate_retired(data.get("retired", {}))
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
        for required in ADAPTERS[language].requires:
            if required not in declared:
                raise BootstrapError(
                    f"{language} requires {required}, which is not declared"
                )
