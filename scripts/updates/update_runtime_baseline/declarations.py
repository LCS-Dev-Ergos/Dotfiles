"""The Nix declarations the updater reads and rewrites.

Rewrites are exact text replacements, checked by evaluating the files again:
only the attribute paths an edit names may change. A release read from an
upstream reaches a declaration only as a plain identifier, so no reply can
write Nix syntax. Files are replaced atomically.
"""

import contextlib
import copy
import json
import os
import re
import subprocess
import tempfile
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import Any

from .model import BlockEdit, Edit, Finding, SourceError
from .versions import numeric

ROOT = Path(__file__).resolve().parents[3]
BASELINE = ROOT / "home/dev/runtime-baseline.nix"
MANAGERS = ROOT / "home/dev/native-managers.nix"
PLATFORMS = ("aarch64-darwin", "x86_64-linux")
# The `retired` attribute set inside the baseline, as nixfmt lays it out.
RETIRED = re.compile(
    r"^(?P<indent> *)retired = (?:\{ \};|\{\n.*?^(?P=indent)\};)\n",
    re.MULTILINE | re.DOTALL,
)
RELEASE = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+_-]*")


def release_identifier(value: Any) -> str:
    """An upstream release, checked before it is written into Nix source."""
    if not isinstance(value, str) or not RELEASE.fullmatch(value):
        raise SourceError(f"not a release identifier: {value!r}")
    return value


def replace_file(path: Path, data: bytes, mode: int) -> None:
    """Replace `path` whole, or leave it as it was; a link is not followed."""
    descriptor, temporary = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}."
    )
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


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
    return Edit(BASELINE, f'"{old}"', f'"{release_identifier(new)}"', scopes)


def apply_edits(edits: Sequence[Edit | BlockEdit], evaluate=evaluate) -> None:
    """Rewrite in place; restore every file unless only the scopes changed."""
    files = sorted({edit.path for edit in edits})
    originals = {path: path.read_text(encoding="utf-8") for path in files}
    modes = {path: path.stat().st_mode & 0o777 for path in files}
    before = {path: flatten(evaluate(path)) for path in files}
    rewritten = dict(originals)
    # Exact replacements first; a block rendering then has the last word.
    for edit in sorted(edits, key=lambda edit: isinstance(edit, BlockEdit)):
        rewritten[edit.path] = edit.apply(rewritten[edit.path])
    try:
        for path in files:
            replace_file(path, rewritten[path].encode(), modes[path])
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
            replace_file(path, text.encode(), modes[path])
        raise


# Retired releases ---------------------------------------------------------------
# `retired` mirrors the declarations: each list holds the releases its path
# used to declare. `dev-bootstrap prune` removes them where still installed.


def render(value: Any, indent: str) -> str:
    """A retired value laid out as nixfmt formats it."""
    inner = indent + "  "
    if isinstance(value, list):
        for release in value:
            release_identifier(release)
        items = [json.dumps(r) for r in sorted(set(value), key=numeric)]
        if len(items) < 2:
            return f"[ {' '.join(items)} ]" if items else "[ ]"
        return "[\n" + "".join(f"{inner}{i}\n" for i in items) + f"{indent}]"
    if not value:
        return "{ }"
    lines = []
    for key in sorted(value):
        # A chain of single attributes collapses into one dotted path.
        path, child = key, value[key]
        while isinstance(child, dict) and len(child) == 1:
            ((name, child),) = child.items()
            path += f".{name}"
        lines.append(f"{inner}{path} = {render(child, inner)};\n")
    return "{\n" + "".join(lines) + f"{indent}}}"


def retire(retired: dict, path: str, release: str) -> None:
    *parents, name = path.split(".")
    for key in parents:
        retired = retired.setdefault(key, {})
    releases = retired.setdefault(name, [])
    if release not in releases:
        releases.append(release)


def retirement(
    baseline: dict, findings: Iterable[Finding]
) -> BlockEdit | None:
    """The `retired` block once the findings' pins are replaced.

    A release a finding declares again leaves the list; validate.nix rejects
    any other overlap, which restores the files.
    """
    retired = copy.deepcopy(baseline.get("retired", {}))
    moved = False
    for finding in findings:
        for path, release in finding.retires:
            retire(retired, path, release)
            moved = True
            try:
                lookup(retired, path).remove(finding.available)
            except ValueError:
                pass
    if not moved:
        return None
    match = RETIRED.search(BASELINE.read_text())
    if not match:
        raise SourceError(f"{BASELINE.name} declares no retired block")
    indent = match.group("indent")
    rendered = f"{indent}retired = {render(retired, indent)};\n"
    return BlockEdit(BASELINE, RETIRED, rendered, ("retired",))
