"""The scan's report: drawn for the terminal, and as JSON for programs.

The terminal report leads with the layers and what each could do, then the
files that need a look, worst first, then what could not be scanned. Clean
files stay out of the way unless asked for. Every path and message passes
through the shared style, which escapes control characters: a file name is
untrusted text.
"""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import terminal_style as ui
from terminal_style import Cell, Column, Note, Row

from . import PROG, __version__
from .files import Selection
from .findings import Result, Severity

_STATES = {"ran": "ok", "off": "muted", "unavailable": "warn"}
_STATES |= {"absent": "muted", "failed": "error"}


@dataclass
class Layer:
    """A layer and how it fared.

    ``state`` is ``ran``, ``off`` (turned off), ``absent`` (not installed),
    ``unavailable`` (installed but unable to scan) or ``failed``; ``fix``
    says what makes it work, and a layer that ran can still carry one.
    """

    name: str
    state: str
    detail: str
    fix: str = ""

    def to_json(self) -> dict[str, object]:
        """The layer as a JSON object."""
        payload: dict[str, object] = {
            "name": self.name,
            "state": self.state,
            "detail": self.detail,
        }
        if self.fix:
            payload["fix"] = self.fix
        return payload


@dataclass
class Scan:
    """Everything a finished scan knows."""

    paths: Sequence[Path]
    selection: Selection
    results: list[Result]
    layers: list[Layer]
    started: datetime

    @property
    def flagged(self) -> list[Result]:
        """Files with a warning or worse, worst first."""
        return sorted(
            (result for result in self.results if result.flagged),
            key=_order,
        )

    @property
    def noted(self) -> list[Result]:
        """Files whose findings are information only."""
        return [
            result
            for result in self.results
            if result.findings and not result.flagged
        ]

    @property
    def clean(self) -> list[Result]:
        """Files every layer that ran finished on, without a finding."""
        return [
            result
            for result in self.results
            if not result.findings and not result.errors
        ]

    @property
    def unscanned(self) -> list[tuple[Path, list[str]]]:
        """Paths and files that were not, or not fully, scanned."""
        return [
            (path, [reason]) for path, reason in self.selection.problems
        ] + [
            (result.path, result.errors)
            for result in self.results
            if result.errors
        ]

    @property
    def complete(self) -> bool:
        """Whether every file was scanned by every layer meant to run."""
        return not (
            self.unscanned
            or any(layer.state == "failed" for layer in self.layers)
        )

    @property
    def status(self) -> int:
        """The exit status: 1 flagged, 2 incomplete, 0 otherwise."""
        if self.flagged:
            return 1
        return 0 if self.complete else 2


def _order(result: Result) -> tuple[int, str]:
    """Worst first, then by path."""
    worst = result.worst
    return (-(worst.rank if worst else -1), str(result.path))


# Terminal ---------------------------------------------------------------------


def render(
    style: ui.Style, scan: Scan, *, verbose: bool = False, quiet: bool = False
) -> list[str]:
    """The whole report, or with ``quiet`` its summary alone."""
    if quiet:
        return _summary(style, scan)
    ran = sum(layer.state == "ran" for layer in scan.layers)
    subtitle = [_count(len(scan.results), "file"), _count(ran, "layer")]
    skipped = scan.selection.skipped
    if skipped["link"]:
        subtitle.append(f"{_count(skipped['link'], 'link')} not followed")
    if skipped["special"]:
        subtitle.append(
            f"{_count(skipped['special'], 'special file')} skipped"
        )
    lines = ui.header(
        style,
        PROG,
        "Security scan",
        " · ".join(subtitle),
        context=_target(style, scan.paths),
        note=scan.started.strftime("%Y-%m-%d %H:%M"),
    )
    lines += ["", *_layers(style, scan.layers)]
    if scan.flagged or scan.noted:
        lines += ["", *_findings(style, scan.flagged + scan.noted)]
    if scan.unscanned:
        lines += ["", *_unscanned(style, scan.unscanned)]
    if verbose and scan.clean:
        lines += ["", *_clean(style, scan.clean)]
    return lines + [""] + _summary(style, scan)


def event(style: ui.Style, tone: str, text: str) -> str:
    """One line after the report, such as where the JSON report went."""
    text = ui.sanitize(text)
    if not style.styled:
        return text
    return f"{' ' * ui.GUTTER}{style.marker(tone)} {text}"


def _target(style: ui.Style, paths: Sequence[Path]) -> str:
    """What was scanned: the one path, or how many."""
    if len(paths) == 1:
        return ui.short_path(str(paths[0]), style)
    return f"{len(paths)} paths"


def _layers(style: ui.Style, layers: Sequence[Layer]) -> list[str]:
    """Each layer, its state and what would fix it."""
    rows = [
        Row(
            [layer.name, layer.detail],
            _STATES[layer.state],
            [Note(layer.fix, label="fix")] if layer.fix else [],
        )
        for layer in layers
    ]
    columns = [Column("Layer"), Column("State", shrink=20)]
    return ui.section(style, "Layers") + ui.table(style, columns, rows)


def _findings(style: ui.Style, results: Sequence[Result]) -> list[str]:
    """The files with findings, each finding under its file."""
    rows = []
    for result in results:
        worst = result.worst or Severity.INFO
        width = max(len(finding.check) for finding in result.findings)
        notes = [
            Note(
                finding.message,
                ui.TONES[finding.severity.tone] if style.styled else "",
                finding.check.ljust(width) if style.styled else finding.check,
            )
            for finding in sorted(
                result.findings, key=lambda finding: -finding.severity.rank
            )
        ]
        rows.append(
            Row(
                [Cell(str(result.path), path=True), worst.value],
                worst.tone,
                notes,
            )
        )
    columns = [Column("File", shrink=24), Column("Severity")]
    title = ui.section(style, "Findings", _count(len(rows), "file"))
    return title + ui.table(style, columns, rows)


def _unscanned(
    style: ui.Style, entries: Sequence[tuple[Path, list[str]]]
) -> list[str]:
    """Paths that were not, or not fully, scanned, and why."""
    rows = [
        Row(
            [Cell(str(path), path=True)],
            "error",
            [Note(reason) for reason in reasons],
        )
        for path, reasons in entries
    ]
    title = ui.section(style, "Not fully scanned", str(len(rows)))
    return title + ui.table(style, [Column("Path", shrink=24)], rows)


def _clean(style: ui.Style, results: Sequence[Result]) -> list[str]:
    """The clean files, with the layers that looked at each."""
    rows = [
        Row(
            [Cell(str(result.path), path=True), ", ".join(result.layers)],
            "ok",
        )
        for result in results
    ]
    columns = [Column("File", shrink=24), Column("Layers", priority=50)]
    title = ui.section(style, "Clean", str(len(rows)))
    return title + ui.table(style, columns, rows)


def _summary(style: ui.Style, scan: Scan) -> list[str]:
    """The count of each outcome, and what to do next."""
    worst = [result.worst for result in scan.results]
    critical = worst.count(Severity.CRITICAL)
    warnings = worst.count(Severity.WARNING)
    counts = [
        ("error", critical, "critical"),
        ("warn", warnings, "suspicious"),
        ("muted", worst.count(Severity.INFO), "with notes"),
        ("ok", len(scan.clean), "clean"),
        ("error", len(scan.unscanned), "not fully scanned"),
    ]
    if scan.flagged:
        hint = "Review the flagged files before opening them"
    elif not scan.complete:
        hint = "The scan is incomplete"
    elif not scan.results:
        hint = "Nothing to scan"
    else:
        hint = ""
    tone = "ok" if scan.complete else "error"
    return ui.summary(style, counts, hint, tone)


def _count(number: int, noun: str) -> str:
    """``1 noun`` or ``n nouns``."""
    return f"{number} {noun if number == 1 else noun + 's'}"


# JSON -------------------------------------------------------------------------


def to_json(scan: Scan) -> dict[str, object]:
    """The report for programs: layers, every file and every gap."""
    return {
        "tool": PROG,
        "version": __version__,
        "started": scan.started.isoformat(timespec="seconds"),
        "complete": scan.complete,
        "status": scan.status,
        "layers": [layer.to_json() for layer in scan.layers],
        "files": [result.to_json() for result in scan.results],
        "not_scanned": [
            {"path": str(path), "reason": reason}
            for path, reason in scan.selection.problems
        ],
        "skipped": {
            kind: count
            for kind, count in scan.selection.skipped.items()
            if count
        },
    }
