"""The declared manifest for orchestration fixtures.

The Nix package supplies its generated manifest through DEVRESTORE_MANIFEST.
Source checks evaluate tests/manifest.nix instead, so the same contracts run
against the real policy without building any store asset.
"""

import functools
import json
import os
import subprocess
from pathlib import Path


@functools.cache
def declared_manifest():
    path = os.environ.get("DEVRESTORE_MANIFEST")
    if path:
        return json.loads(Path(path).read_text())
    try:
        output = subprocess.run(
            [
                "nix",
                "--extra-experimental-features",
                "nix-command",
                "eval",
                "--json",
                "--file",
                str(Path(__file__).with_name("manifest.nix")),
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError(
            "Setup contracts need the declared policy: install Nix or set "
            f"DEVRESTORE_MANIFEST ({error})"
        ) from error
    return json.loads(output)
