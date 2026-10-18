"""The ``pdf-tools`` command line: one subcommand per task.

Exit status: 0 on success, 1 when the task fails (a missing or locked file,
an output that exists without ``--force``), 2 for a usage error, including a
page selection the document does not have, and 130 when interrupted.
"""

import argparse
import json
import os
import sys
import tempfile
from collections import Counter
from collections.abc import Mapping, Sequence
from contextlib import ExitStack
from pathlib import Path

import pikepdf
import terminal_style as ui
from terminal_style import Cell, Column, Note, Row

from . import PROG, __version__, converters, metadata, outline, pages
from . import passwords, watermarks
from .documents import (
    Locked,
    ToolError,
    UsageError,
    check_target,
    compact,
    destination,
    first_line,
    lossless,
    open_pdf,
    parse_pages,
    replacing,
    save,
    size,
    unrestricted,
)
from .output import change, human, name, plural, say, show

_DESCRIPTION = (
    "Work with PDF documents: inspect them, choose, turn, join and split "
    "pages, compress them, protect or unlock them, strip their metadata, "
    "copy bookmarks, remove watermarks and convert DjVu. Outputs are new "
    "files next to the input unless -o names one; nothing is overwritten "
    "without --force, and the input only with --in-place."
)

_EPILOG = f"""\
Examples:
  {PROG} info book.pdf
  {PROG} extract book.pdf 5-10,12 -o excerpt.pdf
  {PROG} rotate scan.pdf right 1-3 --in-place
  {PROG} merge part1.pdf part2.pdf -o book.pdf
  {PROG} compress book.pdf --quality medium
  {PROG} metadata strip *.pdf --in-place
  {PROG} watermarks book.pdf --dry-run

Pages are counted from 1: 5, 5-10, 1-3,7,10-z (z is the last page), 10-1
(backwards). Run {PROG} COMMAND --help for a command's options.
"""


# Parser -----------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    """The subcommands and their options."""
    parser = ui.ArgumentParser(
        prog=PROG,
        description=_DESCRIPTION,
        epilog=_EPILOG,
        version=f"{PROG} {__version__}",
    )
    commands = parser.add_subparsers(
        dest="command", metavar="COMMAND", title="Commands", required=True
    )

    info = _command(commands, "info", "Show what a PDF holds and its problems")
    info.add_argument(
        "files", nargs="+", type=Path, metavar="FILE", help="The PDFs"
    )

    extract = _command(commands, "extract", "Keep only the chosen pages")
    _file(extract)
    extract.add_argument("pages", metavar="PAGES", help="Pages to keep")
    _outputs(extract, in_place=False)

    delete = _command(commands, "delete", "Remove the chosen pages")
    _file(delete)
    delete.add_argument("pages", metavar="PAGES", help="Pages to remove")
    _outputs(delete)

    rotate = _command(commands, "rotate", "Turn pages")
    _file(rotate)
    rotate.add_argument(
        "angle",
        choices=sorted(pages.ANGLES),
        metavar="ANGLE",
        help="Right, left or 180 (also 90, -90 and 270)",
    )
    rotate.add_argument(
        "pages",
        nargs="?",
        default="1-z",
        metavar="PAGES",
        help="Pages to turn (default: all)",
    )
    _outputs(rotate)

    merge = _command(commands, "merge", "Join PDFs into one")
    merge.add_argument(
        "files",
        nargs="+",
        type=Path,
        metavar="FILE",
        help="The PDFs, in order",
    )
    merge.add_argument(
        "-o",
        "--output",
        type=Path,
        required=True,
        metavar="FILE",
        help="The joined PDF",
    )
    merge.add_argument(
        "--no-bookmarks",
        dest="bookmarks",
        action="store_false",
        help="Do not add a bookmark for each file",
    )
    _force(merge)

    split = _command(commands, "split", "Split a PDF into parts")
    _file(split)
    cut = split.add_mutually_exclusive_group()
    cut.add_argument(
        "--every",
        type=_positive,
        metavar="N",
        help="Start a new part every N pages (default: 1)",
    )
    cut.add_argument(
        "--at", metavar="PAGES", help="Start a new part at these pages"
    )
    split.add_argument(
        "-o",
        "--output",
        type=Path,
        metavar="FOLDER",
        help="The folder for the parts (default: FILE_parts)",
    )
    _force(split)

    compress = _command(commands, "compress", "Make a PDF smaller")
    _file(compress)
    compress.add_argument(
        "-q",
        "--quality",
        choices=("lossless", "high", "medium", "low"),
        default="lossless",
        metavar="LEVEL",
        help="Lossless (default) keeps every pixel; high, medium and low "
        "resample images with Ghostscript",
    )
    compress.add_argument(
        "--linearize",
        action="store_true",
        help="Order the file for viewing while it downloads",
    )
    _outputs(compress)

    for command, text in (
        ("protect", "Lock a PDF with a password (AES-256)"),
        ("unlock", "Remove a PDF's password and restrictions"),
    ):
        locking = _command(commands, command, text)
        _file(locking)
        locking.add_argument(
            "--password-file",
            type=Path,
            metavar="FILE",
            help="Read the password from FILE instead of asking",
        )
        _outputs(locking)

    meta = _command(commands, "metadata", "Show or strip metadata")
    meta_commands = meta.add_subparsers(
        dest="action", metavar="ACTION", title="Actions", required=True
    )
    meta_show = _command(meta_commands, "show", "List the metadata")
    _file(meta_show)
    strip = _command(
        meta_commands, "strip", "Remove all metadata, rewriting the files"
    )
    strip.add_argument(
        "files", nargs="+", type=Path, metavar="FILE", help="The PDFs"
    )
    _outputs(strip)

    marks = _command(commands, "bookmarks", "Show or copy bookmarks")
    mark_commands = marks.add_subparsers(
        dest="action", metavar="ACTION", title="Actions", required=True
    )
    marks_show = _command(mark_commands, "show", "List the bookmarks")
    _file(marks_show)
    copy = _command(
        mark_commands, "copy", "Copy one PDF's bookmarks onto another"
    )
    copy.add_argument(
        "source", type=Path, metavar="SOURCE", help="The PDF with bookmarks"
    )
    copy.add_argument(
        "file", type=Path, metavar="TARGET", help="The PDF that receives them"
    )
    _outputs(copy)

    marks_off = _command(
        commands, "watermarks", "Find and remove repeated overlays"
    )
    _file(marks_off)
    marks_off.add_argument(
        "-o",
        "--output",
        type=Path,
        metavar="FILE",
        help="The cleaned PDF (default: FILE_cleaned.pdf)",
    )
    marks_off.add_argument(
        "-n",
        "--dry-run",
        action="store_true",
        help="Report the candidates without writing a PDF",
    )
    marks_off.add_argument(
        "--match-text",
        action="append",
        default=[],
        metavar="TEXT",
        help="Favour overlays holding this text (repeatable)",
    )
    marks_off.add_argument(
        "--report",
        type=Path,
        metavar="FILE",
        help="Also write the analysis to FILE as JSON",
    )
    marks_off.add_argument(
        "--redact",
        action="store_true",
        help="Cover an overlay with white when its stream cannot be edited",
    )
    marks_off.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="List kept candidates and every reason",
    )
    _force(marks_off)

    djvu = _command(commands, "from-djvu", "Convert a DjVu document")
    _file(djvu, "The DjVu document")
    djvu.add_argument(
        "-o",
        "--output",
        type=Path,
        metavar="FILE",
        help="The PDF (default: FILE with .pdf)",
    )
    _force(djvu)
    return parser


def _command(commands, name: str, text: str) -> argparse.ArgumentParser:
    """A subcommand whose help and description are the same sentence."""
    return commands.add_parser(name, help=text, description=f"{text}.")


def _file(parser: argparse.ArgumentParser, text: str = "The PDF") -> None:
    """The input file argument."""
    parser.add_argument("file", type=Path, metavar="FILE", help=text)


def _force(parser: argparse.ArgumentParser) -> None:
    """--force."""
    parser.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Replace an output that exists",
    )


def _outputs(
    parser: argparse.ArgumentParser, *, in_place: bool = True
) -> None:
    """-o, --in-place and --force."""
    where = parser.add_mutually_exclusive_group()
    where.add_argument(
        "-o",
        "--output",
        type=Path,
        metavar="FILE",
        help="Where to write (default: next to the input)",
    )
    if in_place:
        where.add_argument(
            "-i",
            "--in-place",
            action="store_true",
            help="Replace the input",
        )
    _force(parser)


def _positive(text: str) -> int:
    """A positive integer option value."""
    if not text.isdigit() or int(text) < 1:
        raise argparse.ArgumentTypeError("Must be a positive integer")
    return int(text)


# Running ----------------------------------------------------------------------


def main(
    argv: Sequence[str] | None = None,
    environ: Mapping[str, str] | None = None,
    style: ui.Style | None = None,
) -> int:
    """Run the command line; the exit status."""
    args = build_parser().parse_args(argv)
    env = dict(os.environ if environ is None else environ)
    style = style or ui.Style.detect()
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(errors="backslashreplace")
    handler = _HANDLERS[(args.command, getattr(args, "action", None))]
    try:
        return handler(args, env, style)
    except ToolError as error:
        say(style, "error", str(error))
        return error.status
    except pikepdf.PdfError as error:
        say(style, "error", first_line(error))
        return 1
    except OSError as error:
        place = f"{error.filename}: " if error.filename else ""
        say(style, "error", f"{place}{error.strerror or error}")
        return 1
    except KeyboardInterrupt:
        say(style, "error", "Interrupted; no file was left half written")
        return 130


def _written(style: ui.Style, target: Path, *details: str) -> None:
    """Report a written file."""
    say(style, "ok", " · ".join([f"Wrote {name(target, style)}", *details]))


def _target(args: argparse.Namespace, suffix: str) -> Path:
    """The checked output of a one-file command."""
    in_place = getattr(args, "in_place", False)
    target = destination(args.file, suffix, args.output, in_place=in_place)
    check_target(
        target, force=args.force, in_place=in_place, sources=(args.file,)
    )
    return target


def _mode(args: argparse.Namespace) -> Path | None:
    """The file whose mode an in-place write keeps."""
    return args.file if getattr(args, "in_place", False) else None


def _info(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Describe each PDF."""
    status = 0
    for index, path in enumerate(args.files):
        if index:
            print()
        try:
            with open_pdf(path) as pdf:
                show(_card(pdf, path, style))
        except ToolError as error:
            say(style, "error", str(error))
            status = 1
    return status


_SIZES = {
    "A3": (842, 1191),
    "A4": (595, 842),
    "A5": (420, 595),
    "Letter": (612, 792),
    "Legal": (612, 1008),
}


def _card(pdf: pikepdf.Pdf, path: Path, style: ui.Style) -> list[str]:
    """One PDF's facts, then its problems."""
    boxes = Counter(_page_size(page) for page in pdf.pages)
    common = boxes.most_common(1)[0][0] if boxes else "none"
    if len(boxes) > 1:
        common += f" (and {plural(len(boxes) - 1, 'other size')})"
    fields: list[tuple[str, Cell | str]] = [
        ("Pages", str(len(pdf.pages))),
        ("Page size", common),
        ("Version", f"PDF {pdf.pdf_version}"),
        ("Size", human(size(path))),
        ("Protection", _protection(pdf)),
    ]
    info = {
        str(key).removeprefix("/"): str(value)
        for key, value in (
            pdf.docinfo.items() if "/Info" in pdf.trailer else []
        )
    }
    for key in ("Title", "Author", "Producer"):
        if info.get(key):
            fields.append((key, info[key]))
    fields.append(
        ("Bookmarks", str(sum(m.count() for m in outline.read(pdf))))
    )
    fields.append(("Attachments", str(len(pdf.attachments))))
    fields.append(("Forms", "yes" if "/AcroForm" in pdf.Root else "no"))
    fields.append(("Linearized", "yes" if pdf.is_linearized else "no"))
    lines = ui.card(style, name(path, style), fields)
    problems = pdf.check_pdf_syntax()
    if problems:
        lines += [
            "",
            *ui.callout(
                style, "warn", plural(len(problems), "problem"), problems[:10]
            ),
        ]
    return lines


def _page_size(page: pikepdf.Page) -> str:
    """A page's size, by name when it has one."""
    box = page.mediabox
    width = abs(float(box[2]) - float(box[0]))
    height = abs(float(box[3]) - float(box[1]))
    for label, (short, long) in _SIZES.items():
        for w, h in ((short, long), (long, short)):
            if abs(width - w) <= 2 and abs(height - h) <= 2:
                turned = " landscape" if w > h else ""
                return f"{label}{turned}"
    mm = 25.4 / 72
    return f"{width * mm:.0f} × {height * mm:.0f} mm"


_METHODS = {"aesv3": "AES-256", "aesv2": "AES-128", "rc4": "RC4"}


def _protection(pdf: pikepdf.Pdf) -> str:
    """How a PDF is protected."""
    if not pdf.is_encrypted:
        return "none"
    denied = [
        word
        for word, allowed in (
            ("printing", pdf.allow.print_highres),
            ("copying", pdf.allow.extract),
            ("editing", pdf.allow.modify_other),
        )
        if not allowed
    ]
    method = _METHODS.get(pdf.encryption.stream_method.name, "Encrypted")
    if denied:
        return f"{method}; owner forbids {', '.join(denied)}"
    return method


def _extract(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Keep the chosen pages."""
    with open_pdf(args.file) as pdf:
        order = parse_pages(args.pages, len(pdf.pages))
        target = destination(args.file, f"pages_{compact(order)}", args.output)
        check_target(target, force=args.force, sources=(args.file,))
        result = pages.rebuild(pdf, order)
        save(result, target)
    _written(style, target, plural(len(order), "page"))
    return 0


def _delete(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Remove the chosen pages."""
    target = _target(args, "trimmed")
    with open_pdf(args.file) as pdf:
        removed = parse_pages(args.pages, len(pdf.pages))
        order = pages.without(len(pdf.pages), removed)
        result = pages.rebuild(pdf, order)
        save(result, target, keep_mode_of=_mode(args))
    _written(
        style,
        target,
        f"removed {plural(len(set(removed)), 'page')}",
        f"{len(order)} left",
    )
    return 0


def _rotate(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Turn pages."""
    target = _target(args, "rotated")
    with open_pdf(args.file) as pdf:
        chosen = parse_pages(args.pages, len(pdf.pages))
        pages.rotate(pdf, pages.ANGLES[args.angle], chosen)
        save(pdf, target, keep_mode_of=_mode(args))
    _written(style, target, f"turned {plural(len(set(chosen)), 'page')}")
    return 0


def _merge(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Join PDFs."""
    check_target(args.output, force=args.force, sources=tuple(args.files))
    with ExitStack() as stack:
        result = pages.merge(args.files, stack, bookmarks=args.bookmarks)
        save(result, args.output)
        count = len(result.pages)
    _written(
        style,
        args.output,
        plural(len(args.files), "file"),
        plural(count, "page"),
    )
    return 0


def _split(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Split a PDF into parts in a folder."""
    folder = args.output or args.file.with_name(f"{args.file.stem}_parts")
    if folder.exists() and not folder.is_dir():
        raise ToolError(f"{folder} exists and is not a folder")
    if folder.exists() and any(folder.iterdir()) and not args.force:
        raise ToolError(f"{folder} is not empty; --force writes into it")
    with open_pdf(args.file) as pdf:
        unrestricted(pdf)
        count = len(pdf.pages)
        starts = parse_pages(args.at, count) if args.at else []
        chunks = pages.parts(count, args.every, starts)
        folder.mkdir(parents=True, exist_ok=True)
        width = len(str(len(chunks)))
        for number, chunk in enumerate(chunks, start=1):
            part = folder / f"{args.file.stem}_{number:0{width}d}.pdf"
            check_target(part, force=args.force)
            save(pages.rebuild(pdf, chunk), part)
    say(
        style,
        "ok",
        f"Wrote {plural(len(chunks), 'part')} to {name(folder, style)}",
    )
    return 0


def _compress(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Make a PDF smaller, keeping the smaller of two rewrites."""
    target = _target(args, "compressed")
    before = size(args.file)
    options = lossless(linearize=args.linearize)
    with open_pdf(args.file) as pdf:
        if args.quality == "lossless":
            save(pdf, target, keep_mode_of=_mode(args), **options)
            after, note = size(target), ""
        else:
            if pdf.is_encrypted:
                raise ToolError(
                    f"{args.file} has an owner password, which Ghostscript "
                    "would drop; use --quality lossless, or unlock it first"
                )
            after, note = _lossy(args, env, pdf, target, options)
    details = [change(before, after)]
    if note:
        details.append(note)
    _written(style, target, *details)
    return 0


def _lossy(
    args: argparse.Namespace,
    env: dict[str, str],
    pdf: pikepdf.Pdf,
    target: Path,
    options: dict[str, object],
) -> tuple[int, str]:
    """Ghostscript's rewrite, unless a lossless one is smaller."""
    with tempfile.TemporaryDirectory(prefix="pdf-tools.") as private:
        resampled = Path(private, "resampled.pdf")
        converters.ghostscript(args.file, resampled, args.quality, env)
        plain = Path(private, "lossless.pdf")
        pdf.save(plain, encryption=False, **options)
        with open_pdf(resampled) as smaller:
            packed = Path(private, "packed.pdf")
            smaller.save(packed, encryption=False, **options)
        if size(packed) < size(plain):
            chosen, note = packed, ""
        else:
            chosen, note = plain, "lossless was smaller than resampling"
        with open_pdf(chosen) as best:
            save(best, target, keep_mode_of=_mode(args), **options)
    return size(target), note


def _protect(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Lock a PDF with a password."""
    target = _target(args, "protected")
    with open_pdf(args.file) as pdf:
        if pdf.is_encrypted:
            raise ToolError(
                f"{args.file} is already protected; unlock it first"
            )
        password = passwords.ask(
            "New password", args.password_file, confirm=True
        )
        save(
            pdf,
            target,
            keep_mode_of=_mode(args),
            encryption=passwords.encryption(password),
        )
    _written(style, target, "locked with AES-256")
    return 0


def _unlock(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Remove a PDF's password and restrictions."""
    target = _target(args, "unlocked")
    try:
        pdf = open_pdf(args.file)
    except Locked:
        password = passwords.ask("Password", args.password_file)
        pdf = open_pdf(args.file, password)
    with pdf:
        if not pdf.is_encrypted:
            raise ToolError(f"{args.file} has no password or restrictions")
        save(pdf, target, keep_mode_of=_mode(args), encryption=False)
    _written(style, target, "unlocked")
    return 0


def _metadata_show(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """List a PDF's metadata."""
    with open_pdf(args.file) as pdf:
        found = metadata.entries(pdf)
        extra = metadata.hidden(pdf)
    title = ui.section(
        style, name(args.file, style), plural(len(found), "field")
    )
    if found:
        rows = [Row([e.key, Cell(e.value), e.source]) for e in found]
        columns = [Column("Key"), Column("Value", shrink=20), Column("In")]
        show(title + ui.table(style, columns, rows))
    else:
        show(title)
        say(style, "info", "No document information or XMP metadata")
    if extra:
        say(
            style,
            "info",
            f"Also {plural(extra, 'metadata record')} on pages, images "
            "or other objects; strip removes them too",
        )
    return 0


def _metadata_strip(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Strip every PDF's metadata."""
    if args.output is not None and len(args.files) > 1:
        raise UsageError(
            "-o names one output; use --in-place for several files"
        )
    failed = 0
    for path in args.files:
        try:
            target = destination(
                path, "stripped", args.output, in_place=args.in_place
            )
            check_target(
                target,
                force=args.force,
                in_place=args.in_place,
                sources=(path,),
            )
            with open_pdf(path) as pdf:
                removed = metadata.strip(pdf)
                save(
                    pdf,
                    target,
                    keep_mode_of=path if args.in_place else None,
                    deterministic_id=True,
                )
        except ToolError as error:
            say(style, "error", str(error))
            failed += 1
            continue
        parts = [
            plural(removed.fields, "field"),
            plural(removed.packets, "XMP packet"),
        ]
        if removed.application:
            parts.append(plural(removed.application, "application record"))
        _written(style, target, "removed " + ", ".join(parts))
    if len(args.files) > 1:
        level = "error" if failed else "ok"
        done = len(args.files) - failed
        say(
            style,
            level,
            f"{done} of {plural(len(args.files), 'file')} stripped",
        )
    return 1 if failed else 0


def _bookmarks_show(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """List a PDF's bookmarks with their pages."""
    with open_pdf(args.file) as pdf:
        marks = outline.read(pdf)
    entries = outline.flatten(marks)
    title = ui.section(
        style, name(args.file, style), plural(len(entries), "bookmark")
    )
    if not entries:
        show(title)
        say(style, "info", "No bookmarks")
        return 0
    rows = [
        Row(
            [
                str(mark.page + 1) if mark.page is not None else "—",
                f"{'  ' * depth}{mark.title}",
            ]
        )
        for depth, mark in entries
    ]
    columns = [Column("Page"), Column("Title", shrink=20)]
    show(title + ui.table(style, columns, rows))
    return 0


def _bookmarks_copy(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Copy one PDF's bookmarks onto another."""
    target = _target(args, "bookmarks")
    with open_pdf(args.source) as source:
        marks = outline.read(source)
    if not marks:
        raise ToolError(f"{args.source} has no bookmarks")
    with open_pdf(args.file) as pdf:
        written, dropped = outline.write(pdf, marks)
        save(pdf, target, keep_mode_of=_mode(args))
    details = [plural(written, "bookmark")]
    if dropped:
        details.append(f"{dropped} dropped: their pages are missing")
    _written(style, target, *details)
    return 0


def _watermarks(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Find repeated overlays and remove the certain ones."""
    target = None
    if not args.dry_run:
        target = args.output or args.file.with_name(
            f"{args.file.stem}_cleaned.pdf"
        )
        check_target(target, force=args.force, sources=(args.file,))
    if args.report is not None:
        if target is not None and args.report.absolute() == target.absolute():
            raise UsageError("--report and the cleaned PDF are the same file")
        check_target(args.report, force=args.force, sources=(args.file,))
    with open_pdf(args.file) as pdf:
        analysis = watermarks.Analyzer(args.match_text).analyze(pdf)
        show(_analysis(analysis, args, style))
        applied = None
        if target is not None and analysis.selected:
            applied = watermarks.apply(pdf, analysis, redact=args.redact)
            save(pdf, target)
    if args.report is not None:
        _report(args.report, analysis, applied, target)
        say(style, "ok", f"Report saved in {name(args.report, style)}")
    for warning in analysis.warnings + (applied.warnings if applied else []):
        say(style, "warn", warning)
    if target is None:
        say(style, "info", "Dry run: no PDF was written")
    elif applied is None:
        say(style, "info", "Nothing certain enough to remove; no PDF written")
    else:
        details = [
            f"removed {plural(applied.removed, 'overlay')}",
            f"on {plural(applied.pages, 'page')}",
        ]
        if applied.redacted:
            details.append(f"covered {applied.redacted}")
        _written(style, target, *details)
    return 0


def _analysis(
    analysis: watermarks.Analysis, args: argparse.Namespace, style: ui.Style
) -> list[str]:
    """The candidates: removed ones always, kept ones when verbose."""
    shown = [c for c in analysis.clusters if c.remove or args.verbose]
    title = ui.section(
        style,
        f"Watermark candidates in {name(args.file, style)}",
        f"{len(analysis.selected)} of {len(analysis.clusters)} selected",
    )
    if not shown:
        return title
    rows = []
    for cluster in shown:
        notes = []
        if cluster.texts:
            notes.append(Note(cluster.texts[0], label="text"))
        reasons = cluster.reasons if args.verbose else cluster.reasons[:2]
        notes += [Note(reason) for reason in reasons]
        rows.append(
            Row(
                [
                    str(cluster.number),
                    cluster.kind.value,
                    f"{len(cluster.pages)}/{analysis.pages}",
                    cluster.confidence.value,
                    "remove" if cluster.remove else "keep",
                ],
                "pending" if cluster.remove else "muted",
                notes,
            )
        )
    columns = [
        Column("#"),
        Column("Kind"),
        Column("Pages"),
        Column("Confidence", priority=50),
        Column("Decision"),
    ]
    return title + ui.table(style, columns, rows)


def _report(
    path: Path,
    analysis: watermarks.Analysis,
    applied: watermarks.Applied | None,
    target: Path | None,
) -> None:
    """Write the analysis as JSON, whole or not at all."""
    payload = {
        "tool": PROG,
        "version": __version__,
        "output": str(target) if applied is not None and target else None,
        "pages": analysis.pages,
        "warnings": analysis.warnings,
        "candidates": [cluster.to_json() for cluster in analysis.clusters],
        "applied": None
        if applied is None
        else {
            "pages": applied.pages,
            "removed": applied.removed,
            "covered": applied.redacted,
        },
    }
    try:
        with replacing(path) as temporary:
            temporary.write_text(json.dumps(payload, indent=2) + "\n")
    except OSError as error:
        raise ToolError(f"Cannot write {path}: {error.strerror}") from error


def _from_djvu(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Convert a DjVu document to PDF."""
    if not converters.is_djvu(args.file):
        raise ToolError(f"{args.file} is not a DjVu document")
    target = args.output or args.file.with_suffix(".pdf")
    check_target(target, force=args.force, sources=(args.file,))
    try:
        with replacing(target) as temporary:
            converters.djvu(args.file, temporary, env)
    except OSError as error:
        raise ToolError(f"Cannot write {target}: {error.strerror}") from error
    with open_pdf(target) as pdf:
        count = len(pdf.pages)
    _written(style, target, plural(count, "page"), human(size(target)))
    return 0


_HANDLERS = {
    ("info", None): _info,
    ("extract", None): _extract,
    ("delete", None): _delete,
    ("rotate", None): _rotate,
    ("merge", None): _merge,
    ("split", None): _split,
    ("compress", None): _compress,
    ("protect", None): _protect,
    ("unlock", None): _unlock,
    ("metadata", "show"): _metadata_show,
    ("metadata", "strip"): _metadata_strip,
    ("bookmarks", "show"): _bookmarks_show,
    ("bookmarks", "copy"): _bookmarks_copy,
    ("watermarks", None): _watermarks,
    ("from-djvu", None): _from_djvu,
}
