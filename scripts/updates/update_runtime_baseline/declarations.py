"""The Nix declarations the updater reads and rewrites.

Rewrites are exact text replacements, checked by evaluating the files again:
only the attribute paths an edit names may change.
"""

import json
import subprocess
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import Any

from .model import Edit, SourceError

ROOT = Path(__file__).resolve().parents[3]
BASELINE = ROOT / "home/dev/runtime-baseline.nix"
MANAGERS = ROOT / "home/dev/native-managers.nix"
PLATFORMS = ("aarch64-darwin", "x86_64-linux")


def evaluate(path: Path) -> Any:
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


def flatten(value: Any, prefix: str = "") -> dict[str, Any]:
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


def lookup(data: Any, path: str) -> Any:
    """The value at a dotted attribute path."""
    for key in path.split("."):
        data = data[key]
    return data


def within(path: str, scopes: Iterable[str]) -> bool:
    return any(path == s or path.startswith(s + ".") for s in scopes)


def baseline_edit(old: str, new: str, *scopes: str) -> Edit:
    return Edit(BASELINE, f'"{old}"', f'"{new}"', scopes)


def apply_edits(edits: Sequence[Edit], evaluate=evaluate) -> None:
    """Rewrite in place; restore every file unless only the scopes changed."""
    files = sorted({edit.path for edit in edits})
    originals = {path: path.read_text() for path in files}
    before = {path: flatten(evaluate(path)) for path in files}
    rewritten = dict(originals)
    for edit in edits:
        rewritten[edit.path] = edit.apply(rewritten[edit.path])
    try:
        for path in files:
            path.write_text(rewritten[path])
        for path in files:
            after = flatten(evaluate(path))
            scopes = [
                scope
                for edit in edits
                if edit.path == path
                for scope in edit.scopes
            ]
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
