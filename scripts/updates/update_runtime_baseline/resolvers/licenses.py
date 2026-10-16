"""Terms the bootstrap records as accepted, pinned by their reviewed text.

native-managers.nix pins each license by the hash its manager writes once a
person accepts it: for sdkmanager, the SHA-1 of the text in Google's
repository index, normalized the way sdkmanager reads it. A changed text is
drift: it is saved for review, and --accept-license records the hash of the
reviewed text, refusing if upstream changed it again since.
"""

import hashlib
import re
import xml.etree.ElementTree as ElementTree
from pathlib import Path

from .. import declarations
from ..declarations import PLATFORMS
from ..model import Edit, Finding, Kind, SourceError
from ..upstream import Source
from . import android, installers

# Java's \s, which sdkmanager's normalization matches.
SPACE = "[ \t\n\x0b\f\r]"
# What Java's String.trim removes: every character up to the space.
TRIMMED = "".join(map(chr, range(0x21)))


def sdkmanager_hash(text: str) -> str:
    """The hash sdkmanager records for a license text.

    Its TrimStringAdapter drops the blanks after any whitespace, joins lines
    that a single newline breaks, collapses spaces and trims the result.
    Checked against sdkmanager's own records: android-sdk-license
    24333f8a..., android-sdk-preview-license 84831b94... (October 2026).
    """
    text = re.sub(f"(?<={SPACE})[ \t]*", "", text)
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)
    text = re.sub(" +", " ", text)
    text = text.strip(TRIMMED)
    return hashlib.sha1(text.encode(), usedforsecurity=False).hexdigest()


def published(upstream: Source) -> dict[str, str]:
    """Every license text in the repository index, by its id."""
    try:
        root = ElementTree.fromstring(upstream.fetch(android.INDEX))
    except (ElementTree.ParseError, ValueError, TypeError) as error:
        raise SourceError(
            f"{android.INDEX}: not the repository index ({error})"
        ) from error
    texts = {}
    for license in root.iter("license"):
        if name := license.get("id"):
            texts[name] = license.text or ""
    return texts


def review_path(name: str, digest: str) -> Path:
    return (
        installers.review_directory().parent
        / "licenses"
        / f"{name}-{digest[:16]}.txt"
    )


def save_for_review(name: str, digest: str, text: str) -> Path:
    """Keep a text under its hash; a link there is replaced, not followed."""
    path = review_path(name, digest)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = text.encode()
    if path.is_symlink() or not path.is_file() or path.read_bytes() != data:
        declarations.replace_file(path, data, 0o600)
    return path


def text_of(texts: dict[str, str], name: str) -> str:
    if name not in texts:
        raise SourceError(f"{android.INDEX} lists no {name}")
    return texts[name]


def resolve(upstream: Source, baseline: dict, managers: dict) -> list:
    texts = published(upstream)
    found = []
    for name, pinned in sorted(managers.get("licenses", {}).items()):
        text = text_of(texts, name)
        digest = sdkmanager_hash(text)
        label = f"license {name}"
        if digest == pinned:
            found.append(Finding("licenses", label, pinned[:12]))
            continue
        note = f"review {save_for_review(name, digest, text)}"
        previous = review_path(name, pinned)
        if previous.exists():
            note += f" (diff against {previous})"
        found.append(
            Finding(
                "licenses",
                label,
                pinned[:12],
                digest[:12],
                Kind.DRIFT,
                f"{note}, then --accept-license {name}",
            )
        )
    return found


def accept(names: list[str], upstream: Source, managers: dict) -> None:
    """Record the hash of each reviewed text, if upstream still serves it."""
    pinned = managers.get("licenses", {})
    unknown = sorted(set(names) - set(pinned))
    if unknown:
        raise SourceError(
            f"no recorded license named {', '.join(unknown)}; "
            f"choose from {', '.join(sorted(pinned))}"
        )
    texts = published(upstream)
    edits, accepted = [], []
    for name in names:
        text = text_of(texts, name)
        digest = sdkmanager_hash(text)
        if digest == pinned[name]:
            print(f"license {name}: unchanged")
            continue
        path = review_path(name, digest)
        if not path.is_file() or path.read_bytes() != text.encode():
            path = save_for_review(name, digest, text)
            raise SourceError(
                f"license {name}: read {path} first; upstream serves a text "
                "nobody reviewed yet"
            )
        edits.append(
            Edit(
                declarations.MANAGERS,
                f'"{pinned[name]}"',
                f'"{digest}"',
                (
                    "licenses",
                    *(
                        f"bootstrap.{platform}.licenses"
                        for platform in PLATFORMS
                    ),
                ),
            )
        )
        accepted.append(name)
    if edits:
        declarations.apply_edits(edits)
    for name in accepted:
        print(f"license {name}: recorded the reviewed text's hash")
