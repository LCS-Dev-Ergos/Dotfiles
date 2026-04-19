#!/usr/bin/env python3

# ============================================================================ #
"""
PDF Watermark Remover:
Reusable CLI tool for detecting and removing repeated watermark-like overlays
from PDFs using structural content stream editing. The tool inspects repeated
text blocks, isolated streams, and Form XObject draw calls, then only removes
high-confidence candidates.

Author: Codex (GPT-5)
Version: 2.1.0
"""
# ============================================================================ #

from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
import sys
import textwrap
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Iterable, TypeAlias


# ++++++++++++++++++++++++++++++++ Constants +++++++++++++++++++++++++++++++++ #

APP_NAME = "PDF Watermark Remover"
APP_VERSION = "2.1.0"
BOX_WIDTH = 78
BOX_LABEL_WIDTH = 18

DESCRIPTION = (
    "Remove repeated watermark-like overlay content from PDFs by editing PDF "
    "content streams instead of rasterizing pages."
)

STRATEGY_TEXT = (
    "Analyze repeated page-level content stream fragments, short text blocks, "
    "and Form XObject draws; cluster them by structure and position; then only "
    "remove high-confidence watermark candidates."
)

LIMITATIONS_TEXT = (
    "Targets content stream overlays and Form XObjects only. Ambiguous repeated "
    "elements are reported but skipped. Fallback redaction is optional and only "
    "used when a bounding box is available."
)

TEXT_SHOW_OPS = {b"Tj", b"TJ", b"'", b'"'}
TEXT_BLOCK_START = b"BT"
TEXT_BLOCK_END = b"ET"
DRAW_XOBJECT_OP = b"Do"

MODIFIER_OPS = {
    b"cm",
    b"gs",
    b"g",
    b"G",
    b"rg",
    b"RG",
    b"k",
    b"K",
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

MAX_ISOLATED_STREAM_OPS = 48
MAX_WRAPPED_DO_OPS = 24
MIN_REPEAT_RATIO = 0.5

Matrix: TypeAlias = tuple[float, float, float, float, float, float]
Operation: TypeAlias = tuple[Any, bytes]


# ++++++++++++++++++++++++++++++++ Enums ++++++++++++++++++++++++++++++++++++ #

class OccurrenceKind(str, Enum):
    """Supported candidate block types found during analysis."""

    STREAM = "stream"
    TEXT_BLOCK = "text_block"
    XOBJECT_BLOCK = "xobject_block"


class Confidence(str, Enum):
    """Confidence levels for a candidate cluster."""

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class Decision(str, Enum):
    """Decision taken for a candidate cluster."""

    REMOVE = "remove"
    SKIP = "skip"


class RemovalMode(str, Enum):
    """How a candidate was or would be removed."""

    STRUCTURAL = "structural"
    FALLBACK_REDACT = "fallback_redact"
    SKIP = "skip"


# +++++++++++++++++++++++++++++ Exceptions ++++++++++++++++++++++++++++++++++ #

class ToolError(RuntimeError):
    """Base class for user-facing tool failures."""


# +++++++++++++++++++++++++++++ Output Formatting ++++++++++++++++++++++++++++ #

def status_prefix(level: str) -> str:
    """Return a short, consistent terminal prefix for the given status level."""
    labels = {
        "info": "[INFO]",
        "ok": "[ OK ]",
        "warn": "[WARN]",
        "error": "[ERR ]",
    }
    return labels.get(level.lower(), "[INFO]")


def print_status(level: str, message: str, *, stream: Any | None = None) -> None:
    """Print a single structured status line."""
    output = sys.stdout if stream is None else stream
    print(f"{status_prefix(level)} {message}", file=output)


def _wrap_box_value(label: str, value: str, width: int) -> list[str]:
    """Wrap a label/value pair so it fits neatly inside an ASCII box."""
    value = str(value)
    value_width = max(8, width - 4 - BOX_LABEL_WIDTH - 1)
    wrapped = textwrap.wrap(
        value,
        width=value_width,
        break_long_words=False,
        break_on_hyphens=False,
    ) or [""]

    lines: list[str] = []
    for index, chunk in enumerate(wrapped):
        prefix = f"{label:<{BOX_LABEL_WIDTH}} " if index == 0 else f"{'':<{BOX_LABEL_WIDTH}} "
        lines.append(prefix + chunk)
    return lines


def render_box(title: str, rows: list[tuple[str, str]], *, width: int = BOX_WIDTH) -> str:
    """Render a simple ASCII box for terminal-friendly summaries."""
    inner_width = max(20, width - 4)
    border = "+" + "-" * (width - 2) + "+"
    lines = [border, f"| {title[:inner_width]:<{inner_width}} |", border]

    for label, value in rows:
        wrapped_lines = _wrap_box_value(label, value, width)
        for line in wrapped_lines:
            lines.append(f"| {line[:inner_width]:<{inner_width}} |")

    lines.append(border)
    return "\n".join(lines)


@dataclass(slots=True)
class Backend:
    """PDF backend symbols loaded from either pypdf or PyPDF2."""

    module_name: str
    PdfReader: Any
    PdfWriter: Any
    PdfReadError: Any
    ArrayObject: Any
    ContentStream: Any
    DecodedStreamObject: Any
    NameObject: Any


@dataclass(frozen=True, slots=True)
class BBox:
    """Simple rectangular bounding box in PDF user-space coordinates."""

    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def width(self) -> float:
        return max(0.0, self.x1 - self.x0)

    @property
    def height(self) -> float:
        return max(0.0, self.y1 - self.y0)

    def as_list(self) -> list[float]:
        return [round(self.x0, 3), round(self.y0, 3), round(self.x1, 3), round(self.y1, 3)]


@dataclass(frozen=True, slots=True)
class ToolOptions:
    """Normalized command-line options for a single run."""

    input_pdf: Path
    output_pdf: Path | None
    match_texts: list[str]
    dry_run: bool
    verbose: bool
    report_path: Path | None
    fallback_redact: bool


@dataclass(slots=True)
class XObjectAnalysis:
    """Cached metadata extracted from a referenced XObject or Form."""

    object_id: str
    subtype: str
    text: str
    text_pattern: str
    op_hash: str
    op_preview: str
    bbox: BBox | None
    form_matrix: Matrix | None


@dataclass(slots=True)
class Occurrence:
    """Single watermark-like block detected on one page stream."""

    occurrence_id: str
    page_index: int
    stream_index: int
    kind: OccurrenceKind
    start_op: int
    end_op: int
    total_ops: int
    op_count: int
    op_hash: str
    op_preview: str
    position_key: str
    position_preview: str
    order_ratio: float
    stream_ratio: float
    text: str
    text_pattern: str
    explicit_matches: list[str]
    is_whole_stream: bool
    uses_transparency: bool
    has_rotation: bool
    has_form_xobject: bool
    xobject_key: str | None
    xobject_preview: str | None
    bbox: BBox | None


@dataclass(slots=True)
class CandidateGroup:
    """Cluster of repeated occurrences judged as one candidate overlay."""

    group_id: str
    key: str
    kind: OccurrenceKind
    occurrences: list[Occurrence]
    affected_pages: list[int]
    coverage: float
    score: int
    confidence: Confidence
    decision: Decision
    removal_mode: RemovalMode
    reasons: list[str]
    op_preview: str
    position_preview: str
    text_examples: list[str]
    text_patterns: list[str]
    explicit_matches: list[str]
    variable_text: bool
    strong_overlay_cue: bool


@dataclass(slots=True)
class AnalysisResult:
    """Full analysis output for one PDF scan."""

    total_pages: int
    occurrences: list[Occurrence]
    groups: list[CandidateGroup]
    warnings: list[str] = field(default_factory=list)

    @property
    def selected_groups(self) -> list[CandidateGroup]:
        """Return only the groups selected for removal."""
        return [group for group in self.groups if group.decision is Decision.REMOVE]


@dataclass(slots=True)
class ApplyResult:
    """Summary of the write step after candidate removal."""

    changed_pages: int = 0
    structurally_removed_occurrences: int = 0
    fallback_redactions: int = 0
    warnings: list[str] = field(default_factory=list)


@dataclass(slots=True)
class WatermarkProcessor:
    """Own the analysis/apply workflow and its transient caches."""

    backend: Backend
    options: ToolOptions
    xobject_cache: dict[str, XObjectAnalysis] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def analyze_document(self, reader: Any) -> AnalysisResult:
        """Analyze a reader using processor-owned caches and diagnostics."""
        return analyze_document(
            reader,
            self.backend,
            self.options,
            xobject_cache=self.xobject_cache,
            warnings=self.warnings,
        )

    def apply_changes(self, writer: Any, analysis: AnalysisResult) -> ApplyResult:
        """Apply selected removals using processor-owned options."""
        return apply_changes(
            writer,
            analysis,
            self.backend,
            self.options.fallback_redact,
            warnings=self.warnings,
        )


def append_warning(warnings: list[str] | None, message: str) -> None:
    """Append a warning message once when a warning sink is available."""
    if warnings is None:
        return
    if message not in warnings:
        warnings.append(message)


def load_pdf_backend() -> Backend:
    """Load pypdf first and fall back to PyPDF2 when needed."""
    try:
        from pypdf import PdfReader, PdfWriter
        from pypdf.errors import PdfReadError
        from pypdf.generic import ArrayObject, ContentStream, DecodedStreamObject, NameObject

        return Backend(
            module_name="pypdf",
            PdfReader=PdfReader,
            PdfWriter=PdfWriter,
            PdfReadError=PdfReadError,
            ArrayObject=ArrayObject,
            ContentStream=ContentStream,
            DecodedStreamObject=DecodedStreamObject,
            NameObject=NameObject,
        )
    except ImportError:
        pass

    try:
        from PyPDF2 import PdfReader, PdfWriter
        from PyPDF2.errors import PdfReadError
        from PyPDF2.generic import ArrayObject, ContentStream, DecodedStreamObject, NameObject

        return Backend(
            module_name="PyPDF2",
            PdfReader=PdfReader,
            PdfWriter=PdfWriter,
            PdfReadError=PdfReadError,
            ArrayObject=ArrayObject,
            ContentStream=ContentStream,
            DecodedStreamObject=DecodedStreamObject,
            NameObject=NameObject,
        )
    except ImportError as exc:
        raise ToolError(
            "This tool requires pypdf (preferred) or PyPDF2. Install one with "
            "`pip install pypdf`."
        ) from exc


def parse_args(argv: list[str]) -> ToolOptions:
    """Parse CLI arguments and normalize derived defaults."""
    parser = argparse.ArgumentParser(
        description=DESCRIPTION,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            f"Strategy: {STRATEGY_TEXT}\n"
            f"Limitations: {LIMITATIONS_TEXT}"
        ),
    )
    parser.add_argument("input_pdf", type=Path, help="Source PDF to inspect.")
    parser.add_argument(
        "output_pdf",
        nargs="?",
        type=Path,
        help="Destination PDF. Defaults to '<input>_cleaned.pdf' when not using --dry-run.",
    )
    parser.add_argument(
        "--match-text",
        action="append",
        default=[],
        metavar="TEXT",
        help="Prefer candidates whose extracted text contains this phrase. May be repeated.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Analyze the PDF and report candidates without writing an output PDF.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print detailed candidate diagnostics.",
    )
    parser.add_argument(
        "--report",
        type=Path,
        dest="report_path",
        help="Write a JSON analysis report to this path.",
    )
    parser.add_argument(
        "--fallback-redact",
        action="store_true",
        help=(
            "If structural editing fails for a selected candidate, use a last-resort "
            "white rectangle overlay when a bounding box is available."
        ),
    )
    args = parser.parse_args(argv)

    output_pdf = args.output_pdf
    if output_pdf is None and not args.dry_run:
        output_pdf = args.input_pdf.with_name(f"{args.input_pdf.stem}_cleaned.pdf")

    return ToolOptions(
        input_pdf=args.input_pdf,
        output_pdf=output_pdf,
        match_texts=[normalize_whitespace(text) for text in args.match_text if text.strip()],
        dry_run=args.dry_run,
        verbose=args.verbose,
        report_path=args.report_path,
        fallback_redact=args.fallback_redact,
    )


def validate_paths(options: ToolOptions) -> None:
    """Validate input, output, and report paths before doing any PDF work."""
    if not options.input_pdf.exists():
        raise ToolError(f"Input PDF not found: {options.input_pdf}")
    if not options.input_pdf.is_file():
        raise ToolError(f"Input path is not a file: {options.input_pdf}")
    if options.input_pdf.suffix.lower() != ".pdf":
        raise ToolError(f"Input file does not have a .pdf extension: {options.input_pdf}")

    if options.output_pdf is not None:
        if options.output_pdf.resolve() == options.input_pdf.resolve():
            raise ToolError("Input and output paths must be different.")
        output_dir = options.output_pdf.resolve().parent
        if not output_dir.exists():
            raise ToolError(f"Output directory does not exist: {output_dir}")

    if options.report_path is not None:
        report_dir = options.report_path.resolve().parent
        if not report_dir.exists():
            raise ToolError(f"Report directory does not exist: {report_dir}")


def normalize_whitespace(text: str) -> str:
    """Collapse repeated whitespace for stable matching and display."""
    return re.sub(r"\s+", " ", text).strip()


def normalize_compact(text: str) -> str:
    """Normalize text further by removing whitespace and lowercasing."""
    return re.sub(r"\s+", "", normalize_whitespace(text)).lower()


def text_matches(text: str, needle: str) -> bool:
    """Return True when the text contains the requested phrase loosely."""
    normalized_text = normalize_whitespace(text).lower()
    normalized_needle = normalize_whitespace(needle).lower()
    return normalized_needle in normalized_text or normalize_compact(needle) in normalize_compact(text)


def short_sample(text: str, limit: int = 100) -> str:
    """Return a shortened display sample for terminal output and reports."""
    text = normalize_whitespace(text)
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def decode_operator(op: bytes | str) -> str:
    """Convert an operator token into a readable string."""
    return op.decode("latin1") if isinstance(op, bytes) else str(op)


def signature_hash(parts: Iterable[str]) -> str:
    """Build a short stable hash for grouping similar content blocks."""
    digest = hashlib.sha1("\x1f".join(parts).encode("utf-8", "ignore")).hexdigest()
    return digest[:12]


def operator_signature(operations: list[Operation]) -> tuple[str, str]:
    """Return a stable hash plus preview string for an operator sequence."""
    names = [decode_operator(op) for _, op in operations]
    preview_parts = names[:14]
    if len(names) > 14:
        preview_parts.append("…")
        preview_parts.extend(names[-4:])
    preview = " ".join(preview_parts) if preview_parts else "<empty>"
    return signature_hash(names), preview


def extract_text_from_operations(operations: list[Operation]) -> str:
    """Extract text shown by common PDF text-show operators."""
    fragments: list[str] = []
    for operands, op in operations:
        match op:
            case b"Tj" if operands:
                maybe_text = operands[0]
                if isinstance(maybe_text, str):
                    fragments.append(maybe_text)
            case b"TJ" if operands:
                for item in operands[0]:
                    if isinstance(item, str):
                        fragments.append(item)
                fragments.append(" ")
            case b"'" if operands:
                maybe_text = operands[0]
                if isinstance(maybe_text, str):
                    fragments.append("\n")
                    fragments.append(maybe_text)
            case b'"' if operands:
                maybe_text = operands[-1]
                if isinstance(maybe_text, str):
                    fragments.append("\n")
                    fragments.append(maybe_text)
    return normalize_whitespace("".join(fragments))


def mask_dynamic_text(text: str) -> str:
    """Replace dynamic-looking tokens so similar overlays cluster together."""
    if not text:
        return ""
    tokens = re.findall(r"\w+|[^\w\s]", text.lower())
    masked: list[str] = []
    for token in tokens[:30]:
        if re.search(r"\d", token):
            masked.append("<id>")
        elif token.isalpha():
            masked.append(token if len(token) <= 3 else "<word>")
        else:
            masked.append(token)
    return " ".join(masked)


def safe_float(value: Any, default: float = 0.0) -> float:
    """Convert a PDF numeric object to float with a fallback."""
    try:
        return float(value)
    except Exception:
        return default


def resolve(obj: Any) -> Any:
    """Resolve an indirect PDF object if possible."""
    try:
        return obj.get_object()
    except Exception:
        return obj


def object_identifier(obj: Any) -> str:
    """Return a stable identifier for direct or indirect PDF objects."""
    target = obj
    indirect_reference = getattr(obj, "indirect_reference", None)
    if indirect_reference is not None:
        target = indirect_reference

    idnum = getattr(target, "idnum", None)
    generation = getattr(target, "generation", None)
    if idnum is not None:
        return f"{idnum}:{generation or 0}"
    return f"direct:{id(target)}"


def page_dimensions(page: Any) -> tuple[float, float]:
    """Return the page width and height in user-space units."""
    mediabox = getattr(page, "mediabox", None)
    if mediabox is None:
        return 1.0, 1.0
    try:
        return float(mediabox.width), float(mediabox.height)
    except Exception:
        left = safe_float(getattr(mediabox, "left", 0.0))
        bottom = safe_float(getattr(mediabox, "bottom", 0.0))
        right = safe_float(getattr(mediabox, "right", 1.0))
        top = safe_float(getattr(mediabox, "top", 1.0))
        return max(1.0, right - left), max(1.0, top - bottom)


def parse_matrix(value: Any) -> Matrix | None:
    """Parse a six-value PDF transformation matrix when available."""
    resolved = resolve(value)
    if not isinstance(resolved, (list, tuple)) or len(resolved) != 6:
        return None
    return tuple(safe_float(item) for item in resolved)


def transform_point(matrix: Matrix, x: float, y: float) -> tuple[float, float]:
    """Apply a PDF transformation matrix to a single point."""
    a, b, c, d, e, f = matrix
    return a * x + c * y + e, b * x + d * y + f


def transform_bbox(
    bbox: BBox,
    outer_matrix: Matrix | None,
    inner_matrix: Matrix | None,
) -> BBox:
    """Transform a bounding box through nested PDF matrices."""
    points = [
        (bbox.x0, bbox.y0),
        (bbox.x1, bbox.y0),
        (bbox.x1, bbox.y1),
        (bbox.x0, bbox.y1),
    ]
    transformed: list[tuple[float, float]] = []
    for x, y in points:
        px, py = x, y
        if inner_matrix is not None:
            px, py = transform_point(inner_matrix, px, py)
        if outer_matrix is not None:
            px, py = transform_point(outer_matrix, px, py)
        transformed.append((px, py))

    xs = [point[0] for point in transformed]
    ys = [point[1] for point in transformed]
    return BBox(min(xs), min(ys), max(xs), max(ys))


def parse_bbox(value: Any) -> BBox | None:
    """Parse a PDF /BBox array into a normalized bounding box."""
    resolved = resolve(value)
    if not isinstance(resolved, (list, tuple)) or len(resolved) != 4:
        return None
    x0, y0, x1, y1 = (safe_float(item) for item in resolved)
    if x1 < x0:
        x0, x1 = x1, x0
    if y1 < y0:
        y0, y1 = y1, y0
    return BBox(x0, y0, x1, y1)


def matrix_has_rotation(matrix: Matrix | None) -> bool:
    """Return True when a matrix appears to rotate or skew content."""
    if matrix is None:
        return False
    _, b, c, _, _, _ = matrix
    return abs(b) > 0.01 or abs(c) > 0.01


def position_key_from_matrix(
    matrix: Matrix | None,
    page_width: float,
    page_height: float,
) -> tuple[str, str]:
    """Create grouping and preview strings from a transform matrix."""
    if matrix is None:
        return "unknown", "unknown"
    a, b, c, d, e, f = matrix
    key = (
        f"mx={round(a, 2)},"
        f"my={round(d, 2)},"
        f"sk={round(b, 2)}/{round(c, 2)},"
        f"tx={round(e / max(page_width, 1.0), 2)},"
        f"ty={round(f / max(page_height, 1.0), 2)}"
    )
    preview = (
        f"x={round(e / max(page_width, 1.0), 2)}, "
        f"y={round(f / max(page_height, 1.0), 2)}, "
        f"rot={'yes' if matrix_has_rotation(matrix) else 'no'}"
    )
    return key, preview


def position_key_from_bbox(bbox: BBox | None, page_width: float, page_height: float) -> tuple[str, str]:
    """Create grouping and preview strings from a bounding box."""
    if bbox is None:
        return "unknown", "unknown"
    key = (
        f"x0={round(bbox.x0 / max(page_width, 1.0), 2)},"
        f"y0={round(bbox.y0 / max(page_height, 1.0), 2)},"
        f"w={round(bbox.width / max(page_width, 1.0), 2)},"
        f"h={round(bbox.height / max(page_height, 1.0), 2)}"
    )
    preview = (
        f"x={round(bbox.x0 / max(page_width, 1.0), 2)}, "
        f"y={round(bbox.y0 / max(page_height, 1.0), 2)}, "
        f"w={round(bbox.width / max(page_width, 1.0), 2)}, "
        f"h={round(bbox.height / max(page_height, 1.0), 2)}"
    )
    return key, preview


def dominant_share(values: list[str]) -> float:
    """Return the dominant non-unknown value share within a sequence."""
    filtered = [value for value in values if value != "unknown"]
    if not filtered:
        return 0.0
    counts = Counter(filtered)
    return max(counts.values()) / len(filtered)


def get_resource_dict(page_or_xobject: Any, resource_name: str) -> Any:
    """Fetch and resolve a named resource dictionary from a page or XObject."""
    resources = resolve(page_or_xobject.get("/Resources", {}))
    if not isinstance(resources, dict):
        return None
    return resolve(resources.get(resource_name))


def extgstate_has_transparency(container: Any, gs_name: Any) -> bool:
    """Check whether an ExtGState implies transparency or non-normal blending."""
    extgstates = get_resource_dict(container, "/ExtGState")
    if not isinstance(extgstates, dict) or gs_name not in extgstates:
        return False
    extgstate = resolve(extgstates[gs_name])
    if not isinstance(extgstate, dict):
        return False
    alpha_stroke = safe_float(extgstate.get("/CA", 1.0), 1.0)
    alpha_fill = safe_float(extgstate.get("/ca", 1.0), 1.0)
    blend_mode = str(extgstate.get("/BM", "/Normal"))
    return alpha_stroke < 0.999 or alpha_fill < 0.999 or blend_mode not in {"/Normal", "Normal"}


def analyze_xobject(
    page: Any,
    xobject_name: Any,
    backend: Backend,
    cache: dict[str, XObjectAnalysis],
    warnings: list[str] | None = None,
) -> XObjectAnalysis | None:
    """Inspect one referenced XObject and cache reusable analysis data."""
    xobjects = get_resource_dict(page, "/XObject")
    if not isinstance(xobjects, dict) or xobject_name not in xobjects:
        return None

    xobject_ref = xobjects[xobject_name]
    object_id = object_identifier(xobject_ref)
    if object_id in cache:
        return cache[object_id]

    xobject = resolve(xobject_ref)
    subtype = str(xobject.get("/Subtype", ""))
    text = ""
    text_pattern = ""
    op_hash = ""
    op_preview = ""
    bbox = parse_bbox(xobject.get("/BBox"))
    form_matrix = parse_matrix(xobject.get("/Matrix"))

    if subtype == "/Form":
        try:
            content_stream = backend.ContentStream(xobject, getattr(page, "pdf", None))
            operations = content_stream.operations
            text = extract_text_from_operations(operations)
            text_pattern = mask_dynamic_text(text)
            op_hash, op_preview = operator_signature(operations)
        except Exception as exc:
            append_warning(
                warnings,
                f"Skipped Form XObject analysis for object {object_id}: {exc}",
            )
            op_hash, op_preview = "form-error", "form parse error"
    else:
        op_hash = signature_hash([subtype or "unknown"])
        op_preview = subtype or "unknown"

    analysis = XObjectAnalysis(
        object_id=object_id,
        subtype=subtype,
        text=text,
        text_pattern=text_pattern,
        op_hash=op_hash,
        op_preview=op_preview,
        bbox=bbox,
        form_matrix=form_matrix,
    )
    cache[object_id] = analysis
    return analysis


def looks_like_isolated_overlay_stream(operations: list[Operation]) -> bool:
    """Heuristically detect a small content stream that looks overlay-only."""
    if not operations or len(operations) > MAX_ISOLATED_STREAM_OPS:
        return False
    visible_ops = [op for _, op in operations if op in TEXT_SHOW_OPS or op in {TEXT_BLOCK_START, DRAW_XOBJECT_OP}]
    if not visible_ops:
        return False
    disqualifying_ops = {b"BI", b"EI", b"m", b"l", b"c", b"h", b"S", b"s", b"f", b"f*", b"B", b"B*"}
    return not any(op in disqualifying_ops for _, op in operations)


def detect_text_ranges(operations: list[Operation]) -> list[tuple[int, int]]:
    """Find self-contained text blocks that could be removable overlays."""
    ranges: list[tuple[int, int]] = []
    block_start: int | None = None
    for index, (_, op) in enumerate(operations):
        if op == TEXT_BLOCK_START and block_start is None:
            block_start = index
        elif op == TEXT_BLOCK_END and block_start is not None:
            start = block_start
            end = index + 1
            if start > 0 and end < len(operations) and operations[start - 1][1] == b"q" and operations[end][1] == b"Q":
                start -= 1
                end += 1
            block_ops = operations[start:end]
            if extract_text_from_operations(block_ops):
                ranges.append((start, end))
            block_start = None
    return ranges


def detect_small_wrapped_do_ranges(operations: list[Operation]) -> tuple[list[tuple[int, int]], set[int]]:
    """Find short q/cm/Do/Q-style draw wrappers around XObjects."""
    ranges: list[tuple[int, int]] = []
    covered_do_indices: set[int] = set()
    stack: list[int] = []

    for index, (_, op) in enumerate(operations):
        if op == b"q":
            stack.append(index)
        elif op == b"Q" and stack:
            start = stack.pop()
            block = operations[start : index + 1]
            do_indices = [start + offset for offset, (_, block_op) in enumerate(block) if block_op == DRAW_XOBJECT_OP]
            if len(do_indices) == 1 and len(block) <= MAX_WRAPPED_DO_OPS:
                ranges.append((start, index + 1))
                covered_do_indices.update(do_indices)

    return ranges, covered_do_indices


def detect_do_ranges(operations: list[Operation], protected_do_indices: set[int]) -> list[tuple[int, int]]:
    """Find standalone XObject draw calls and their nearby modifiers."""
    ranges: list[tuple[int, int]] = []

    for index, (_, op) in enumerate(operations):
        if op != DRAW_XOBJECT_OP or index in protected_do_indices:
            continue

        start = index
        while start > 0 and operations[start - 1][1] in MODIFIER_OPS:
            start -= 1

        end = index + 1
        if start > 0 and end < len(operations) and operations[start - 1][1] == b"q" and operations[end][1] == b"Q":
            start -= 1
            end += 1

        ranges.append((start, end))

    deduped: list[tuple[int, int]] = []
    seen: set[tuple[int, int]] = set()
    for item in ranges:
        if item not in seen:
            seen.add(item)
            deduped.append(item)
    return deduped


def primary_matrix_for_block(operations: list[Operation]) -> Matrix | None:
    """Return the most relevant transform matrix seen inside a block."""
    last_matrix: Matrix | None = None
    for operands, op in operations:
        if op in {b"cm", b"Tm"}:
            matrix = parse_matrix(operands)
            if matrix is not None:
                last_matrix = matrix
        elif op in {b"Td", b"TD"} and isinstance(operands, (list, tuple)) and len(operands) >= 2:
            last_matrix = (1.0, 0.0, 0.0, 1.0, safe_float(operands[0]), safe_float(operands[1]))
    return last_matrix


def build_occurrence(
    page: Any,
    page_index: int,
    stream_index: int,
    total_streams: int,
    operations: list[Operation],
    start_op: int,
    end_op: int,
    kind: OccurrenceKind,
    backend: Backend,
    match_texts: list[str],
    xobject_cache: dict[str, XObjectAnalysis],
    warnings: list[str] | None = None,
) -> Occurrence:
    """Build a normalized occurrence record for one candidate block."""
    page_width, page_height = page_dimensions(page)
    block_ops = operations[start_op:end_op]
    text = extract_text_from_operations(block_ops)
    gs_names = [operands[0] for operands, op in block_ops if op == b"gs" and operands]
    uses_transparency = any(extgstate_has_transparency(page, name) for name in gs_names)

    xobject_name = None
    xobject_info = None
    do_names = [operands[0] for operands, op in block_ops if op == DRAW_XOBJECT_OP and operands]
    if len(do_names) == 1:
        xobject_name = do_names[0]
        xobject_info = analyze_xobject(page, xobject_name, backend, xobject_cache, warnings)

    if xobject_info is not None and xobject_info.text:
        text = normalize_whitespace(" ".join(part for part in [text, xobject_info.text] if part))

    text_pattern = mask_dynamic_text(text)
    explicit_matches = [needle for needle in match_texts if text_matches(text, needle)]

    primary_matrix = primary_matrix_for_block(block_ops)
    bbox = None
    if xobject_info is not None and xobject_info.bbox is not None:
        bbox = transform_bbox(xobject_info.bbox, primary_matrix, xobject_info.form_matrix)

    if bbox is not None:
        position_key, position_preview = position_key_from_bbox(bbox, page_width, page_height)
    else:
        position_key, position_preview = position_key_from_matrix(primary_matrix, page_width, page_height)

    op_hash, op_preview = operator_signature(block_ops)

    xobject_key = None
    xobject_preview = None
    if xobject_info is not None:
        xobject_key = signature_hash(
            [
                xobject_info.subtype,
                xobject_info.op_hash,
                xobject_info.text_pattern,
            ]
        )
        xobject_preview = f"{xobject_info.subtype or 'xobject'} {xobject_info.op_preview}".strip()

    stream_ratio = 0.0 if total_streams <= 1 else stream_index / max(total_streams - 1, 1)
    order_ratio = start_op / max(len(operations), 1)
    has_rotation = matrix_has_rotation(primary_matrix) or (xobject_info is not None and matrix_has_rotation(xobject_info.form_matrix))

    return Occurrence(
        occurrence_id=f"p{page_index + 1}-s{stream_index}-{start_op}:{end_op}-{kind}",
        page_index=page_index,
        stream_index=stream_index,
        kind=kind,
        start_op=start_op,
        end_op=end_op,
        total_ops=len(operations),
        op_count=max(0, end_op - start_op),
        op_hash=op_hash,
        op_preview=op_preview,
        position_key=position_key,
        position_preview=position_preview,
        order_ratio=order_ratio,
        stream_ratio=stream_ratio,
        text=text,
        text_pattern=text_pattern,
        explicit_matches=explicit_matches,
        is_whole_stream=start_op == 0 and end_op == len(operations),
        uses_transparency=uses_transparency,
        has_rotation=has_rotation,
        has_form_xobject=bool(xobject_info and xobject_info.subtype == "/Form"),
        xobject_key=xobject_key,
        xobject_preview=xobject_preview,
        bbox=bbox,
    )


def page_streams(page: Any) -> list[Any]:
    """Return the page /Contents as a normalized list of streams."""
    contents = resolve(page.get("/Contents"))
    if contents is None:
        return []
    if hasattr(contents, "get_data"):
        return [contents]
    try:
        return list(contents)
    except TypeError:
        pass
    return [contents]


def collect_page_occurrences(
    page: Any,
    page_index: int,
    backend: Backend,
    match_texts: list[str],
    xobject_cache: dict[str, XObjectAnalysis],
    warnings: list[str] | None = None,
) -> list[Occurrence]:
    """Collect removable-looking blocks from all streams on one page."""
    occurrences: list[Occurrence] = []
    streams = page_streams(page)

    for stream_index, stream_obj in enumerate(streams):
        try:
            content_stream = backend.ContentStream(stream_obj, getattr(page, "pdf", None))
            operations = content_stream.operations
        except Exception as exc:
            append_warning(
                warnings,
                f"Skipped unreadable content stream on page {page_index + 1}: {exc}",
            )
            continue

        if not operations:
            continue

        if looks_like_isolated_overlay_stream(operations):
            occurrences.append(
                build_occurrence(
                    page=page,
                    page_index=page_index,
                    stream_index=stream_index,
                    total_streams=len(streams),
                    operations=operations,
                    start_op=0,
                    end_op=len(operations),
                    kind=OccurrenceKind.STREAM,
                    backend=backend,
                    match_texts=match_texts,
                    xobject_cache=xobject_cache,
                    warnings=warnings,
                )
            )
            continue

        seen_ranges: set[tuple[str, int, int]] = set()

        for start_op, end_op in detect_text_ranges(operations):
            key = ("text_block", start_op, end_op)
            if key in seen_ranges:
                continue
            seen_ranges.add(key)
            occurrences.append(
                build_occurrence(
                    page=page,
                    page_index=page_index,
                    stream_index=stream_index,
                    total_streams=len(streams),
                    operations=operations,
                    start_op=start_op,
                    end_op=end_op,
                    kind=OccurrenceKind.TEXT_BLOCK,
                    backend=backend,
                    match_texts=match_texts,
                    xobject_cache=xobject_cache,
                    warnings=warnings,
                )
            )

        wrapped_do_ranges, protected_do_indices = detect_small_wrapped_do_ranges(operations)
        for start_op, end_op in wrapped_do_ranges:
            key = ("xobject_block", start_op, end_op)
            if key in seen_ranges:
                continue
            seen_ranges.add(key)
            occurrences.append(
                build_occurrence(
                    page=page,
                    page_index=page_index,
                    stream_index=stream_index,
                    total_streams=len(streams),
                    operations=operations,
                    start_op=start_op,
                    end_op=end_op,
                    kind=OccurrenceKind.XOBJECT_BLOCK,
                    backend=backend,
                    match_texts=match_texts,
                    xobject_cache=xobject_cache,
                    warnings=warnings,
                )
            )

        for start_op, end_op in detect_do_ranges(operations, protected_do_indices):
            key = ("xobject_block", start_op, end_op)
            if key in seen_ranges:
                continue
            seen_ranges.add(key)
            occurrences.append(
                build_occurrence(
                    page=page,
                    page_index=page_index,
                    stream_index=stream_index,
                    total_streams=len(streams),
                    operations=operations,
                    start_op=start_op,
                    end_op=end_op,
                    kind=OccurrenceKind.XOBJECT_BLOCK,
                    backend=backend,
                    match_texts=match_texts,
                    xobject_cache=xobject_cache,
                    warnings=warnings,
                )
            )

    return occurrences


def build_group_key(occurrence: Occurrence) -> str:
    """Build a clustering key for repeated occurrences across pages."""
    parts = [
        occurrence.kind.value,
        occurrence.op_hash,
        occurrence.position_key,
        occurrence.xobject_key or "",
        occurrence.text_pattern or "",
    ]
    return signature_hash(parts)


def evaluate_group(
    group_id: str,
    key: str,
    occurrences: list[Occurrence],
    total_pages: int,
) -> CandidateGroup:
    """Score a cluster conservatively and decide whether to remove it."""
    pages = sorted({occurrence.page_index + 1 for occurrence in occurrences})
    coverage = len(pages) / max(total_pages, 1)

    reasons: list[str] = []
    score = 0

    if coverage >= 0.85:
        score += 4
        reasons.append(f"repeats on most pages ({len(pages)}/{total_pages})")
    elif coverage >= 0.6:
        score += 3
        reasons.append(f"repeats on many pages ({len(pages)}/{total_pages})")
    elif coverage >= MIN_REPEAT_RATIO:
        score += 2
        reasons.append(f"repeats on at least half of the pages ({len(pages)}/{total_pages})")
    elif pages:
        reasons.append(f"limited repetition ({len(pages)}/{total_pages} pages)")

    position_share = dominant_share([occurrence.position_key for occurrence in occurrences])
    if position_share >= 0.8:
        score += 2
        reasons.append("position is stable across pages")
    elif position_share:
        reasons.append("position varies somewhat across pages")
    else:
        reasons.append("position could not be estimated reliably")

    explicit_matches = sorted({match for occurrence in occurrences for match in occurrence.explicit_matches})
    if explicit_matches:
        score += 5
        reasons.append("matched explicit text provided by the user")

    transparency_count = sum(1 for occurrence in occurrences if occurrence.uses_transparency)
    if transparency_count:
        score += 3
        reasons.append("uses a graphics state that suggests transparency or blending")

    rotation_count = sum(1 for occurrence in occurrences if occurrence.has_rotation)
    if rotation_count:
        score += 2
        reasons.append("uses rotation or skew, which is common for watermarks")

    whole_stream_share = sum(1 for occurrence in occurrences if occurrence.is_whole_stream) / max(len(occurrences), 1)
    if whole_stream_share >= 0.7:
        score += 2
        reasons.append("appears as an isolated stream or isolated draw block")

    edge_share = sum(
        1
        for occurrence in occurrences
        if occurrence.order_ratio <= 0.15
        or occurrence.order_ratio >= 0.85
        or occurrence.stream_ratio <= 0.15
        or occurrence.stream_ratio >= 0.85
    ) / max(len(occurrences), 1)
    if edge_share >= 0.7:
        score += 1
        reasons.append("is consistently drawn near the beginning or end of page content")

    median_op_count = int(statistics.median(occurrence.op_count for occurrence in occurrences))
    if median_op_count <= 18:
        score += 1
        reasons.append("block is small enough to look like an overlay wrapper")
    elif median_op_count > 80:
        score -= 3
        reasons.append("block is large and risks containing real page content")

    text_values = [normalize_whitespace(occurrence.text) for occurrence in occurrences if occurrence.text]
    unique_texts = sorted(set(text_values))
    variable_text = len(unique_texts) > 1
    median_token_count = int(
        statistics.median(len(re.findall(r"\w+", text)) for text in text_values)
    ) if text_values else 0
    if variable_text:
        score += 1
        reasons.append("text varies across pages while the block structure stays similar")

    has_form_xobject = any(occurrence.has_form_xobject for occurrence in occurrences)
    if has_form_xobject:
        score += 1
        reasons.append("draws a Form XObject, a common watermark container")

    dynamic_overlay_text = (
        variable_text
        and median_token_count >= 4
        and whole_stream_share >= 0.5
        and edge_share >= 0.5
    )

    strong_overlay_cue = bool(
        explicit_matches
        or transparency_count
        or rotation_count
        or dynamic_overlay_text
    )

    if not strong_overlay_cue:
        score -= 2
        reasons.append("no strong watermark-specific cue was found")

    if not explicit_matches and coverage < MIN_REPEAT_RATIO:
        score -= 2

    if explicit_matches and median_op_count > 60:
        score -= 1
        reasons.append("explicit text was found, but the surrounding block is still fairly large")

    if strong_overlay_cue and score >= 8:
        confidence = Confidence.HIGH
        decision = Decision.REMOVE
        removal_mode = RemovalMode.STRUCTURAL
    elif score >= 6:
        confidence = Confidence.MEDIUM
        decision = Decision.SKIP
        removal_mode = RemovalMode.SKIP
        reasons.append("reported for review, but skipped because confidence is not high enough")
    else:
        confidence = Confidence.LOW
        decision = Decision.SKIP
        removal_mode = RemovalMode.SKIP
        reasons.append("skipped to avoid deleting uncertain content")

    kind = occurrences[0].kind if occurrences else OccurrenceKind.STREAM
    op_preview = occurrences[0].op_preview if occurrences else "<empty>"
    position_preview = occurrences[0].position_preview if occurrences else "unknown"
    text_examples = [short_sample(text) for text in unique_texts[:3]]
    text_patterns = sorted({occurrence.text_pattern for occurrence in occurrences if occurrence.text_pattern})[:3]

    return CandidateGroup(
        group_id=group_id,
        key=key,
        kind=kind,
        occurrences=occurrences,
        affected_pages=pages,
        coverage=coverage,
        score=score,
        confidence=confidence,
        decision=decision,
        removal_mode=removal_mode,
        reasons=reasons,
        op_preview=op_preview,
        position_preview=position_preview,
        text_examples=text_examples,
        text_patterns=text_patterns,
        explicit_matches=explicit_matches,
        variable_text=variable_text,
        strong_overlay_cue=strong_overlay_cue,
    )


def analyze_document(
    reader: Any,
    backend: Backend,
    options: ToolOptions,
    *,
    xobject_cache: dict[str, XObjectAnalysis] | None = None,
    warnings: list[str] | None = None,
) -> AnalysisResult:
    """Analyze the full document and group repeated watermark candidates."""
    all_occurrences: list[Occurrence] = []
    cache = xobject_cache if xobject_cache is not None else {}
    warning_sink = warnings if warnings is not None else []

    total_pages = len(reader.pages)
    for page_index, page in enumerate(reader.pages):
        page_occurrences = collect_page_occurrences(
            page=page,
            page_index=page_index,
            backend=backend,
            match_texts=options.match_texts,
            xobject_cache=cache,
            warnings=warning_sink,
        )
        all_occurrences.extend(page_occurrences)

    grouped: dict[str, list[Occurrence]] = defaultdict(list)
    for occurrence in all_occurrences:
        grouped[build_group_key(occurrence)].append(occurrence)

    groups: list[CandidateGroup] = []
    for index, (key, occurrences) in enumerate(grouped.items(), start=1):
        groups.append(evaluate_group(f"cand-{index:03d}", key, occurrences, total_pages))

    groups.sort(
        key=lambda group: (
            group.decision is not Decision.REMOVE,
            -group.score,
            -group.coverage,
            group.group_id,
        )
    )

    return AnalysisResult(
        total_pages=total_pages,
        occurrences=all_occurrences,
        groups=groups,
        warnings=list(warning_sink),
    )


def open_reader(input_pdf: Path, backend: Backend) -> Any:
    """Open the input PDF with strict parsing disabled when supported."""
    try:
        try:
            reader = backend.PdfReader(str(input_pdf), strict=False)
        except TypeError:
            reader = backend.PdfReader(str(input_pdf))
    except backend.PdfReadError as exc:
        raise ToolError(f"Unable to read PDF: {exc}") from exc

    if getattr(reader, "is_encrypted", False):
        raise ToolError(
            "Encrypted PDFs are not supported by this tool. Decrypt the file first and run it again."
        )
    return reader


def create_writer(reader: Any, backend: Backend) -> Any:
    """Create a writer that preserves as much of the source structure as possible."""
    try:
        return backend.PdfWriter(clone_from=reader)
    except TypeError:
        writer = backend.PdfWriter()
        if hasattr(writer, "clone_document_from_reader"):
            writer.clone_document_from_reader(reader)
        elif hasattr(writer, "clone_reader_document_root"):
            writer.clone_reader_document_root(reader)
        else:
            for page in reader.pages:
                writer.add_page(page)
            metadata = getattr(reader, "metadata", None)
            if metadata:
                try:
                    writer.add_metadata(metadata)
                except Exception:
                    pass
        return writer


def replace_page_contents(page: Any, content: Any, backend: Backend) -> None:
    """Replace a page's /Contents object using the active backend API."""
    if hasattr(page, "replace_contents"):
        page.replace_contents(content)
        return
    page[backend.NameObject("/Contents")] = content


def empty_stream(backend: Backend) -> Any:
    """Create an empty decoded stream for pages whose contents were removed."""
    stream = backend.DecodedStreamObject()
    stream.set_data(b"")
    return stream


def build_redaction_stream(backend: Backend, rects: list[BBox]) -> Any:
    """Build a simple white-fill content stream used as a last-resort fallback."""
    commands = ["q", "1 1 1 rg", "1 1 1 RG"]
    for rect in rects:
        if rect.width <= 0 or rect.height <= 0:
            continue
        commands.append(
            f"{rect.x0:.3f} {rect.y0:.3f} {rect.width:.3f} {rect.height:.3f} re f"
        )
    commands.append("Q")
    stream = backend.DecodedStreamObject()
    stream.set_data("\n".join(commands).encode("ascii"))
    return stream


def apply_occurrences_to_page(
    page: Any,
    occurrences: list[Occurrence],
    backend: Backend,
    fallback_redact: bool,
    page_number: int,
    warnings: list[str] | None = None,
) -> tuple[bool, int, int]:
    """Apply selected removals to one page and return modification counts."""
    streams = page_streams(page)
    by_stream: dict[int, list[Occurrence]] = defaultdict(list)
    for occurrence in occurrences:
        by_stream[occurrence.stream_index].append(occurrence)

    changed = False
    removed = 0
    fallback_count = 0
    redaction_rects: list[BBox] = []
    new_streams: list[Any] = []

    for stream_index, stream_obj in enumerate(streams):
        stream_occurrences = by_stream.get(stream_index, [])
        if not stream_occurrences:
            new_streams.append(stream_obj)
            continue

        whole_stream = any(occurrence.is_whole_stream for occurrence in stream_occurrences)
        if whole_stream:
            changed = True
            removed += len({occurrence.occurrence_id for occurrence in stream_occurrences})
            continue

        try:
            content_stream = backend.ContentStream(stream_obj, getattr(page, "pdf", None))
            operations = content_stream.operations
            remove_indices: set[int] = set()
            for occurrence in stream_occurrences:
                remove_indices.update(range(occurrence.start_op, occurrence.end_op))

            if not remove_indices:
                new_streams.append(stream_obj)
                continue

            filtered_operations = [
                operation
                for index, operation in enumerate(operations)
                if index not in remove_indices
            ]
            if len(filtered_operations) != len(operations):
                changed = True
                removed += len({occurrence.occurrence_id for occurrence in stream_occurrences})
                if filtered_operations:
                    content_stream.operations = filtered_operations
                    new_streams.append(content_stream)
                continue

            new_streams.append(stream_obj)
        except Exception as exc:
            if fallback_redact:
                usable_rects = [occurrence.bbox for occurrence in stream_occurrences if occurrence.bbox is not None]
                if usable_rects:
                    redaction_rects.extend(usable_rects)
                    fallback_count += len(usable_rects)
                    changed = True
                    append_warning(
                        warnings,
                        f"Used fallback redaction on page {page_number} after structural edit failure: {exc}",
                    )
                    new_streams.append(stream_obj)
                    continue
            raise

    if not new_streams:
        replacement: Any = empty_stream(backend)
    elif len(new_streams) == 1 and not redaction_rects:
        replacement = new_streams[0]
    else:
        if redaction_rects:
            new_streams.append(build_redaction_stream(backend, redaction_rects))
        replacement = backend.ArrayObject(new_streams)

    if changed:
        replace_page_contents(page, replacement, backend)

    return changed, removed, fallback_count


def apply_changes(
    writer: Any,
    analysis: AnalysisResult,
    backend: Backend,
    fallback_redact: bool,
    *,
    warnings: list[str] | None = None,
) -> ApplyResult:
    """Apply all selected candidate removals to the writer pages."""
    result = ApplyResult()
    selected_occurrences: dict[int, list[Occurrence]] = defaultdict(list)

    for group in analysis.selected_groups:
        for occurrence in group.occurrences:
            selected_occurrences[occurrence.page_index].append(occurrence)

    for page_index, occurrences in selected_occurrences.items():
        page = writer.pages[page_index]
        changed, removed, fallback_count = apply_occurrences_to_page(
            page=page,
            occurrences=occurrences,
            backend=backend,
            fallback_redact=fallback_redact,
            page_number=page_index + 1,
            warnings=warnings,
        )
        if changed:
            result.changed_pages += 1
        result.structurally_removed_occurrences += removed
        result.fallback_redactions += fallback_count

    if warnings is not None:
        result.warnings.extend(warnings)

    return result


def pages_preview(pages: list[int], limit: int = 12) -> str:
    """Format a compact page list preview for terminal output."""
    if len(pages) <= limit:
        return ", ".join(str(page) for page in pages)
    head = ", ".join(str(page) for page in pages[:limit])
    return f"{head}, …"


def format_candidate_rows(group: CandidateGroup, total_pages: int, verbose: bool) -> list[tuple[str, str]]:
    """Format one candidate group into display rows for the terminal UI."""
    rows = [
        ("Status", f"{group.decision.value.upper()} ({group.confidence.value.upper()})"),
        ("Kind", group.kind.value),
        ("Pages", pages_preview(group.affected_pages)),
        ("Coverage", f"{len(group.affected_pages)}/{total_pages} pages ({group.coverage:.0%})"),
        ("Operators", group.op_preview),
        ("Position", group.position_preview),
    ]

    if group.text_examples:
        rows.append(("Text", group.text_examples[0]))
    if group.explicit_matches:
        rows.append(("Matches", ", ".join(group.explicit_matches)))

    reasons = group.reasons if verbose else group.reasons[:2]
    for index, reason in enumerate(reasons, start=1):
        rows.append((f"Why {index}", reason))

    return rows


def print_analysis(analysis: AnalysisResult, options: ToolOptions) -> None:
    """Print a structured terminal summary of the analysis results."""
    summary_rows = [
        ("App", f"{APP_NAME} {APP_VERSION}"),
        ("Mode", "Dry run" if options.dry_run else "Write output"),
        ("Input", str(options.input_pdf)),
        ("Pages", str(analysis.total_pages)),
        ("Candidates", str(len(analysis.groups))),
        ("Selected", str(len(analysis.selected_groups))),
    ]
    if options.match_texts:
        summary_rows.append(("Match text", "; ".join(options.match_texts)))
    if analysis.warnings:
        summary_rows.append(("Warnings", str(len(analysis.warnings))))

    print(render_box("PDF Watermark Analysis", summary_rows))

    if not analysis.groups:
        print_status("warn", "No repeated watermark candidates were detected.")
        return

    if analysis.warnings and options.verbose:
        print(render_box("Analysis Warnings", [("Item", warning) for warning in analysis.warnings[:8]]))
        print()

    print()
    for group in analysis.groups:
        if not options.verbose and group.decision is not Decision.REMOVE and not options.dry_run:
            continue
        title = f"Candidate {group.group_id}"
        print(render_box(title, format_candidate_rows(group, analysis.total_pages, options.verbose)))
        print()


def group_to_dict(group: CandidateGroup) -> dict[str, Any]:
    """Convert a candidate group into a JSON-serializable report record."""
    return {
        "id": group.group_id,
        "kind": group.kind.value,
        "pages": group.affected_pages,
        "coverage": round(group.coverage, 4),
        "occurrences": len(group.occurrences),
        "score": group.score,
        "confidence": group.confidence.value,
        "decision": group.decision.value,
        "removal_mode": group.removal_mode.value,
        "strong_overlay_cue": group.strong_overlay_cue,
        "variable_text": group.variable_text,
        "operators": group.op_preview,
        "position": group.position_preview,
        "text_examples": group.text_examples,
        "text_patterns": group.text_patterns,
        "exact_matches": group.explicit_matches,
        "reasons": group.reasons,
    }


def merged_warnings(
    analysis: AnalysisResult,
    apply_result: ApplyResult | None = None,
) -> list[str]:
    """Return stable deduplicated warnings from analysis and apply phases."""
    apply_warnings = [] if apply_result is None else apply_result.warnings
    return list(dict.fromkeys(analysis.warnings + apply_warnings))


def build_report(
    options: ToolOptions,
    analysis: AnalysisResult,
    apply_result: ApplyResult | None = None,
) -> dict[str, Any]:
    """Build the JSON report payload for dry-run or write mode."""
    warning_list = merged_warnings(analysis, apply_result)
    return {
        "input_pdf": str(options.input_pdf),
        "output_pdf": str(options.output_pdf) if options.output_pdf is not None else None,
        "dry_run": options.dry_run,
        "match_texts": options.match_texts,
        "fallback_redact": options.fallback_redact,
        "strategy": STRATEGY_TEXT,
        "limitations": LIMITATIONS_TEXT,
        "warnings": warning_list,
        "summary": {
            "pages_analyzed": analysis.total_pages,
            "candidate_groups": len(analysis.groups),
            "selected_groups": len(analysis.selected_groups),
            "selected_pages": sorted(
                {page for group in analysis.selected_groups for page in group.affected_pages}
            ),
        },
        "application": None
        if apply_result is None
        else {
            "changed_pages": apply_result.changed_pages,
            "structurally_removed_occurrences": apply_result.structurally_removed_occurrences,
            "fallback_redactions": apply_result.fallback_redactions,
        },
        "candidates": [group_to_dict(group) for group in analysis.groups],
    }


def write_report(report_path: Path, report: dict[str, Any]) -> None:
    """Write the structured analysis report to disk."""
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    """Run the CLI entrypoint and return a process exit code."""
    options = parse_args(argv or sys.argv[1:])

    try:
        validate_paths(options)
        backend = load_pdf_backend()
        print_status("info", f"Using backend: {backend.module_name}")
        processor = WatermarkProcessor(backend=backend, options=options)
        reader = open_reader(options.input_pdf, backend)
        analysis = processor.analyze_document(reader)
        print_analysis(analysis, options)

        report = build_report(options, analysis)
        if options.report_path is not None:
            write_report(options.report_path, report)
            print_status("ok", f"Report written to: {options.report_path}")

        if options.dry_run:
            print_status("ok", "Dry run completed. No PDF content was modified.")
            return 0

        if options.output_pdf is None:
            raise ToolError("An output path is required unless --dry-run is used.")

        writer = create_writer(reader, backend)
        apply_result = processor.apply_changes(writer=writer, analysis=analysis)

        with options.output_pdf.open("wb") as handle:
            writer.write(handle)

        print()
        print(
            render_box(
                "Write Result",
                [
                    ("Output", str(options.output_pdf)),
                    ("Pages modified", str(apply_result.changed_pages)),
                    (
                        "Structural removals",
                        str(apply_result.structurally_removed_occurrences),
                    ),
                    ("Fallback redactions", str(apply_result.fallback_redactions)),
                    ("Warnings", str(len(merged_warnings(analysis, apply_result)))),
                ],
            )
        )

        if options.report_path is not None:
            write_report(options.report_path, build_report(options, analysis, apply_result))
            print_status("ok", f"Updated report written to: {options.report_path}")

        return 0
    except ToolError as exc:
        print_status("error", str(exc), stream=sys.stderr)
        return 2
    except Exception as exc:
        print_status("error", f"Unexpected failure: {exc}", stream=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
