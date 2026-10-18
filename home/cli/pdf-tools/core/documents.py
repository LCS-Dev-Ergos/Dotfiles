"""Opening and saving PDFs, choosing outputs and reading page selections.

Every write goes to a private temporary file in the destination folder,
which then replaces the destination in one rename: an interrupted or failed
run leaves the old file, never half a new one. An existing file is replaced
only with ``--force``, and the input only with ``--in-place``, which keeps
its permissions.
"""

import os
import re
import stat
import tempfile
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

import pikepdf


class ToolError(Exception):
    """A failure the user can act on; the command exits with ``status``."""

    status = 1


class Locked(ToolError):
    """A PDF that opens only with its password."""


class UsageError(ToolError):
    """Arguments that do not fit the document, such as page 12 of 10."""

    status = 2


def open_pdf(path: Path, password: str = "") -> pikepdf.Pdf:
    """Open a PDF for reading and editing.

    A PDF locked with a user password opens only with that password; one
    restricted by an owner password alone opens, and saving keeps the
    restriction.

    Raises:
        ToolError: If the file is missing, locked or not a readable PDF.
    """
    _require_file(path)
    try:
        return pikepdf.open(path, password=password)
    except pikepdf.PasswordError as error:
        if password:
            raise ToolError(f"Wrong password for {path}") from error
        raise Locked(
            f"{path} is locked with a password; pdf-tools unlock opens it"
        ) from error
    except pikepdf.PdfError as error:
        raise ToolError(
            f"{path} is not a readable PDF: {first_line(error)}"
        ) from error


def unrestricted(pdf: pikepdf.Pdf) -> None:
    """Refuse a protected PDF for a task whose output cannot keep that.

    Only a save of the same document keeps an owner password; a new
    document, or one Ghostscript rewrites, would come out unprotected.

    Raises:
        ToolError: If the PDF has an owner password.
    """
    if pdf.is_encrypted:
        raise ToolError(
            f"{pdf.filename} has an owner password, which this command "
            "would drop; pdf-tools unlock removes it first"
        )


def _require_file(path: Path) -> None:
    """Refuse a path that is not a regular file, before any parser runs.

    Raises:
        ToolError: If the path is missing or not a regular file.
    """
    try:
        mode = path.stat().st_mode
    except FileNotFoundError as error:
        raise ToolError(f"{path} does not exist") from error
    except OSError as error:
        raise ToolError(f"Cannot read {path}: {error.strerror}") from error
    if not stat.S_ISREG(mode):
        raise ToolError(f"{path} is not a regular file")


def first_line(error: Exception) -> str:
    """An exception's message, first line only."""
    lines = str(error).strip().splitlines()
    return lines[0] if lines else type(error).__name__


# Outputs ----------------------------------------------------------------------


def destination(
    source: Path,
    suffix: str,
    output: Path | None,
    *,
    in_place: bool = False,
    extension: str = ".pdf",
) -> Path:
    """Where a command writes: ``--output``, the input, or a derived name.

    The derived name sits next to the input: ``book.pdf`` becomes
    ``book_<suffix>.pdf``. In place, a symbolic link is followed, so the
    file it points at is replaced rather than the link.
    """
    if in_place:
        return source.resolve()
    if output is not None:
        return output
    return source.with_name(f"{source.stem}_{suffix}{extension}")


def check_target(
    target: Path,
    *,
    force: bool,
    in_place: bool = False,
    sources: tuple[Path, ...] = (),
) -> None:
    """Refuse a destination that would lose data, before any work is done.

    Raises:
        ToolError: If the destination exists without ``--force``, is an
            input without ``--in-place``, or has no folder to go in.
    """
    if in_place:
        return
    if not target.absolute().parent.is_dir():
        raise ToolError(f"The folder for {target} does not exist")
    if not target.exists():
        return
    if target.is_dir():
        raise ToolError(f"{target} is a folder")
    for source in sources:
        if source.exists() and os.path.samefile(source, target):
            raise ToolError(
                f"{target} is an input; --in-place replaces it on purpose"
            )
    if not force:
        raise ToolError(f"{target} exists; --force replaces it")


@contextmanager
def replacing(
    target: Path, *, keep_mode_of: Path | None = None
) -> Generator[Path]:
    """A temporary path beside ``target`` that replaces it on success.

    The temporary file is private while it is written. On success it takes
    the mode of ``keep_mode_of`` (the file an in-place edit replaces), or
    the mode a new file would get, and then replaces ``target``. On any
    failure it is removed and ``target`` is untouched.
    """
    target = target.absolute()
    descriptor, name = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
    )
    os.close(descriptor)
    temporary = Path(name)
    try:
        yield temporary
        if keep_mode_of is not None:
            mode = stat.S_IMODE(keep_mode_of.stat().st_mode)
        else:
            mode = 0o666 & ~_umask()
        temporary.chmod(mode)
        os.replace(temporary, target)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _umask() -> int:
    """The process umask, read without changing it for long."""
    current = os.umask(0o022)
    os.umask(current)
    return current


def save(
    pdf: pikepdf.Pdf,
    target: Path,
    *,
    keep_mode_of: Path | None = None,
    encryption: pikepdf.Encryption | bool | None = None,
    **options: object,
) -> None:
    """Save a PDF to ``target`` through a temporary file.

    ``encryption`` None keeps whatever protection the document had: pikepdf
    would otherwise drop an owner password silently.

    Raises:
        ToolError: If the PDF cannot be written.
    """
    if encryption is None:
        encryption = pdf.is_encrypted
    try:
        with replacing(target, keep_mode_of=keep_mode_of) as temporary:
            pdf.save(temporary, encryption=encryption, **options)
    except (OSError, pikepdf.PdfError) as error:
        raise ToolError(
            f"Cannot write {target}: {first_line(error)}"
        ) from error


def lossless(*, linearize: bool = False) -> dict[str, object]:
    """Save options that shrink a file without changing how it looks.

    Streams are recompressed at the best Flate level and small objects are
    packed into object streams; ``linearize`` orders the file for viewing
    page by page while it downloads.
    """
    return {
        "compress_streams": True,
        "recompress_flate": True,
        "object_stream_mode": pikepdf.ObjectStreamMode.generate,
        "linearize": linearize,
    }


def size(path: Path) -> int:
    """A file's size in bytes, 0 when it cannot be read."""
    try:
        return path.stat().st_size
    except OSError:
        return 0


# Page selections --------------------------------------------------------------

_RANGE = re.compile(r"([0-9]{1,9}|z|last)(?:-([0-9]{1,9}|z|last))?")


def parse_pages(spec: str, count: int) -> list[int]:
    """The zero-based pages a selection names, in its order.

    A selection is a comma-separated list of pages and ranges, counted from
    1: ``1-5,8,10-z``. ``z`` or ``last`` is the last page; a descending
    range (``5-1``) runs backwards, and a page may appear more than once.

    Raises:
        UsageError: If the selection is malformed or names a missing page.
    """
    pages: list[int] = []
    for part in spec.replace(" ", "").split(","):
        if not part:
            raise UsageError("The page selection has an empty part")
        match = _RANGE.fullmatch(part)
        if match is None:
            raise UsageError(f"Not a page or range: {part}")
        first = _page(match[1], count)
        last = _page(match[2], count) if match[2] else first
        step = 1 if last >= first else -1
        pages += range(first, last + step, step)
    return pages


def _page(token: str, count: int) -> int:
    """One page number of a selection, zero-based.

    Raises:
        UsageError: If the page is outside the document.
    """
    number = count if token in ("z", "last") else int(token)
    if not 1 <= number <= count:
        raise UsageError(
            f"Page {number} is outside the document, which has "
            f"{count} page{'s' if count != 1 else ''}"
        )
    return number - 1


def compact(pages: list[int]) -> str:
    """Zero-based pages written back as a selection: ``1-3,7``."""
    parts: list[str] = []
    start = previous = None
    for page in pages:
        if previous is not None and page == previous + 1:
            previous = page
            continue
        if start is not None:
            parts.append(_span(start, previous))
        start = previous = page
    if start is not None:
        parts.append(_span(start, previous))
    return ",".join(parts)


def _span(start: int, end: int | None) -> str:
    """A run of pages, counted from 1."""
    if end is None or end == start:
        return str(start + 1)
    return f"{start + 1}-{end + 1}"


def copy_pages(
    source: pikepdf.Pdf, order: list[int], target: pikepdf.Pdf
) -> None:
    """Append the source's pages to ``target`` in ``order``."""
    for index in order:
        target.pages.append(source.pages[index])
