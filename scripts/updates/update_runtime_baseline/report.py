"""Findings as a terminal table or as a Markdown job summary."""

from collections.abc import Iterable, Sequence

from .model import Finding, Kind

COLUMNS = ("ecosystem", "pinned", "available", "state", "note")
Errors = Sequence[tuple[str, str]]


def rows(findings: Iterable[Finding]) -> list[tuple[str, ...]]:
    return [
        (f.name, f.pinned, f.available or "-", str(f.kind), f.note)
        for f in findings
    ]


def render_text(findings: Sequence[Finding], errors: Errors) -> str:
    table = [COLUMNS, *rows(findings)]
    widths = [max(len(row[i]) for row in table) for i in range(4)]
    lines = []
    for row in table:
        cells = [
            cell.ljust(width)
            for cell, width in zip(row[:4], widths, strict=True)
        ]
        lines.append("  ".join([*cells, row[4]]).rstrip())
    lines += [f"error    {name}: {message}" for name, message in errors]
    return "\n".join(lines)


def render_markdown(findings: Sequence[Finding], errors: Errors) -> str:
    actionable = sum(f.actionable for f in findings)
    lines = [
        "## Runtime baseline freshness",
        "",
        f"{actionable} actionable, {len(errors)} source errors.",
        "",
        "| " + " | ".join(c.capitalize() for c in COLUMNS) + " |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in rows(f for f in findings if f.kind != Kind.CURRENT):
        cells = [cell.replace("|", "\\|") for cell in row]
        lines.append("| " + " | ".join(cells) + " |")
    lines += [f"- Error in {name}: {message}" for name, message in errors]
    return "\n".join(lines)
