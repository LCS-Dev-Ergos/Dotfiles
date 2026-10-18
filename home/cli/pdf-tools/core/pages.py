"""Page operations: extract, delete, rotate, merge and split.

A new document built from chosen pages keeps the source's document
information and those bookmarks whose pages it still holds, so an excerpt
stays navigable.
"""

from collections.abc import Sequence
from contextlib import ExitStack
from pathlib import Path

import pikepdf

from . import outline
from .documents import UsageError, copy_pages, open_pdf, unrestricted

ANGLES = {
    "right": 90,
    "r": 90,
    "90": 90,
    "left": -90,
    "l": -90,
    "-90": -90,
    "270": -90,
    "180": 180,
    "-180": 180,
}
"""Rotation words and the clockwise angle each means."""


def rebuild(source: pikepdf.Pdf, order: list[int]) -> pikepdf.Pdf:
    """A new PDF of the source's pages in ``order``.

    It keeps the document information, the XMP metadata and every bookmark
    whose page is among them; a page chosen twice takes its bookmarks at
    its first appearance.

    Raises:
        ToolError: If the source has an owner password, which a new
            document cannot carry over.
    """
    unrestricted(source)
    result = pikepdf.new()
    copy_pages(source, order, result)
    if "/Info" in source.trailer:
        result.docinfo = result.copy_foreign(source.docinfo)
    if "/Metadata" in source.Root:
        result.Root.Metadata = result.copy_foreign(source.Root.Metadata)
    first: dict[int, int] = {}
    for new, old in enumerate(order):
        first.setdefault(old, new)
    marks = outline.read(source)
    if marks:
        outline.write(result, marks, first.get)
    return result


def without(count: int, removed: list[int]) -> list[int]:
    """The pages that remain after removing some.

    Raises:
        UsageError: If no page would remain.
    """
    gone = set(removed)
    order = [page for page in range(count) if page not in gone]
    if not order:
        raise UsageError("That removes every page; nothing would remain")
    return order


def rotate(pdf: pikepdf.Pdf, angle: int, pages: list[int]) -> None:
    """Turn pages clockwise by ``angle``, on top of their current turn."""
    for index in dict.fromkeys(pages):
        pdf.pages[index].rotate(angle, relative=True)


def merge(
    paths: Sequence[Path], stack: ExitStack, *, bookmarks: bool = True
) -> pikepdf.Pdf:
    """One PDF of every input's pages, in order.

    With ``bookmarks``, each input gets a bookmark named after its file,
    holding the bookmarks it had. The inputs stay open on ``stack`` until
    the result is saved, since pages are copied lazily.

    Raises:
        ToolError: If an input cannot be opened or has an owner password.
    """
    result = pikepdf.new()
    marks: list[outline.Mark] = []
    for path in paths:
        source = stack.enter_context(open_pdf(path))
        unrestricted(source)
        offset = len(result.pages)
        copy_pages(source, list(range(len(source.pages))), result)
        if bookmarks and len(source.pages):
            inner = _shifted(outline.read(source), offset)
            marks.append(outline.Mark(path.stem, offset, [], inner))
    if marks:
        outline.write(result, marks)
    return result


def _shifted(marks: list[outline.Mark], offset: int) -> list[outline.Mark]:
    """Bookmarks moved down by ``offset`` pages."""
    return [
        outline.Mark(
            mark.title,
            None if mark.page is None else mark.page + offset,
            mark.view,
            _shifted(mark.children, offset),
        )
        for mark in marks
    ]


def parts(count: int, every: int | None, starts: list[int]) -> list[list[int]]:
    """The pages of each part of a split.

    ``every`` cuts after each N pages; ``starts`` lists the zero-based pages
    that begin a new part. Without either, every page is its own part.
    """
    if starts:
        bounds = sorted({0, *starts, count})
        return [
            list(range(start, end))
            for start, end in zip(bounds, bounds[1:], strict=False)
            if start < end
        ]
    size = every or 1
    return [
        list(range(start, min(start + size, count)))
        for start in range(0, count, size)
    ]
