"""Posts and images, from the vault into the site.

The site's posts folder mirrors the vault's: a post the vault no longer has
is removed. Markdown is copied with Obsidian's image embeds rewritten for
Hugo (``![[chart.png|Alt text]]`` becomes ``![Alt text](/images/chart.png)``)
and each image a post shows is copied from the vault's images folder into
the site's static images. Images nothing points at stay: the site has its
own, such as its logo.

``plan`` reads both sides and writes nothing; ``apply`` refuses a plan with
problems, keeps a copy of every file it replaces or removes, then writes
each file through a temporary file and a rename. Hidden files and folders
are left alone on both sides, and a link in the vault is never followed, so
nothing outside the vault can reach the published site.
"""

import os
import re
import shutil
import stat
import tempfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

from .config import Config, ToolError

EMBED = re.compile(
    r"(?P<bang>!?)\[\[(?P<name>[^\[\]|#\n]+?"
    r"\.(?:png|jpe?g|gif|bmp|webp|svg|avif))"
    r"(?:\|(?P<label>[^\[\]\n]*))?\]\]",
    re.IGNORECASE,
)
"""An Obsidian link to an image, with an optional ``|label``."""

_SIZE = re.compile(r"\d+(?:x\d+)?")
_HUGO = (
    "hugo.toml",
    "hugo.yaml",
    "hugo.yml",
    "hugo.json",
    "config.toml",
    "config.yaml",
    "config.yml",
    "config.json",
)
_BACKUP = re.compile(r"\d{8}-\d{6}-.+")


@dataclass(frozen=True)
class Change:
    """One file to add, update or remove, relative to its folder."""

    kind: str
    area: str
    path: Path
    data: bytes | None = None


@dataclass
class Plan:
    """Everything a sync would do, and what stops it."""

    posts: int = 0
    changes: list[Change] = field(default_factory=list[Change])
    problems: list[str] = field(default_factory=list[str])
    skipped: list[str] = field(default_factory=list[str])

    def count(self, kind: str, area: str) -> int:
        """How many changes of a kind there are in an area."""
        return sum(c.kind == kind and c.area == area for c in self.changes)


def convert(text: str) -> tuple[str, list[str], list[str]]:
    """A post with its image embeds rewritten for Hugo.

    Returns the text, the image names it shows and the names that cannot
    be published (a folder in the name, or a hidden file). A ``|label``
    becomes the alternative text unless it is a size such as ``|300``;
    then the file's stem is. Embeds inside code blocks are rewritten too.
    """
    names: list[str] = []
    refused: list[str] = []

    def link(match: re.Match[str]) -> str:
        """The Markdown for one embed, or the embed itself if refused."""
        name = match["name"].strip()
        if "/" in name or "\\" in name or name.startswith("."):
            refused.append(name)
            return match[0]
        names.append(name)
        label = (match["label"] or "").strip()
        alt = Path(name).stem if not label or _SIZE.fullmatch(label) else label
        return f"{match['bang']}[{alt}](/images/{quote(name)})"

    return EMBED.sub(link, text), names, refused


def plan(config: Config) -> Plan:
    """What a sync would change, without writing anything.

    Raises:
        ToolError: If a folder is missing or unreadable, the site is not a
            Hugo site, or the vault holds no post at all, which is far
            likelier an unmounted or unsynced vault than an empty blog.
    """
    if not any((config.site / name).is_file() for name in _HUGO):
        raise ToolError(f"{config.site} is not a Hugo site")
    if _inside(config.posts, config.content) or _inside(
        config.content, config.posts
    ):
        raise ToolError(
            f"{config.posts} and {config.content} overlap; each sync would "
            "copy the site into itself"
        )
    result = Plan()
    source = _files(config.posts, result.skipped, "vault")
    result.posts = sum(path.suffix.lower() == ".md" for path in source)
    if not result.posts:
        raise ToolError(
            f"{config.posts} holds no posts; refusing to empty the site"
        )
    wanted: dict[str, str] = {}
    for relative, path in sorted(source.items()):
        data = _read(path)
        if path.suffix.lower() == ".md":
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                result.problems.append(f"{relative} is not UTF-8 text")
                continue
            text, names, refused = convert(text)
            data = text.encode("utf-8")
            for name in names:
                wanted.setdefault(name, str(relative))
            result.problems += [
                f"{relative} shows {name}; only a file name in the images "
                "folder can be published"
                for name in refused
            ]
        _compare(result, "posts", relative, data, config.content)
    target = (
        _files(config.content, None, "site") if config.content.exists() else {}
    )
    for relative in sorted(set(target) - set(source)):
        result.changes.append(Change("remove", "posts", relative))
    for name, post in sorted(wanted.items()):
        path = config.images / name
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            result.problems.append(f"{post} shows {name}, which is missing")
            continue
        except OSError as error:
            raise ToolError(f"Cannot read {path}: {error.strerror}") from error
        if not stat.S_ISREG(mode):
            result.problems.append(f"{name} is a link or not a file")
            continue
        data = _read(path)
        _compare(result, "images", Path(name), data, config.static)
    return result


def _files(
    root: Path, skipped: list[str] | None, side: str
) -> dict[Path, Path]:
    """The files below a folder, by relative path; hidden ones left out.

    With ``skipped``, only regular files count and links and special files
    are listed there; without it, links count too, so a stray link in the
    site can be removed.

    Raises:
        ToolError: If the folder is missing or a folder cannot be listed.
    """
    if not root.is_dir():
        raise ToolError(f"The {side} folder {root} does not exist")
    found: dict[Path, Path] = {}

    def failed(error: OSError) -> None:
        """Stop the walk on a folder that cannot be listed."""
        raise ToolError(f"Cannot list {error.filename}: {error.strerror}")

    for directory, folders, names in os.walk(root, onerror=failed):
        here = Path(directory)
        kept = []
        for name in sorted(folders):
            if name.startswith("."):
                continue
            if (here / name).is_symlink():
                if skipped is None:
                    found[(here / name).relative_to(root)] = here / name
                else:
                    skipped.append(str((here / name).relative_to(root)))
                continue
            kept.append(name)
        folders[:] = kept
        for name in sorted(names):
            if name.startswith("."):
                continue
            path = here / name
            mode = path.lstat().st_mode
            if stat.S_ISREG(mode) or (skipped is None and stat.S_ISLNK(mode)):
                found[path.relative_to(root)] = path
            elif skipped is not None:
                skipped.append(str(path.relative_to(root)))
    return found


def _read(path: Path) -> bytes:
    """A vault file's bytes; a link is refused, not read.

    A file replaced by a link after the walk still cannot pull another file
    into the site.

    Raises:
        ToolError: If it cannot be read.
    """
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as handle:
            return handle.read()
    except OSError as error:
        raise ToolError(f"Cannot read {path}: {error.strerror}") from error


def _inside(path: Path, folder: Path) -> bool:
    """Whether a path is the folder or below it, once links are resolved."""
    return path.resolve().is_relative_to(folder.resolve())


def _compare(
    result: Plan, area: str, relative: Path, data: bytes, root: Path
) -> None:
    """Add a change when the target is missing or holds other bytes.

    A folder in the site that is a link leading out of it is a problem:
    writing through it would put the file somewhere else.
    """
    target = root / relative
    if not _inside(target.parent, root):
        result.problems.append(
            f"{area}/{relative.parent} in the site is a link out of it"
        )
        return
    if target.is_symlink() or not target.exists():
        kind = "update" if target.is_symlink() else "add"
    elif target.is_file() and target.read_bytes() == data:
        return
    else:
        kind = "update"
    result.changes.append(Change(kind, area, relative, data))


# Applying ---------------------------------------------------------------------


def apply(result: Plan, config: Config, state: Path) -> Path | None:
    """Carry out a plan; the folder holding the replaced files, if any.

    Raises:
        ToolError: If the plan has problems or a file cannot be written;
            the files written before it stay, and the copies hold the rest.
    """
    if result.problems:
        raise ToolError(
            "Nothing was synced: "
            + plural(len(result.problems), "problem")
            + " must be fixed first"
        )
    roots = {"posts": config.content, "images": config.static}
    backup = _backup(result, roots, state / "backups", config.backups)
    try:
        for change in result.changes:
            target = roots[change.area] / change.path
            if change.kind == "remove":
                _remove(target, roots[change.area])
            else:
                _write(target, change.data or b"")
    except OSError as error:
        name = error.filename or "a file"
        raise ToolError(f"Cannot write {name}: {error.strerror}") from error
    return backup


def _backup(
    result: Plan, roots: dict[str, Path], folder: Path, keep: int
) -> Path | None:
    """Copy every file about to be replaced or removed; keep ``keep`` runs.

    Raises:
        ToolError: If the copies cannot be made, before anything changes.
    """
    replaced = [
        change
        for change in result.changes
        if change.kind != "add"
        and (roots[change.area] / change.path).is_file()
        and not (roots[change.area] / change.path).is_symlink()
    ]
    if not replaced or not keep:
        return None
    try:
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S-")
        backup = Path(tempfile.mkdtemp(prefix=stamp, dir=folder))
        for change in replaced:
            copy = backup / change.area / change.path
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(roots[change.area] / change.path, copy)
        runs = sorted(p for p in folder.iterdir() if _BACKUP.fullmatch(p.name))
        for old in runs[:-keep]:
            shutil.rmtree(old)
    except OSError as error:
        raise ToolError(
            f"Cannot keep a copy of the replaced files: {error.strerror}; "
            "nothing was synced"
        ) from error
    return backup


def _write(target: Path, data: bytes) -> None:
    """Replace a file through a temporary file beside it."""
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        os.chmod(name, 0o666 & ~_umask())
        os.replace(name, target)
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise


def _remove(target: Path, root: Path) -> None:
    """Remove a file or link, then any folders it leaves empty."""
    target.unlink(missing_ok=True)
    folder = target.parent
    while folder != root and root in folder.parents:
        try:
            folder.rmdir()
        except OSError:
            return
        folder = folder.parent


def _umask() -> int:
    """The process umask, read without changing it for long."""
    current = os.umask(0o022)
    os.umask(current)
    return current


def plural(count: int, noun: str) -> str:
    """``1 post`` or ``n posts``."""
    return f"{count} {noun}{'' if count == 1 else 's'}"
