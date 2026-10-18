"""Bookmarks: read as a tree of page numbers, written back to any PDF.

A bookmark points at a page object, directly, through a GoTo action or
through a named destination. Reading resolves each to a page number and
keeps the view after it (``/XYZ left top zoom``, ``/Fit``); writing turns
the number into the target document's page, so bookmarks survive copying,
merging and removing pages. A bookmark whose page is gone is dropped, unless
it still holds others.
"""

from collections.abc import Callable
from dataclasses import dataclass, field

import pikepdf

MAX_DEPTH = 32
"""How deep a bookmark tree is followed; a crafted file can nest forever."""


@dataclass
class Mark:
    """One bookmark: its title, its page (zero-based) and its view."""

    title: str
    page: int | None
    view: list[object] = field(default_factory=list[object])
    children: list["Mark"] = field(default_factory=list["Mark"])

    def count(self) -> int:
        """This bookmark and every one beneath it."""
        return 1 + sum(child.count() for child in self.children)


def read(pdf: pikepdf.Pdf) -> list[Mark]:
    """The document's bookmarks, resolved to page numbers."""
    if "/Outlines" not in pdf.Root:
        return []
    pages = {page.obj.objgen: index for index, page in enumerate(pdf.pages)}
    outline = pikepdf.Outline(pdf, max_depth=MAX_DEPTH)
    return [_mark(pdf, item, pages, 0) for item in outline.root]


def _mark(
    pdf: pikepdf.Pdf,
    item: pikepdf.OutlineItem,
    pages: dict[tuple[int, int], int],
    depth: int,
) -> Mark:
    """One outline item and its children as a Mark."""
    target = item.destination
    action = item.action
    if target is None and isinstance(action, pikepdf.Dictionary):
        if action.get("/S") == pikepdf.Name.GoTo:
            target = action.get("/D")
    if isinstance(target, pikepdf.Name | pikepdf.String):
        target = _named(pdf, target)
    if isinstance(target, pikepdf.Dictionary):
        target = target.get("/D")
    page: int | None = None
    view: list[object] = []
    if isinstance(target, pikepdf.Array) and len(target):
        first = target[0]
        if isinstance(first, pikepdf.Dictionary):
            page = pages.get(first.objgen)
        elif isinstance(first, int) and 0 <= first < len(pdf.pages):
            page = first
        view = [
            value
            for value in list(target)[1:]
            if not getattr(value, "is_indirect", False)
        ]
    children = []
    if depth < MAX_DEPTH:
        children = [
            _mark(pdf, child, pages, depth + 1) for child in item.children
        ]
    return Mark(str(item.title), page, view, children)


def _named(pdf: pikepdf.Pdf, name: pikepdf.Object) -> pikepdf.Object | None:
    """A named destination, from the name tree or the older dictionary."""
    key = str(name)
    if isinstance(name, pikepdf.Name):
        key = key.removeprefix("/")
    names = pdf.Root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/Dests" in names:
        tree = pikepdf.NameTree(names.Dests)
        if key in tree:
            return tree[key]
    dests = pdf.Root.get("/Dests")
    if isinstance(dests, pikepdf.Dictionary):
        return dests.get(f"/{key}")
    return None


def write(
    pdf: pikepdf.Pdf,
    marks: list[Mark],
    page_of: Callable[[int], int | None] = lambda page: page,
) -> tuple[int, int]:
    """Replace the document's bookmarks; how many were written and dropped.

    The old outline is removed first rather than edited, so a malformed
    one cannot get in the way.

    ``page_of`` maps a bookmark's page to the page it lands on in ``pdf``,
    or to None when that page is not there.
    """
    counts = [0, 0]
    items = _items(pdf, marks, page_of, counts)
    if "/Outlines" in pdf.Root:
        del pdf.Root.Outlines
    with pdf.open_outline(max_depth=MAX_DEPTH) as outline:
        outline.root.extend(items)
    return counts[0], counts[1]


def _items(
    pdf: pikepdf.Pdf,
    marks: list[Mark],
    page_of: Callable[[int], int | None],
    counts: list[int],
) -> list[pikepdf.OutlineItem]:
    """Outline items for marks whose page, or a descendant's, exists."""
    items = []
    for mark in marks:
        children = _items(pdf, mark.children, page_of, counts)
        page = page_of(mark.page) if mark.page is not None else None
        if page is None or not 0 <= page < len(pdf.pages):
            if not children:
                counts[1] += 1
                continue
            item = pikepdf.OutlineItem(mark.title)
        else:
            view = mark.view or [pikepdf.Name.Fit]
            target = pikepdf.Array([pdf.pages[page].obj, *view])
            item = pikepdf.OutlineItem(mark.title, target)
        item.children.extend(children)
        items.append(item)
        counts[0] += 1
    return items


def flatten(marks: list[Mark], depth: int = 0) -> list[tuple[int, Mark]]:
    """Every bookmark with its depth, in reading order."""
    rows = []
    for mark in marks:
        rows.append((depth, mark))
        rows += flatten(mark.children, depth + 1)
    return rows
