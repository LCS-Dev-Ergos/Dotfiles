"""The ``security-scan`` command line.

Exit status: 0 when every file was scanned by every layer that could run
and nothing was flagged; 1 when a file was flagged with a warning or worse,
even if the scan is incomplete; 2 when the scan is incomplete or cannot
run, or for a usage error; 130 when interrupted.
"""

import argparse
import json
import os
import sys
import tempfile
from collections.abc import Mapping, Sequence
from datetime import datetime
from pathlib import Path
from typing import TextIO

import terminal_style as ui

from . import PROG, __version__, antivirus, structural
from .files import open_regular, select, sha256
from .findings import LayerError, Result, ScanError
from .patterns import DEFAULT_RULES, Patterns
from .report import Layer, Scan, event, render, to_json

_DESCRIPTION = (
    "Scan files and folders for documents that carry more than they "
    "claim: a program under a document's name, a program hidden inside a "
    "file, a PDF that starts something when opened, an archive bundling "
    "scripts. Three layers look at every file: built-in structural checks, "
    "the bundled YARA rules and ClamAV, once freshclam has fetched its "
    "signatures. Files are only read, never changed or opened by another "
    "program."
)

_EPILOG = f"""\
Examples:
  {PROG} ~/Downloads/book.pdf            One file
  {PROG} ~/Books --report scan.json      A folder, with a JSON report
  {PROG} . --no-clamav --verbose         Quickly, listing clean files too

Exit status:
  0  Every file was scanned and nothing was flagged
  1  A file was flagged with a warning or worse
  2  The scan is incomplete or cannot run, or the usage is wrong
"""


def build_parser() -> argparse.ArgumentParser:
    """The arguments and options."""
    parser = ui.ArgumentParser(
        prog=PROG,
        description=_DESCRIPTION,
        epilog=_EPILOG,
        version=f"{PROG} {__version__}",
    )
    parser.add_argument(
        "paths",
        nargs="+",
        type=Path,
        metavar="PATH",
        help="Files and folders to scan",
    )
    parser.add_argument(
        "--no-recursive",
        dest="recursive",
        action="store_false",
        help="Scan only the files directly inside each folder",
    )
    layers = parser.add_argument_group("Layers")
    layers.add_argument(
        "--no-structural",
        dest="structural",
        action="store_false",
        help="Skip the structural checks",
    )
    layers.add_argument(
        "--no-yara", dest="yara", action="store_false", help="Skip YARA"
    )
    layers.add_argument(
        "--no-clamav", dest="clamav", action="store_false", help="Skip ClamAV"
    )
    layers.add_argument(
        "--yara-rules",
        type=Path,
        default=DEFAULT_RULES,
        metavar="FILE",
        help="Match the YARA rules in FILE instead of the bundled ones",
    )
    output = parser.add_argument_group("Output")
    output.add_argument(
        "--report",
        type=Path,
        metavar="FILE",
        help="Also write every result to FILE as JSON",
    )
    output.add_argument(
        "--hash",
        action="store_true",
        help="Add each file's SHA-256 to the JSON report",
    )
    detail = output.add_mutually_exclusive_group()
    detail.add_argument(
        "-v", "--verbose", action="store_true", help="List clean files too"
    )
    detail.add_argument(
        "-q", "--quiet", action="store_true", help="Print only the summary"
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    environ: Mapping[str, str] | None = None,
    style: ui.Style | None = None,
) -> int:
    """Run the command line; the exit status.

    A file name that is not valid UTF-8 reaches the terminal escaped, and
    the JSON report escapes every non-ASCII character, so neither can fail
    on one.
    """
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.hash and args.report is None:
        parser.error("--hash needs --report")
    if not (args.structural or args.yara or args.clamav):
        parser.error("Every layer is turned off")
    env = dict(os.environ if environ is None else environ)
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(errors="backslashreplace")
    try:
        return _run(args, env, style or ui.Style.detect())
    except ScanError as error:
        print(f"{PROG}: {ui.sanitize(error)}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print(f"{PROG}: Interrupted", file=sys.stderr)
        return 130


def _run(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Prepare the layers, scan, report; the exit status.

    Everything that can make the scan pointless (rules that do not
    compile, a report that cannot be written) is checked before the first
    file is read.
    """
    started = datetime.now()
    if args.report is not None:
        _check_destination(args.report)
    patterns = Patterns(args.yara_rules) if args.yara else None
    clamav, absent = antivirus.find(env) if args.clamav else (None, "")
    layers = _layers(args, patterns, clamav, absent, started)

    selection = select(args.paths, recursive=args.recursive)
    if args.report is not None:
        _check_overwrite(args.report, selection.files)
    progress = _Progress(style, not args.quiet)
    results = []
    try:
        for done, path in enumerate(selection.files, 1):
            progress.show("Scanning", done, len(selection.files), path)
            results.append(
                _scan_file(path, args.structural, patterns, args.hash)
            )
        if clamav is not None and results:
            layers[-1] = _clamav(clamav, results, env, progress, layers[-1])
    finally:
        progress.clear()

    scan = Scan(args.paths, selection, results, layers, started)
    print(
        "\n".join(render(style, scan, verbose=args.verbose, quiet=args.quiet))
    )
    if args.report is None:
        return scan.status
    try:
        _write_json(args.report, to_json(scan))
    except OSError as error:
        print(
            f"{PROG}: Cannot write {ui.sanitize(args.report)}: "
            f"{error.strerror or error}",
            file=sys.stderr,
        )
        return 1 if scan.flagged else 2
    if not args.quiet:
        print(event(style, "ok", f"Report saved in {args.report}"))
    return scan.status


def _layers(
    args: argparse.Namespace,
    patterns: Patterns | None,
    clamav: antivirus.ClamAV | None,
    absent: str,
    now: datetime,
) -> list[Layer]:
    """The three layers as they stand before the scan."""
    layers = [
        Layer("Structural", "ran", "Built in")
        if args.structural
        else Layer("Structural", "off", "Turned off")
    ]
    if patterns is not None:
        rules = f"{patterns.path.name} · {patterns.count} rules"
        layers.append(Layer("YARA", "ran", rules))
    else:
        layers.append(Layer("YARA", "off", "Turned off"))
    if not args.clamav:
        layers.append(Layer("ClamAV", "off", "Turned off"))
    elif clamav is None and absent == "Not installed":
        fix = "Install ClamAV, then run freshclam"
        layers.append(Layer("ClamAV", "absent", absent, fix))
    elif clamav is None:
        fix = "Run freshclam" if absent == "No signature database" else ""
        layers.append(Layer("ClamAV", "unavailable", absent, fix))
    else:
        updated = clamav.updated
        stamp = updated.strftime("%Y-%m-%d") if updated else "date unknown"
        detail = f"{clamav.version} · database {clamav.database} · {stamp}"
        stale = clamav.stale(now)
        fix = "Run freshclam: the database is over a week old" if stale else ""
        layers.append(Layer("ClamAV", "ran", detail, fix))
    return layers


def _scan_file(
    path: Path, structure: bool, patterns: Patterns | None, digest: bool
) -> Result:
    """The structural and YARA layers on one file.

    A crafted file can trip a parser in ways no list of exceptions
    foresees; that failure is the file's error, and the scan goes on.
    """
    result = Result(path)
    try:
        with open_regular(path) as handle:
            result.size = os.fstat(handle.fileno()).st_size
    except OSError as error:
        result.errors.append(f"Cannot read: {error.strerror or error}")
        return result
    if structure:
        try:
            result.findings += structural.check(path)
            result.layers.append("structural")
        except OSError as error:
            result.errors.append(f"Cannot read: {error.strerror or error}")
        except Exception as error:
            result.errors.append(
                f"Structural checks failed: {type(error).__name__}: {error}"
            )
    if patterns is not None:
        try:
            result.findings += patterns.match(path)
            result.layers.append("yara")
        except LayerError as error:
            result.errors.append(str(error))
    if digest:
        try:
            result.sha256 = sha256(path)
        except OSError as error:
            result.errors.append(f"Cannot hash: {error.strerror or error}")
    return result


def _clamav(
    clamav: antivirus.ClamAV,
    results: list[Result],
    env: Mapping[str, str],
    progress: "_Progress",
    layer: Layer,
) -> Layer:
    """ClamAV over every file; the layer, failed if the batch failed."""
    total = len(results)
    paths = [result.path for result in results]
    progress.show("ClamAV is loading its database", 0, total)
    try:
        outcome = antivirus.scan(
            clamav,
            paths,
            env,
            lambda done: progress.show("ClamAV", done, total),
        )
    except LayerError as error:
        return Layer(layer.name, "failed", str(error), layer.fix)
    for result in results:
        if result.path in outcome.errors:
            result.errors.append(outcome.errors[result.path])
            continue
        result.layers.append("clamav")
        result.findings += outcome.findings.get(result.path, [])
    return layer


def _check_destination(report: Path) -> None:
    """Refuse a report path that cannot be written, before scanning.

    Raises:
        ScanError: If the path is a folder or its folder is missing.
    """
    if report.is_dir():
        raise ScanError(f"--report names a folder: {report}")
    if not report.absolute().parent.is_dir():
        raise ScanError(f"--report's folder does not exist: {report.parent}")


def _check_overwrite(report: Path, files: Sequence[Path]) -> None:
    """Refuse a report path that is one of the files to scan.

    Raises:
        ScanError: If writing the report would replace a scanned file.
    """
    try:
        target = report.stat()
    except OSError:
        return
    for path in files:
        try:
            if os.path.samestat(target, path.stat()):
                raise ScanError(
                    f"--report would replace a scanned file: {path}"
                )
        except OSError:
            continue


def _write_json(report: Path, payload: dict[str, object]) -> None:
    """Write the report whole or not at all, readable only by its owner.

    The JSON goes to a private temporary file beside the target, which then
    replaces it: a reader never sees half a report, and an interrupted
    write leaves the old one.

    Raises:
        OSError: If the file cannot be written.
    """
    target = report.absolute()
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


class _Progress:
    """A line on a terminal's standard error that tracks the scan.

    It appears only on a styled terminal, rewrites itself in place, and
    is cleared before the report is printed.
    """

    def __init__(
        self, style: ui.Style, wanted: bool, stream: TextIO | None = None
    ) -> None:
        """Track on ``stream`` (standard error), when it is a terminal."""
        self.stream = sys.stderr if stream is None else stream
        isatty = getattr(self.stream, "isatty", None)
        self.style = style
        self.active = wanted and style.styled and bool(isatty and isatty())
        self.shown = False

    def show(
        self, label: str, done: int, total: int, path: Path | None = None
    ) -> None:
        """Rewrite the line: the label, the count and the current file."""
        if not self.active:
            return
        text = f"{label} {done}/{total}"
        if path is not None:
            text += f"  {ui.short_path(ui.sanitize(path), self.style)}"
        room = self.style.width - ui.GUTTER * 2 - 2
        marker = self.style.paint(ui.ACCENT, ui.GLYPH["info"])
        line = f"{' ' * ui.GUTTER}{marker} {ui.truncate(text, room)}"
        self.stream.write(f"\r\033[K{line}")
        self.stream.flush()
        self.shown = True

    def clear(self) -> None:
        """Remove the line."""
        if self.shown:
            self.stream.write("\r\033[K")
            self.stream.flush()
            self.shown = False
