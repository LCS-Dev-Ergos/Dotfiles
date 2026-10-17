"""What a person reads, in the terminal style every shell tool shares.

A report opens with the masthead, shows the user files and each Insiders
profile, then whatever needs attention, the changes a run would make, and a
summary. ``to_json`` is the same content for programs.
"""

from collections import Counter
from collections.abc import Sequence

import terminal_style as ui
from terminal_style import Cell, Column, Row

from . import PROG
from .plan import (
    ACTION_TONES,
    Action,
    AdoptFolder,
    Decision,
    Install,
    ItemStatus,
    LinkFolder,
    LinkItem,
    Operation,
    Plan,
    Quarantine,
    RestoreFolder,
    RestoreItem,
    UnlinkFolder,
    UnlinkItem,
    WriteFile,
    scope_order,
)

ITEM_TONES = {
    ItemStatus.LINKED: "ok",
    ItemStatus.INDEPENDENT: "pending",
    ItemStatus.MISSING: "pending",
    ItemStatus.BROKEN: "pending",
    ItemStatus.FOREIGN: "warn",
    ItemStatus.NO_SOURCE: "muted",
}

ITEM_DETAILS = {
    ItemStatus.LINKED: "",
    ItemStatus.INDEPENDENT: "Insiders' own file; setup links it",
    ItemStatus.MISSING: "setup links it",
    ItemStatus.BROKEN: "Stable has none; setup removes the link",
    ItemStatus.FOREIGN: "links elsewhere; left alone",
    ItemStatus.NO_SOURCE: "Stable has none",
}

_PENDING = (
    Action.LINK,
    Action.REBIND,
    Action.RELOCATE,
    Action.RESTORE,
    Action.INSTALL,
)
_QUIET = (Action.SHARED, Action.NATIVE)

TITLES = {
    "status": "Stable → {}",
    "check": "Stable → {}",
    "setup": "Share with {}",
    "update": "Update and share with {}",
    "remove": "Stop sharing with {}",
    "clean": "Clean duplicates",
}
"""Report titles; ``{}`` is the consumer's name."""

HINTS = {
    "status": f"{PROG} setup applies them",
    "check": f"{PROG} setup applies them",
    "setup": f"{PROG} setup applies them",
    "update": f"{PROG} update applies them",
    "remove": f"{PROG} remove applies them",
    "clean": f"{PROG} clean applies them",
}


def render(
    plan: Plan, style: ui.Style, *, context: str = "", changes: bool = True
) -> list[str]:
    """The report of a plan, from the masthead to the summary.

    Args:
        plan: What was found and what would change.
        style: How to draw.
        context: Shown at the right of the masthead, such as "dry run".
        changes: Whether to list every change, not only count them.
    """
    label = _label(plan)
    scopes = {decision.scope for decision in plan.decisions}
    subtitle = ""
    if plan.decisions:
        subtitle = (
            f"{len(plan.decisions)} {label} entries in "
            f"{len(scopes)} profile{'s' * (len(scopes) != 1)}"
        )
    title = TITLES[plan.command].format(label)
    lines = ui.header(style, PROG, title, subtitle, context=context)
    if plan.command in ("status", "check", "setup", "update"):
        if plan.items:
            lines += ["", *_items(plan, style)]
        if plan.decisions:
            lines += ["", *_profiles(plan, style)]
    lines += _sections(plan, style)
    if changes and plan.changed:
        lines += ["", *render_changes(plan, style)]
    lines += ["", *_summary(plan, style)]
    return lines


def render_changes(plan: Plan, style: ui.Style) -> list[str]:
    """A section listing each change: downloads first, as a run makes them."""
    columns = [
        Column("Change"),
        Column("What", shrink=24),
        Column("Detail", priority=50, shrink=16),
    ]
    rows = [
        Row(list(_install(item, _label(plan))), "pending")
        for item in plan.installs
    ]
    rows += [
        Row(list(_change(operation)), "pending")
        for operation in plan.operations
    ]
    title = ui.section(style, "Changes", str(len(rows)))
    return title + ui.table(style, columns, rows)


def event(style: ui.Style, tone: str, text: str) -> str:
    """One line of progress, such as a line VS Code's update printed."""
    text = ui.sanitize(text)
    if not style.styled:
        return text
    lead = " " * (ui.GUTTER + ui.INDENT)
    return f"{lead}{style.marker(tone)} {text}"


def notice(
    style: ui.Style, tone: str, title: str, lines: Sequence[str] = ()
) -> list[str]:
    """A notice set off from the report, such as the result of a run."""
    return ui.callout(style, tone, title, lines)


def to_json(plan: Plan) -> dict[str, object]:
    """The plan for programs: every decision, finding and change."""
    return {
        "command": plan.command,
        "consumer": plan.consumer.value if plan.consumer else None,
        "changed": plan.changed,
        "problems": plan.problems,
        "items": [
            {
                "name": item.name,
                "status": item.status.value,
                "source": str(item.source),
                "target": str(item.target),
                "link": item.link,
            }
            for item in plan.items
        ],
        "decisions": [
            {
                "profile": decision.scope,
                "extension": decision.extension_id,
                "folder": decision.folder,
                "target": decision.target,
                "action": decision.action.value,
                "detail": decision.detail,
            }
            for decision in plan.decisions
        ],
        "findings": [
            {
                "tone": finding.tone,
                "subject": finding.subject,
                "text": finding.text,
            }
            for finding in plan.findings
        ],
        "changes": [
            *(
                {
                    "kind": "download",
                    "extension": item.extension_id,
                    "version": item.version,
                }
                for item in plan.installs
            ),
            *(_change_json(operation) for operation in plan.operations),
        ],
    }


def _items(plan: Plan, style: ui.Style) -> list[str]:
    """The user files and how each relates to Stable's."""
    columns = [
        Column("File"),
        Column("State"),
        Column("Detail", priority=50, shrink=16),
    ]
    rows = [
        Row(
            [item.name, item.status.value, ITEM_DETAILS[item.status]],
            ITEM_TONES[item.status],
        )
        for item in plan.items
    ]
    return ui.section(style, "User files", str(len(rows))) + ui.table(
        style, columns, rows
    )


def _profiles(plan: Plan, style: ui.Style) -> list[str]:
    """One row per consumer profile: what it shares, what is due."""
    by_scope: dict[str, Counter[str]] = {}
    for decision in plan.decisions:
        counts = by_scope.setdefault(decision.scope, Counter())
        counts[_bucket(decision.action)] += 1
    columns = [
        Column("Profile", shrink=12),
        Column("Shared"),
        Column("Pending"),
        Column("Own", priority=60),
        Column("Attention", priority=70),
    ]
    rows: list[Row] = []
    for scope in sorted(by_scope, key=scope_order):
        counts = by_scope[scope]
        tone = "ok"
        if counts["error"]:
            tone = "error"
        elif counts["warn"]:
            tone = "warn"
        elif counts["pending"]:
            tone = "pending"
        attention = counts["error"] + counts["warn"]
        rows.append(
            Row(
                [
                    scope,
                    str(counts["shared"]),
                    str(counts["pending"]),
                    str(counts["own"]),
                    str(attention),
                ],
                tone,
            )
        )
    title = f"{_label(plan)} profiles"
    return ui.section(style, title, str(len(rows))) + ui.table(
        style, columns, rows
    )


def _sections(plan: Plan, style: ui.Style) -> list[str]:
    """Entries with work due, then problems, then notes."""
    due: list[Row] = []
    attention: list[Row] = []
    notes: list[Row] = []
    for decision in sorted(plan.decisions, key=_decision_order):
        if decision.action in _QUIET:
            continue
        what = decision.extension_id
        if decision.target != decision.folder:
            what = f"{decision.folder} → {decision.target}"
        tone = ACTION_TONES[decision.action]
        row = Row(
            [what, decision.scope, decision.action.value, decision.detail],
            tone,
        )
        (due if tone == "pending" else attention).append(row)
    for finding in plan.findings:
        row = Row([finding.subject, "", "", finding.text], finding.tone)
        (notes if finding.tone == "muted" else attention).append(row)
    columns = [
        Column("Extension", shrink=24),
        Column("Profile", priority=60, shrink=10),
        Column("State"),
        Column("Detail", priority=50, shrink=16, fold=("error", "warn")),
    ]
    lines: list[str] = []
    for title, rows in (
        ("Due", due),
        ("Needs attention", attention),
        ("Notes", notes),
    ):
        if rows:
            lines += ["", *ui.section(style, title, str(len(rows)))]
            lines += ui.table(style, columns, rows)
    return lines


def _summary(plan: Plan, style: ui.Style) -> list[str]:
    """The closing counts and the next step."""
    buckets = Counter(_bucket(decision.action) for decision in plan.decisions)
    tones = Counter(finding.tone for finding in plan.findings)
    counts = [
        ("ok", buckets["shared"], "shared"),
        ("pending", plan.size, "changes"),
        ("warn", buckets["warn"] + tones["warn"], "warnings"),
        ("error", buckets["error"] + tones["error"], "problems"),
    ]
    hint = HINTS[plan.command] if plan.changed else "nothing to do"
    return ui.summary(style, counts, hint)


def _bucket(action: Action) -> str:
    """Which column of a profile row an action counts in."""
    if action is Action.SHARED:
        return "shared"
    if action is Action.NATIVE:
        return "own"
    if action in _PENDING:
        return "pending"
    return ACTION_TONES[action]


def _decision_order(decision: Decision) -> tuple[int, tuple[int, str], str]:
    """Problems first, then by profile and extension."""
    severity = ("error", "warn", "pending", "muted", "ok")
    tone = ACTION_TONES[decision.action]
    return severity.index(tone), scope_order(decision.scope), decision.folder


def _change(operation: Operation) -> tuple[str | Cell, ...]:
    """The cells of one change."""
    if isinstance(operation, LinkFolder):
        return "link", operation.name, "to Stable's folder"
    if isinstance(operation, RestoreFolder):
        return "copy", operation.name, "from Stable's folder"
    if isinstance(operation, UnlinkFolder):
        return "unlink", operation.name, "no profile uses it"
    if isinstance(operation, AdoptFolder):
        return "adopt", operation.name, "the downloaded build"
    if isinstance(operation, LinkItem):
        return "link", operation.name, "to Stable's"
    if isinstance(operation, RestoreItem):
        return "copy", operation.name, "from Stable's"
    if isinstance(operation, UnlinkItem):
        return "unlink", operation.name, "Stable has none"
    if isinstance(operation, WriteFile):
        return "write", operation.label, Cell(str(operation.path), path=True)
    return "quarantine", operation.name, operation.edition.label


def _label(plan: Plan) -> str:
    """The name of the plan's consumer."""
    return plan.consumer.label if plan.consumer else "Insiders"


def _install(item: Install, label: str) -> tuple[str, str, str]:
    """The cells of one download."""
    version = f"@{item.version}" if item.version else ""
    return "download", f"{item.extension_id}{version}", f"with {label}"


def _change_json(operation: Operation) -> dict[str, object]:
    """One change for programs."""
    kinds = {
        LinkFolder: "link-folder",
        RestoreFolder: "restore-folder",
        UnlinkFolder: "unlink-folder",
        AdoptFolder: "adopt-folder",
        LinkItem: "link-item",
        RestoreItem: "restore-item",
        UnlinkItem: "unlink-item",
        WriteFile: "write-file",
        Quarantine: "quarantine",
    }
    change: dict[str, object] = {"kind": kinds[type(operation)]}
    if isinstance(operation, WriteFile):
        change.update(label=operation.label, path=str(operation.path))
    else:
        change.update(name=operation.name, path=str(operation.path))
    if isinstance(operation, LinkFolder | LinkItem):
        change["target"] = str(operation.target)
    if isinstance(operation, RestoreFolder | RestoreItem | AdoptFolder):
        change["source"] = str(operation.source)
    if isinstance(operation, Quarantine):
        change["edition"] = operation.edition.value
    return change
