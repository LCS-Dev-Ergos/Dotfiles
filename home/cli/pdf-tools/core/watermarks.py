"""Watermark removal: find repeated overlays and cut them from the content.

Pages are read as content-stream operators, never rasterized. Three kinds
of block are candidates: a small stream that only draws text or a form (an
overlay appended to each page), a text block, and a drawn XObject. Blocks
are clustered across pages by their operators, position, form and masked
text, then scored: repetition, a stable position, transparency, rotation,
text the user named, a form container. Only a cluster with a strong
watermark cue and a high score is removed; the rest is reported.

Removal keeps the page's drawing state intact. A block wrapped in ``q`` and
``Q`` goes whole; from an unwrapped block only the operators that draw are
cut, so a colour, font or transformation that later content relies on
stays. A whole stream is dropped only when nothing after it can depend on
it.
"""

import hashlib
import re
import statistics
from collections import Counter, defaultdict
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from enum import Enum

import pikepdf

from .documents import first_line

TEXT_SHOW = {b"Tj", b"TJ", b"'", b'"'}
DRAW_XOBJECT = b"Do"
INLINE_IMAGE = b"BI"
MODIFIERS = {
    b"cm",
    b"gs",
    b"g",
    b"G",
    b"rg",
    b"RG",
    b"k",
    b"K",
    b"cs",
    b"CS",
    b"sc",
    b"SC",
    b"scn",
    b"SCN",
    b"w",
    b"J",
    b"j",
    b"M",
    b"d",
    b"ri",
    b"i",
}
"""Graphics-state operators that may precede a draw and belong to it."""

PERSISTENT = MODIFIERS | {
    b"q",
    b"Q",
    b"Tf",
    b"Tc",
    b"Tw",
    b"Tz",
    b"TL",
    b"Ts",
    b"Tr",
}
"""Operators whose effect outlives a block that is not wrapped in q/Q."""

PATHS = {b"m", b"l", b"c", b"v", b"y", b"re", b"h", b"S", b"s", b"f"}
PATHS |= {b"F", b"f*", b"B", b"B*", b"b", b"b*", b"n", INLINE_IMAGE}
"""Operators that draw page content, never found in a pure overlay."""

MAX_ISOLATED_OPS = 48
MAX_WRAPPED_DO_OPS = 24
MIN_REPEAT = 0.5

Matrix = tuple[float, float, float, float, float, float]
Operation = tuple[list[object], bytes]


class Kind(Enum):
    """The kind of block a candidate is."""

    STREAM = "stream"
    TEXT = "text block"
    XOBJECT = "drawn object"


class Confidence(Enum):
    """How sure the scoring is that a cluster is a watermark."""

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


@dataclass(frozen=True)
class Box:
    """A rectangle in PDF user space."""

    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def width(self) -> float:
        """The width, never negative."""
        return max(0.0, self.x1 - self.x0)

    @property
    def height(self) -> float:
        """The height, never negative."""
        return max(0.0, self.y1 - self.y0)


@dataclass
class Form:
    """What a drawn XObject holds, analysed once per object."""

    subtype: str
    text: str
    signature: str
    preview: str
    box: Box | None
    matrix: Matrix | None


@dataclass
class Occurrence:
    """One candidate block on one page."""

    page: int
    stream: int
    streams: int
    kind: Kind
    start: int
    end: int
    total: int
    signature: str
    preview: str
    position: str
    position_preview: str
    text: str
    pattern: str
    matches: list[str]
    transparent: bool
    rotated: bool
    form: bool
    form_key: str
    box: Box | None

    @property
    def whole_stream(self) -> bool:
        """Whether the block is its stream's entire content."""
        return self.start == 0 and self.end == self.total

    @property
    def at_edge(self) -> bool:
        """Whether it is drawn near the start or end of the page.

        A page with one stream counts as both: its only stream is first.
        """
        order = self.start / max(self.total, 1)
        stream = self.stream / max(self.streams - 1, 1)
        return not 0.15 < order < 0.85 or not 0.15 < stream < 0.85

    @property
    def ops(self) -> int:
        """How many operators the block spans."""
        return self.end - self.start


@dataclass
class Cluster:
    """Repeated occurrences judged together."""

    number: int
    kind: Kind
    occurrences: list[Occurrence]
    pages: list[int]
    coverage: float
    score: int
    confidence: Confidence
    remove: bool
    reasons: list[str]
    preview: str
    position: str
    texts: list[str]
    matches: list[str]

    def to_json(self) -> dict[str, object]:
        """The cluster for the JSON report; pages counted from 1."""
        return {
            "id": self.number,
            "kind": self.kind.value,
            "pages": [page + 1 for page in self.pages],
            "coverage": round(self.coverage, 4),
            "occurrences": len(self.occurrences),
            "score": self.score,
            "confidence": self.confidence.value,
            "decision": "remove" if self.remove else "keep",
            "operators": self.preview,
            "position": self.position,
            "texts": self.texts,
            "matches": self.matches,
            "reasons": self.reasons,
        }


@dataclass
class Analysis:
    """Every cluster of a document, worth removing first."""

    pages: int
    clusters: list[Cluster]
    warnings: list[str] = field(default_factory=list[str])

    @property
    def selected(self) -> list[Cluster]:
        """The clusters chosen for removal."""
        return [cluster for cluster in self.clusters if cluster.remove]


@dataclass
class Applied:
    """What the removal changed."""

    pages: int = 0
    removed: int = 0
    redacted: int = 0
    warnings: list[str] = field(default_factory=list[str])


# Text and signatures ----------------------------------------------------------


def normalize(text: str) -> str:
    """Whitespace collapsed to single spaces."""
    return re.sub(r"\s+", " ", text).strip()


def compact(text: str) -> str:
    """Lowercase text without any whitespace."""
    return re.sub(r"\s+", "", text).lower()


def matches(text: str, needle: str) -> bool:
    """Whether text contains a phrase, ignoring case and spacing."""
    return normalize(needle).lower() in normalize(text).lower() or (
        compact(needle) in compact(text)
    )


def sample(text: str, limit: int = 100) -> str:
    """A shortened display sample."""
    text = normalize(text)
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def digest(parts: Iterable[str]) -> str:
    """A short stable hash for grouping."""
    joined = "\x1f".join(parts).encode("utf-8", "ignore")
    return hashlib.sha1(joined, usedforsecurity=False).hexdigest()[:12]


def signature(operations: Sequence[Operation]) -> tuple[str, str]:
    """A hash of an operator sequence and a readable preview of it."""
    names = [op.decode("latin-1") for _, op in operations]
    preview = names[:14]
    if len(names) > 14:
        preview += ["…", *names[-4:]]
    return digest(names), " ".join(preview) or "<empty>"


def _string(value: object) -> str | None:
    """The text of a string operand, or None for anything else."""
    if isinstance(value, str):
        return value
    if isinstance(value, pikepdf.String):
        return str(value)
    return None


def text_of(operations: Sequence[Operation]) -> str:
    """The text that the text-showing operators draw."""
    fragments: list[str] = []
    for operands, op in operations:
        if not operands:
            continue
        if op == b"Tj":
            fragments.append(_string(operands[0]) or "")
        elif op == b"TJ":
            items = operands[0]
            if isinstance(items, Iterable) and not isinstance(items, str):
                fragments += [_string(item) or "" for item in items]
            fragments.append(" ")
        elif op in (b"'", b'"'):
            fragments += ["\n", _string(operands[-1]) or ""]
    return normalize("".join(fragments))


def mask(text: str) -> str:
    """Text with ids and long words masked, so variants cluster."""
    masked = []
    for token in re.findall(r"\w+|[^\w\s]", text.lower())[:30]:
        if re.search(r"\d", token):
            masked.append("<id>")
        elif token.isalpha():
            masked.append(token if len(token) <= 3 else "<word>")
        else:
            masked.append(token)
    return " ".join(masked)


# Geometry ---------------------------------------------------------------------


def number(value: object, default: float = 0.0) -> float:
    """A PDF number as a float, or the default."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def matrix_of(value: object) -> Matrix | None:
    """A six-number transformation matrix, when the value is one."""
    if not isinstance(value, Iterable) or isinstance(value, str | bytes):
        return None
    items = list(value)
    if len(items) != 6:
        return None
    a, b, c, d, e, f = (number(item) for item in items)
    return a, b, c, d, e, f


def box_of(value: object) -> Box | None:
    """A rectangle from four numbers, corners in either order."""
    if not isinstance(value, Iterable) or isinstance(value, str | bytes):
        return None
    items = [number(item) for item in value]
    if len(items) != 4:
        return None
    x0, y0, x1, y1 = items
    return Box(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))


def transform(box: Box, outer: Matrix | None, inner: Matrix | None) -> Box:
    """A box through an inner, then an outer, matrix."""
    points = []
    for x, y in ((box.x0, box.y0), (box.x1, box.y0), (box.x1, box.y1)):
        points.append(_apply(outer, *_apply(inner, x, y)))
    points.append(_apply(outer, *_apply(inner, box.x0, box.y1)))
    xs = [x for x, _ in points]
    ys = [y for _, y in points]
    return Box(min(xs), min(ys), max(xs), max(ys))


def _apply(matrix: Matrix | None, x: float, y: float) -> tuple[float, float]:
    """A point through a matrix, or unchanged without one."""
    if matrix is None:
        return x, y
    a, b, c, d, e, f = matrix
    return a * x + c * y + e, b * x + d * y + f


def rotated(matrix: Matrix | None) -> bool:
    """Whether a matrix rotates or skews."""
    return matrix is not None and (
        abs(matrix[1]) > 0.01 or abs(matrix[2]) > 0.01
    )


def matrix_position(
    matrix: Matrix | None, width: float, height: float
) -> tuple[str, str]:
    """A grouping key and a preview from a matrix, relative to the page."""
    if matrix is None:
        return "unknown", "unknown"
    a, b, c, d, e, f = matrix
    x, y = round(e / max(width, 1.0), 2), round(f / max(height, 1.0), 2)
    key = (
        f"mx={round(a, 2)},my={round(d, 2)},"
        f"sk={round(b, 2)}/{round(c, 2)},tx={x},ty={y}"
    )
    return key, f"x={x}, y={y}, rotated={'yes' if rotated(matrix) else 'no'}"


def box_position(
    box: Box | None, width: float, height: float
) -> tuple[str, str]:
    """A grouping key and a preview from a box, relative to the page."""
    if box is None:
        return "unknown", "unknown"
    x = round(box.x0 / max(width, 1.0), 2)
    y = round(box.y0 / max(height, 1.0), 2)
    w = round(box.width / max(width, 1.0), 2)
    h = round(box.height / max(height, 1.0), 2)
    return f"x0={x},y0={y},w={w},h={h}", f"x={x}, y={y}, w={w}, h={h}"


def dominant(values: Sequence[str]) -> float:
    """The share of the most common known value."""
    known = [value for value in values if value != "unknown"]
    if not known:
        return 0.0
    return max(Counter(known).values()) / len(known)


def last_matrix(operations: Sequence[Operation]) -> Matrix | None:
    """The last transformation a block sets."""
    found: Matrix | None = None
    for operands, op in operations:
        if op in (b"cm", b"Tm"):
            found = matrix_of(operands) or found
        elif op in (b"Td", b"TD") and len(operands) >= 2:
            found = (
                1.0,
                0.0,
                0.0,
                1.0,
                number(operands[0]),
                number(operands[1]),
            )
    return found


# Block detection --------------------------------------------------------------


def isolated(operations: Sequence[Operation]) -> bool:
    """Whether a small stream only shows text or draws a form."""
    if not operations or len(operations) > MAX_ISOLATED_OPS:
        return False
    ops = {op for _, op in operations}
    if not ops & (TEXT_SHOW | {b"BT", DRAW_XOBJECT}):
        return False
    return not ops & PATHS


def text_ranges(operations: Sequence[Operation]) -> list[tuple[int, int]]:
    """Text blocks with text, with the q/Q right around them."""
    ranges = []
    start: int | None = None
    for index, (_, op) in enumerate(operations):
        if op == b"BT" and start is None:
            start = index
        elif op == b"ET" and start is not None:
            first, end = _widen(operations, start, index + 1)
            if text_of(operations[first:end]):
                ranges.append((first, end))
            start = None
    return ranges


def _widen(
    operations: Sequence[Operation], start: int, end: int
) -> tuple[int, int]:
    """A range grown by one q before and one Q after, when both are there."""
    if (
        start > 0
        and end < len(operations)
        and operations[start - 1][1] == b"q"
        and operations[end][1] == b"Q"
    ):
        return start - 1, end + 1
    return start, end


def wrapped_draws(
    operations: Sequence[Operation],
) -> tuple[list[tuple[int, int]], set[int]]:
    """Short q … Do … Q blocks around one XObject, and their Do indices."""
    ranges = []
    covered: set[int] = set()
    stack: list[int] = []
    for index, (_, op) in enumerate(operations):
        if op == b"q":
            stack.append(index)
        elif op == b"Q" and stack:
            start = stack.pop()
            draws = [
                position
                for position in range(start, index + 1)
                if operations[position][1] == DRAW_XOBJECT
            ]
            if len(draws) == 1 and index + 1 - start <= MAX_WRAPPED_DO_OPS:
                ranges.append((start, index + 1))
                covered.update(draws)
    return ranges, covered


def draws(
    operations: Sequence[Operation], covered: set[int]
) -> list[tuple[int, int]]:
    """Other XObject draws, with the modifiers right before them."""
    ranges: list[tuple[int, int]] = []
    for index, (_, op) in enumerate(operations):
        if op != DRAW_XOBJECT or index in covered:
            continue
        start = index
        while start > 0 and operations[start - 1][1] in MODIFIERS:
            start -= 1
        ranges.append(_widen(operations, start, index + 1))
    return list(dict.fromkeys(ranges))


def blocks(operations: Sequence[Operation]) -> list[tuple[int, int, Kind]]:
    """Every candidate block of a stream, each range once."""
    if not operations:
        return []
    if isolated(operations):
        return [(0, len(operations), Kind.STREAM)]
    found = [(start, end, Kind.TEXT) for start, end in text_ranges(operations)]
    seen = {(start, end) for start, end, _ in found}
    wrapped, covered = wrapped_draws(operations)
    for start, end in wrapped + draws(operations, covered):
        if (start, end) not in seen:
            seen.add((start, end))
            found.append((start, end, Kind.XOBJECT))
    return found


# Pages ------------------------------------------------------------------------


def operations_of(instructions: Sequence[object]) -> list[Operation]:
    """Parsed instructions as (operands, operator) pairs.

    An inline image becomes ``BI``, which marks real page content.
    """
    result: list[Operation] = []
    for instruction in instructions:
        if isinstance(instruction, pikepdf.ContentStreamInlineImage):
            result.append(([], INLINE_IMAGE))
            continue
        operator = str(instruction.operator).encode("latin-1")
        result.append((list(instruction.operands), operator))
    return result


def streams_of(page: pikepdf.Page) -> list[pikepdf.Stream]:
    """A page's content streams, in drawing order."""
    contents = page.obj.get("/Contents")
    if isinstance(contents, pikepdf.Stream):
        return [contents]
    if isinstance(contents, pikepdf.Array):
        return [item for item in contents if isinstance(item, pikepdf.Stream)]
    return []


def resource(
    container: pikepdf.Object, kind: str
) -> pikepdf.Dictionary | None:
    """A named resource dictionary of a page or form."""
    resources = container.get("/Resources")
    if not isinstance(resources, pikepdf.Dictionary):
        return None
    found = resources.get(kind)
    return found if isinstance(found, pikepdf.Dictionary) else None


def transparent(container: pikepdf.Object, name: object) -> bool:
    """Whether a graphics state blends or is see-through."""
    states = resource(container, "/ExtGState")
    if (
        states is None
        or not isinstance(name, pikepdf.Name)
        or name not in states
    ):
        return False
    state = states[name]
    if not isinstance(state, pikepdf.Dictionary):
        return False
    return (
        number(state.get("/CA", 1), 1) < 0.999
        or number(state.get("/ca", 1), 1) < 0.999
        or str(state.get("/BM", "/Normal")) not in ("/Normal", "/Compatible")
    )


class Analyzer:
    """Analyse one document; forms are parsed once however often drawn."""

    def __init__(self, match_texts: Sequence[str]) -> None:
        """Prepare for the phrases the user named."""
        self.match_texts = [normalize(t) for t in match_texts if t.strip()]
        self.forms: dict[object, Form | None] = {}
        self.warnings: list[str] = []

    def warn(self, message: str) -> None:
        """Note a warning once."""
        if message not in self.warnings:
            self.warnings.append(message)

    def analyze(self, pdf: pikepdf.Pdf) -> Analysis:
        """Cluster and score every candidate block of the document."""
        found: list[Occurrence] = []
        for index, page in enumerate(pdf.pages):
            found += self.page(page, index)
        grouped: dict[str, list[Occurrence]] = defaultdict(list)
        for occurrence in found:
            key = digest(
                [
                    occurrence.kind.value,
                    occurrence.signature,
                    occurrence.position,
                    occurrence.form_key,
                    occurrence.pattern,
                ]
            )
            grouped[key].append(occurrence)
        total = len(pdf.pages)
        clusters = [
            evaluate(position, items, total)
            for position, items in enumerate(grouped.values(), start=1)
        ]
        clusters.sort(
            key=lambda c: (not c.remove, -c.score, -c.coverage, c.number)
        )
        return Analysis(total, clusters, list(self.warnings))

    def page(self, page: pikepdf.Page, index: int) -> list[Occurrence]:
        """The candidate blocks of one page."""
        found: list[Occurrence] = []
        streams = streams_of(page)
        for position, stream in enumerate(streams):
            try:
                operations = operations_of(
                    pikepdf.parse_content_stream(stream)
                )
            except pikepdf.PdfError as error:
                self.warn(
                    f"Skipped an unreadable stream on page {index + 1}: "
                    f"{first_line(error)}"
                )
                continue
            for start, end, kind in blocks(operations):
                found.append(
                    self.occurrence(
                        page,
                        index,
                        position,
                        len(streams),
                        operations,
                        start,
                        end,
                        kind,
                    )
                )
        return found

    def form(self, container: pikepdf.Object, name: object) -> Form | None:
        """What an XObject drawn by name holds, analysed once."""
        objects = resource(container, "/XObject")
        if objects is None or not isinstance(name, pikepdf.Name):
            return None
        if name not in objects:
            return None
        xobject = objects[name]
        if not isinstance(xobject, pikepdf.Stream):
            return None
        key = xobject.objgen if xobject.is_indirect else id(xobject)
        if key in self.forms:
            return self.forms[key]
        subtype = str(xobject.get("/Subtype", ""))
        text, hashed, preview = "", digest([subtype or "unknown"]), subtype
        if subtype == "/Form":
            try:
                inner = operations_of(pikepdf.parse_content_stream(xobject))
                text = text_of(inner)
                hashed, preview = signature(inner)
            except pikepdf.PdfError as error:
                self.warn(f"Skipped an unreadable form: {first_line(error)}")
                hashed, preview = "form-error", "unreadable form"
        form = Form(
            subtype,
            text,
            hashed,
            preview,
            box_of(xobject.get("/BBox")),
            matrix_of(xobject.get("/Matrix")),
        )
        self.forms[key] = form
        return form

    def occurrence(
        self,
        page: pikepdf.Page,
        index: int,
        stream: int,
        streams: int,
        operations: list[Operation],
        start: int,
        end: int,
        kind: Kind,
    ) -> Occurrence:
        """One block described for clustering and scoring."""
        box = page.mediabox
        width = number(box[2]) - number(box[0])
        height = number(box[3]) - number(box[1])
        block = operations[start:end]
        text = text_of(block)
        states = [
            operands[0] for operands, op in block if op == b"gs" and operands
        ]
        see_through = any(transparent(page.obj, name) for name in states)
        names = [o[0] for o, op in block if op == DRAW_XOBJECT and o]
        form = self.form(page.obj, names[0]) if len(names) == 1 else None
        if form is not None and form.text:
            text = normalize(f"{text} {form.text}")
        matrix = last_matrix(block)
        drawn = None
        if form is not None and form.box is not None:
            drawn = transform(form.box, matrix, form.matrix)
            position, preview = box_position(drawn, width, height)
        else:
            position, preview = matrix_position(matrix, width, height)
        hashed, operators = signature(block)
        form_key = ""
        if form is not None:
            form_key = digest([form.subtype, form.signature, mask(form.text)])
        return Occurrence(
            page=index,
            stream=stream,
            streams=streams,
            kind=kind,
            start=start,
            end=end,
            total=len(operations),
            signature=hashed,
            preview=operators,
            position=position,
            position_preview=preview,
            text=text,
            pattern=mask(text),
            matches=[n for n in self.match_texts if matches(text, n)],
            transparent=see_through,
            rotated=rotated(matrix)
            or (form is not None and rotated(form.matrix)),
            form=form is not None and form.subtype == "/Form",
            form_key=form_key,
            box=drawn,
        )


# Scoring ----------------------------------------------------------------------


def evaluate(number_: int, items: list[Occurrence], total: int) -> Cluster:
    """Score a cluster conservatively and decide whether to remove it."""
    pages = sorted({item.page for item in items})
    coverage = len(pages) / max(total, 1)
    reasons: list[str] = []
    score = 0
    share = f"{len(pages)}/{total} pages"
    if coverage >= 0.85:
        score += 4
        reasons.append(f"Repeats on most pages ({share})")
    elif coverage >= 0.6:
        score += 3
        reasons.append(f"Repeats on many pages ({share})")
    elif coverage >= MIN_REPEAT:
        score += 2
        reasons.append(f"Repeats on at least half of the pages ({share})")
    else:
        reasons.append(f"Repeats little ({share})")

    steady = dominant([item.position for item in items])
    if steady >= 0.8:
        score += 2
        reasons.append("Sits in the same place on every page")
    elif steady:
        reasons.append("Moves somewhat from page to page")
    else:
        reasons.append("Its position could not be estimated")

    named = sorted({match for item in items for match in item.matches})
    if named:
        score += 5
        reasons.append("Holds the text you named")
    if any(item.transparent for item in items):
        score += 3
        reasons.append("Is drawn see-through or blended")
    if any(item.rotated for item in items):
        score += 2
        reasons.append("Is rotated or skewed, as watermarks often are")

    count = max(len(items), 1)
    whole = sum(item.whole_stream for item in items) / count
    if whole >= 0.7:
        score += 2
        reasons.append("Is a stream or block of its own")
    edge = sum(item.at_edge for item in items) / count
    if edge >= 0.7:
        score += 1
        reasons.append("Is drawn at the start or end of the page")

    ops = int(statistics.median(item.ops for item in items))
    if ops <= 18:
        score += 1
        reasons.append("Is small enough to be an overlay")
    elif ops > 80:
        score -= 3
        reasons.append("Is large and may hold real page content")

    texts = sorted({normalize(item.text) for item in items if item.text})
    varying = len(texts) > 1
    words = (
        int(statistics.median(len(re.findall(r"\w+", t)) for t in texts))
        if texts
        else 0
    )
    if varying:
        score += 1
        reasons.append("Its text changes while its structure stays the same")
    if any(item.form for item in items):
        score += 1
        reasons.append("Draws a form, a common watermark container")

    stamped = varying and words >= 4 and whole >= 0.5 and edge >= 0.5
    cue = bool(
        named
        or any(item.transparent for item in items)
        or any(item.rotated for item in items)
        or stamped
    )
    if not cue:
        score -= 2
        reasons.append("Shows no sign specific to watermarks")
    if not named and coverage < MIN_REPEAT:
        score -= 2
    if named and ops > 60:
        score -= 1
        reasons.append("Holds the named text inside a fairly large block")

    if cue and score >= 8:
        confidence, remove = Confidence.HIGH, True
    elif score >= 6:
        confidence, remove = Confidence.MEDIUM, False
        reasons.append("Kept: likely, but not certain enough to remove")
    else:
        confidence, remove = Confidence.LOW, False
        reasons.append("Kept: removing it could delete real content")

    return Cluster(
        number=number_,
        kind=items[0].kind,
        occurrences=items,
        pages=pages,
        coverage=coverage,
        score=score,
        confidence=confidence,
        remove=remove,
        reasons=reasons,
        preview=items[0].preview,
        position=items[0].position_preview,
        texts=[sample(text) for text in texts[:3]],
        matches=named,
    )


# Removal ----------------------------------------------------------------------


def apply(
    pdf: pikepdf.Pdf, analysis: Analysis, *, redact: bool = False
) -> Applied:
    """Remove the selected clusters from the document's pages.

    With ``redact``, a block whose stream cannot be edited is covered by a
    white rectangle instead, when its extent is known.
    """
    result = Applied()
    chosen: dict[int, list[Occurrence]] = defaultdict(list)
    for cluster in analysis.selected:
        for item in cluster.occurrences:
            chosen[item.page].append(item)
    for index, items in sorted(chosen.items()):
        removed, redacted = _apply_page(
            pdf, pdf.pages[index], items, redact, result.warnings
        )
        result.pages += bool(removed or redacted)
        result.removed += removed
        result.redacted += redacted
    return result


def _apply_page(
    pdf: pikepdf.Pdf,
    page: pikepdf.Page,
    items: list[Occurrence],
    redact: bool,
    warnings: list[str],
) -> tuple[int, int]:
    """Cut one page's blocks; how many were removed and redacted."""
    streams = streams_of(page)
    by_stream: dict[int, list[Occurrence]] = defaultdict(list)
    for item in items:
        by_stream[item.stream].append(item)
    kept: list[pikepdf.Stream] = []
    covers: list[Box] = []
    removed = redacted = 0
    for position, stream in enumerate(streams):
        mine = by_stream.get(position, [])
        if not mine:
            kept.append(stream)
            continue
        try:
            instructions = pikepdf.parse_content_stream(stream)
        except pikepdf.PdfError as error:
            boxes = [item.box for item in mine if item.box is not None]
            if not (redact and boxes):
                raise
            covers += boxes
            redacted += len(boxes)
            kept.append(stream)
            message = f"Covered page {page.index + 1}: {first_line(error)}"
            warnings.append(message)
            continue
        operations = operations_of(instructions)
        last = position == len(streams) - 1
        cut: set[int] = set()
        for item in mine:
            cut |= removable(operations, item.start, item.end, last=last)
        removed += len(mine)
        remaining = [
            instruction
            for number_, instruction in enumerate(instructions)
            if number_ not in cut
        ]
        if remaining:
            data = pikepdf.unparse_content_stream(remaining)
            kept.append(pdf.make_stream(data))
    if covers:
        kept.append(pdf.make_stream(_cover(covers)))
    page.obj.Contents = pikepdf.Array(kept) if kept else pdf.make_stream(b"")
    return removed, redacted


def removable(
    operations: Sequence[Operation], start: int, end: int, *, last: bool
) -> set[int]:
    """The operators of a block that can go without disturbing the page.

    A block wrapped in q/Q, or the whole of a page's last stream, goes
    entirely. Otherwise only the operators that draw go, and anything that
    sets state later content may use stays.
    """
    whole = start == 0 and end == len(operations)
    wrapped = operations[start][1] == b"q" and operations[end - 1][1] == b"Q"
    if wrapped and _balanced(operations[start:end]) or whole and last:
        return set(range(start, end))
    return {
        index
        for index in range(start, end)
        if operations[index][1] not in PERSISTENT
    }


def _balanced(operations: Sequence[Operation]) -> bool:
    """Whether every q in a block is closed inside it, and none closes early."""
    depth = 0
    for _, op in operations:
        depth += (op == b"q") - (op == b"Q")
        if depth < 0:
            return False
    return depth == 0


def _cover(boxes: Sequence[Box]) -> bytes:
    """A content stream that paints white rectangles over boxes."""
    commands = ["q", "1 1 1 rg"]
    commands += [
        f"{b.x0:.3f} {b.y0:.3f} {b.width:.3f} {b.height:.3f} re f"
        for b in boxes
        if b.width > 0 and b.height > 0
    ]
    commands.append("Q")
    return "\n".join(commands).encode("ascii")
