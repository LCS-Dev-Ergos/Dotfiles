"""What a person reads, in the terminal style every shell tool shares.

Styled output fits the terminal; plain output (``NO_COLOR``, a pipe, a dumb
terminal) keeps every value whole and uncolored, so a captured report can
be read and copied from. ``doctor_json`` is the health report for programs.
"""

from collections import Counter
from collections.abc import Sequence
from datetime import datetime

import terminal_style as ui
from terminal_style import Cell, Column, Row

from . import DOCTOR, TOOLCHAIN
from .compilers import Entry
from .deep import Deep
from .doctor import Conflict, Record, State, Updates
from .host import Host, Platform
from .registry import Group
from .sdk import Survey

_LOG = {
    "info": ("[INFO]  ", "info", ui.ACCENT),
    "ok": ("[OK]    ", "done", ui.TONES["ok"]),
    "warn": ("[WARN]  ", "pending", ui.TONES["warn"]),
    "error": ("[ERROR] ", "error", ui.TONES["error"]),
}
_DEEP_TONES = {
    "ok": "ok",
    "external": "muted",
    "blocked": "warn",
    "missing": "warn",
    "present": "warn",
}


def log(style: ui.Style, level: str, text: str) -> str:
    """One leveled line: ``[OK]    text`` plain, a colored mark styled."""
    label, glyph, color = _LOG[level]
    text = ui.sanitize(text)
    if not style.styled:
        return f"{label}{text}"
    return f"{' ' * ui.GUTTER}{style.paint(color, ui.GLYPH[glyph])} {text}"


def _plural(count: int, word: str, plural: str = "") -> str:
    """``1 word`` or ``n words``."""
    return f"{count} {word if count == 1 else plural or word + 's'}"


# Health Report ----------------------------------------------------------------


def doctor_report(
    style: ui.Style,
    host: Host,
    records: Sequence[Record],
    conflicts: Sequence[Conflict],
    deep: Deep | None,
    *,
    updates: Updates | None,
    now: datetime,
) -> list[str]:
    """The health report: masthead, runtimes, conflicts, updates, deep health
    and tally; ``updates`` is what ``--updates`` found, if it ran."""
    groups = {record.runtime.group for record in records}
    runtimes = _plural(len(records), "runtime")
    subtitle = f"{runtimes} in {_plural(len(groups), 'group')}"
    lines = ui.header(
        style,
        DOCTOR,
        "Development Environment",
        subtitle,
        context=host.description,
        note=now.strftime("%Y-%m-%d %H:%M"),
    )
    lines.append("")
    if not records:
        lines.append(log(style, "warn", "No runtime matched the selection."))
    elif style.styled:
        lines += _runtimes_styled(style, records)
    else:
        lines += _runtimes_plain(records)
    if conflicts:
        lines += ["", *_conflicts(style, conflicts)]
    if updates is not None:
        lines += ["", *_updates(style, records, updates)]
    if deep is not None:
        lines += ["", *_deep(style, deep)]
    lines += ["", *_tally(style, records, conflicts, deep, updates)]
    return lines


def _runtimes_plain(records: Sequence[Record]) -> list[str]:
    """One untruncated table with a group column."""
    columns = [
        Column(label)
        for label in (
            "Group",
            "ID",
            "Runtime",
            "State",
            "Active",
            "Origin",
            "Detail",
        )
    ]
    rows = [
        Row(
            [
                record.runtime.group.title,
                record.runtime.id,
                record.runtime.label,
                record.state.value.upper(),
                record.active,
                record.origin,
                record.detail,
            ]
        )
        for record in records
    ]
    return ui.table(ui.Style(False), columns, rows)


def _runtimes_styled(style: ui.Style, records: Sequence[Record]) -> list[str]:
    """Grouped status lines that fit the terminal.

    Each line is a marker, the label, its id for ``--only``, the active
    version, where the binary comes from and a detail. On a narrow
    terminal the id goes first, then the version shortens, then the origin
    goes, then the label shortens. A healthy row shortens its detail; any
    other keeps its state on the line and continues the detail beneath.
    """
    indent = " " * (ui.GUTTER + ui.INDENT)
    widths = {
        "label": max(ui.text_width(r.runtime.label) for r in records),
        "id": max(ui.text_width(r.runtime.id) for r in records),
        "active": min(max(ui.text_width(r.active) for r in records), 18),
        "origin": max(ui.text_width(r.origin) for r in records),
    }
    least = 8
    show_id = show_origin = True
    room = style.width - len(indent) - 2 - 8 - ui.GUTTER - sum(widths.values())

    def shorten(key: str) -> None:
        """Give the detail up to what the column has beyond 10 cells."""
        nonlocal room
        if room < least and widths[key] > 10:
            cut = min(least - room, widths[key] - 10)
            widths[key] -= cut
            room += cut

    if room < least:
        show_id, room = False, room + widths["id"] + 2
    shorten("active")
    if room < least:
        show_origin, room = False, room + widths["origin"] + 2
    shorten("label")
    room = max(room, least)

    def cell(text: str, width: int) -> str:
        """A padded cell; ``-`` reads as a muted dash."""
        shown = ui.truncate(text, width)
        padding = " " * (width - ui.text_width(shown))
        if text == "-":
            return f"{style.paint(ui.MUTED, '—')}{padding}"
        return f"{shown}{padding}"

    counts = Counter(record.runtime.group for record in records)
    lines: list[str] = []
    current: Group | None = None
    for record in records:
        group = record.runtime.group
        if group is not current:
            if current is not None:
                lines.append("")
            current = group
            lines += ui.section(style, group.title, str(counts[group]))
        tone = record.state.tone
        text = f"{indent}{style.marker(tone, record.state.value)} "
        text += cell(record.runtime.label, widths["label"])
        if show_id:
            text += "  " + style.paint(
                ui.MUTED, ui.pad(record.runtime.id, widths["id"])
            )
        text += "  " + cell(record.active, widths["active"])
        if show_origin:
            text += "  " + cell(record.origin, widths["origin"])
        detail = ui.short_path(ui.sanitize(record.detail), style)
        word = record.state.value
        folded: list[str] = []
        if record.state is State.OK:
            if detail and detail != "Runtime starts":
                text += "  " + style.paint(ui.MUTED, ui.truncate(detail, room))
        elif (
            not detail
            or ui.text_width(word) + ui.text_width(detail) + 3 <= room
        ):
            more = f" · {detail}" if detail else ""
            text += f"  {style.paint(ui.TONES[tone], word)}"
            text += style.paint(ui.MUTED, more)
        else:
            text += f"  {style.paint(ui.TONES[tone], word)}"
            width = style.width - len(indent) - 2 - ui.GUTTER
            folded = ui.wrap(detail, width)
        lines.append(text.rstrip())
        lines += [
            f"{indent}  {style.paint(ui.MUTED, piece)}" for piece in folded
        ]
    return lines


def _conflicts(style: ui.Style, conflicts: Sequence[Conflict]) -> list[str]:
    """PATH conflicts: a shadowed binary informs, anything else needs action."""
    title = ui.section(style, "PATH conflicts", str(len(conflicts)))
    if not style.styled:
        columns = [Column("Kind"), Column("Subject"), Column("Detail")]
        rows = [Row([c.kind, c.subject, c.detail]) for c in conflicts]
        return title + ui.table(style, columns, rows)
    indent = " " * (ui.GUTTER + ui.INDENT)
    lead = len(indent) + 2
    w_kind = max(ui.text_width(c.kind) for c in conflicts)
    w_subject = max(ui.text_width(c.subject) for c in conflicts)
    w_subject = min(w_subject, style.width // 2)
    room = style.width - lead - w_kind - 2 - ui.GUTTER
    w_subject = min(w_subject, room)
    room -= w_subject + 2
    lines = list(title)
    for conflict in conflicts:
        tone = "warn" if conflict.rank == 0 else "pending"
        subject = ui.truncate(
            ui.short_path(conflict.subject, style), w_subject
        )
        detail = ui.short_path(conflict.detail, style)
        text = f"{indent}{style.marker(tone)} {ui.pad(conflict.kind, w_kind)}"
        text += f"  {subject}"
        if detail and ui.text_width(detail) <= room:
            gap = " " * (w_subject - ui.text_width(subject))
            lines.append(f"{text}{gap}  {style.paint(ui.MUTED, detail)}")
            continue
        lines.append(text)
        width = style.width - lead - ui.GUTTER
        lines += [
            f"{indent}  {style.paint(ui.MUTED, piece)}"
            for piece in ui.wrap(detail, width)
        ]
    return lines


def _deep(style: ui.Style, deep: Deep) -> list[str]:
    """dev-bootstrap's health check, one row per runtime."""
    title = ui.section(style, "Deep health", str(len(deep.rows)))
    if deep.error:
        level = "error" if deep.level > 1 else "warn"
        message = f"dev-bootstrap verify --health: {deep.error}"
        return [*title, log(style, level, message)]
    columns = [
        Column("Runtime", shrink=16),
        Column("State"),
        Column("Version", shrink=10),
        Column("Detail", priority=50, shrink=16, fold=("error", "warn")),
    ]
    rows = [
        Row(
            [row.title, row.state, row.version, row.detail],
            _DEEP_TONES.get(row.state, "error"),
        )
        for row in deep.rows
    ]
    return title + ui.table(style, columns, rows)


def _tally(
    style: ui.Style,
    records: Sequence[Record],
    conflicts: Sequence[Conflict],
    deep: Deep | None,
    updates: Updates | None,
) -> list[str]:
    """The count of each state and what to do next."""
    counts = Counter(record.state for record in records)
    shown = [(state, counts[state]) for state in State if counts[state]]
    worst = doctor_status(records, conflicts, deep)
    if style.styled:
        hint = ""
        if updates is None:
            hint = f"{DOCTOR} --updates checks for new releases"
        entries = [(state.tone, count, state.value) for state, count in shown]
        return ui.summary(style, entries, hint)
    lines: list[str] = []
    if shown:
        words = ", ".join(f"{count} {state.value}" for state, count in shown)
        level = ("ok", "warn", "error")[worst]
        ending = "." if worst == 0 else "; review the flagged entries."
        lines.append(log(style, level, f"{words}{ending}"))
    if updates is None:
        message = f"Run '{DOCTOR} --updates' for native update checks."
        lines.append(log(style, "info", message))
    return lines


_SOURCES = {"brew": "Homebrew", "rustup": "rustup"}


def _updates(
    style: ui.Style, records: Sequence[Record], found: Updates
) -> list[str]:
    """What each update source answered, so an empty answer reads as one.

    Homebrew's outdated packages, formulae and casks alike, split into
    those a row tracks, which the table marks ``outdated``, and the rest,
    which only ``brew upgrade`` concerns.
    """
    when = datetime.fromtimestamp(found.time).strftime("%H:%M")
    note = f"cached {when}" if found.cached else f"asked {when}"
    lines = ui.section(style, "Updates", note)
    if not found.checked and not found.failed:
        message = "No manager here has a native update check."
        return [*lines, log(style, "info", message)]
    tracked = {r.runtime.formula for r in records if r.runtime.formula}
    for source in found.checked:
        if source == "brew":
            here = sorted(found.formulas & tracked)
            other = sorted(found.formulas - tracked)
            parts = [
                f"Outdated here: {', '.join(here)}"
                if here
                else "Nothing outdated among the runtimes above"
            ]
            if other:
                parts.append(
                    f"{_plural(len(other), 'other package')}"
                    f" ({_names(other)}); brew upgrade updates them"
                )
            level = "warn" if here else "ok"
            text = "; ".join(parts)
        else:
            due = source in found.managers
            level = "warn" if due else "ok"
            text = "Update available" if due else "Up to date"
        lines += _paragraph(style, level, f"{_SOURCES[source]}: {text}.")
    for source, reason in found.failed:
        message = f"{_SOURCES[source]}: No answer. {reason}."
        lines += _paragraph(style, "warn", message)
    message = (
        "Other managers have no machine-readable check and are not asked."
    )
    if found.cached:
        message += f" {DOCTOR} --refresh asks again."
    return [*lines, *_paragraph(style, "info", message)]


def _paragraph(style: ui.Style, level: str, text: str) -> list[str]:
    """A leveled line, wrapped to the terminal when styled."""
    if not style.styled:
        return [log(style, level, text)]
    room = style.width - 2 * ui.GUTTER - 2
    first, *rest = ui.wrap(ui.sanitize(text), room)
    lead = " " * (ui.GUTTER + 2)
    return [log(style, level, first), *(f"{lead}{line}" for line in rest)]


def _names(items: Sequence[str], limit: int = 5) -> str:
    """The first ``limit`` names, then how many more."""
    shown = ", ".join(items[:limit])
    rest = len(items) - limit
    return f"{shown} and {rest} more" if rest > 0 else shown


def doctor_status(
    records: Sequence[Record],
    conflicts: Sequence[Conflict],
    deep: Deep | None,
) -> int:
    """The exit status: 2 if anything is broken, 1 if anything is doubtful."""
    ranks = [record.state.rank for record in records]
    ranks += [conflict.rank for conflict in conflicts]
    if deep is not None:
        ranks.append(deep.rank)
    return max(ranks, default=0)


def doctor_json(
    records: Sequence[Record],
    conflicts: Sequence[Conflict],
    deep: Deep | None,
    updates: Updates | None = None,
) -> dict[str, object]:
    """The health report for programs."""
    report: dict[str, object] = {
        "managers": [
            {
                "id": record.runtime.id,
                "label": record.runtime.label,
                "state": record.state.value,
                "active": record.active,
                "origin": record.origin,
                "detail": record.detail,
                "group": record.runtime.group.value,
            }
            for record in records
        ],
        "conflicts": [
            {"kind": c.kind, "subject": c.subject, "detail": c.detail}
            for c in conflicts
        ],
    }
    if updates is not None:
        report["updates"] = {
            "checked": list(updates.checked),
            "failed": [
                {"source": source, "reason": reason}
                for source, reason in updates.failed
            ],
            "time": updates.time,
            "cached": updates.cached,
            "formulas": sorted(updates.formulas),
            "managers": sorted(updates.managers),
        }
    if deep is not None:
        report["deep"] = {
            "error": deep.error or None,
            "runtimes": [
                {
                    "runtime": row.title,
                    "state": row.state,
                    "version": row.version,
                    "detail": row.detail,
                }
                for row in deep.rows
            ],
        }
    return report


# Compilers --------------------------------------------------------------------


def info_report(
    style: ui.Style, host: Host, entries: Sequence[Entry], debug: bool
) -> list[str]:
    """Which compilers PATH finds, what they really are, and the overrides."""
    lines = ui.header(
        style,
        TOOLCHAIN,
        "C/C++ toolchain",
        "Active compiler resolution",
        context=host.label,
    )
    overrides = [(name, host.get(name)) for name in ("CC", "CXX")]
    overrides = [(name, value) for name, value in overrides if value]
    if overrides:
        lines += ["", *ui.section(style, "Environment overrides")]
        lines += ui.table(
            style,
            [Column("Variable"), Column("Value")],
            [Row([name, Cell(value, path=True)]) for name, value in overrides],
        )
    rows: list[Row] = []
    for entry in entries:
        if entry.path is None or entry.identity is None:
            cells = [entry.name, "Missing", "-", "-", "Not found in PATH"]
            rows.append(Row(cells, "error"))
            continue
        status, tone = "Available", "ok"
        if entry.masquerade:
            status, tone = f"Warning: resolves to {entry.masquerade}", "warn"
        rows.append(
            Row(
                [
                    entry.name,
                    status,
                    entry.identity.toolchain,
                    entry.identity.version or "Unknown",
                    Cell(entry.resolution, path=True),
                ],
                tone,
            )
        )
    columns = [
        Column("Compiler"),
        Column("Status", shrink=9),
        Column("Toolchain", priority=60, shrink=12),
        Column("Version"),
        Column("Resolution", priority=50, shrink=20),
    ]
    lines += ["", *ui.section(style, "Compilers in PATH", str(len(rows)))]
    lines += ui.table(style, columns, rows)
    if debug:
        debug_rows = [
            Row(
                [
                    entry.name,
                    entry.wrapper.kind.value if entry.wrapper else "-",
                    entry.wrapper.vendor if entry.wrapper else "-",
                    entry.wrapper.banner if entry.wrapper else "-",
                    Cell(str(entry.real or "-"), path=True),
                ]
            )
            for entry in entries
            if entry.path is not None
        ]
        columns = [
            Column("Compiler"),
            Column("Wrapper type"),
            Column("Wrapper vendor", priority=70),
            Column("Wrapper version", priority=60, shrink=16),
            Column("Real path", priority=50, shrink=20),
        ]
        lines += ["", *ui.section(style, "Debug details")]
        lines += ui.table(style, columns, debug_rows)
    found = sum(1 for entry in entries if entry.path is not None)
    missing = len(entries) - found
    text = f"{_plural(found, 'compiler')} available"
    if missing:
        text += f"; {missing} missing"
    lines += ["", log(style, "warn" if missing else "ok", f"{text}.")]
    return lines


def sdk_report(
    style: ui.Style, host: Host, survey: Survey, everything: bool
) -> list[str]:
    """Which headers the active compiler reaches next to the system one."""
    lines = ui.header(
        style,
        TOOLCHAIN,
        "SDK reachability",
        "What the active C compiler can include with no extra flags",
        context=host.label,
    )
    active = " ".join(survey.active)
    fields: list[tuple[str, Cell | str]] = [
        ("Active compiler", Cell(active, path=True))
    ]
    if survey.system is not None:
        fields.append(("System compiler", Cell(str(survey.system), path=True)))
    lines += ["", *ui.card(style, "Compilers", fields)]
    if survey.active[0].startswith("/nix/store/"):
        lines.append(
            log(
                style,
                "warn",
                "CC is pinned to a Nix store generation; profile updates do "
                "not change it.",
            )
        )
    macos = host.platform is Platform.MACOS
    compare = survey.system is not None
    rows: list[Row] = []
    for reach in survey.reaches:
        if compare and not everything and not reach.diverges:
            continue
        cells = [reach.header, "reachable" if reach.active else "missing"]
        if compare:
            cells.append("reachable" if reach.system else "missing")
        cells.append(reach.purpose)
        if macos:
            cells.append(reach.hint)
        tone = "ok" if reach.active else "error" if reach.diverges else "muted"
        rows.append(Row(cells, tone))
    if rows:
        columns = [Column("Header"), Column("Active")]
        if compare:
            columns.append(Column("System"))
        columns.append(Column("Used by", priority=60, shrink=16))
        if macos:
            columns.append(Column("Homebrew alternative", priority=50))
        lines += ["", *ui.section(style, "Libraries", str(len(rows)))]
        lines += ui.table(style, columns, rows)
    lines.append("")
    if not compare:
        lines.append(
            log(style, "info", "No system compiler at /usr/bin/cc to compare.")
        )
    elif survey.divergent:
        count = _plural(survey.divergent, "library", "libraries")
        lines.append(
            log(
                style,
                "warn",
                f"{count} the system compiler sees out of reach here.",
            )
        )
        lines.append(
            log(
                style,
                "info",
                "Check the compiler and SDK selection before adding library "
                "search paths.",
            )
        )
    else:
        lines.append(
            log(
                style,
                "ok",
                "The active compiler reaches everything the system one does.",
            )
        )
    lines.append(
        log(
            style,
            "info",
            "Header-only probe: missing does not prove a library needs "
            "installation.",
        )
    )
    if macos:
        lines.append(
            log(
                style,
                "info",
                "Apple's ffi.h needs the SDK's usr/include/ffi search path.",
            )
        )
    return lines
