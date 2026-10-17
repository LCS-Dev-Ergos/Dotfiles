"""Format plans, writes and resolutions for the terminal."""

import difflib

from . import PROG, __version__
from .host import Host
from .manifest import LEAVES
from .plan import ChangeAction, FindingKind, Plan
from .storage import WriteResult

_VALUE_WIDTH = 96
_UNMANAGED_WIDTH = 80

_SECTIONS = (
    (FindingKind.UNRESOLVED, "Not found on this machine (left as they are):"),
    (FindingKind.ABSENT, "Not present in the file (nothing to update):"),
    (FindingKind.NOTICE, "Notes:"),
    (FindingKind.UNMANAGED, "Host-bound values the tool does not manage:"),
)


def shorten(value: str | None, width: int = _VALUE_WIDTH) -> str:
    """``value`` cut to ``width`` characters, or a marker for no value."""
    if value is None:
        return "(absent)"
    return value if len(value) <= width else f"{value[: width - 3]}..."


def render_plan(plan: Plan, *, dry_run: bool) -> str:
    """The changes and findings of a plan, headed by the file's path."""
    lines = [str(plan.path)]
    if not plan.changed:
        lines.append(
            "  Everything managed is already correct for this machine."
        )
    for change in plan.changes:
        if change.action is ChangeAction.ADD:
            lines += [
                f"  add     {change.subject}",
                f"            {shorten(change.new)}",
            ]
        else:
            lines += [
                f"  update  {change.subject}",
                f"            {shorten(change.old)}",
                f"         -> {shorten(change.new)}",
            ]
    for kind, heading in _SECTIONS:
        findings = plan.of_kind(kind)
        if not findings:
            continue
        lines.append(f"  {heading}")
        for finding in findings:
            if kind is FindingKind.ABSENT:
                lines.append(f"    {finding.subject}")
            elif kind is FindingKind.UNMANAGED:
                value = shorten(finding.detail, _UNMANAGED_WIDTH)
                lines.append(f"    {finding.subject} = {value}")
            else:
                lines.append(f"    {finding.subject}: {finding.detail}")
    if plan.changed and dry_run:
        lines.append("  `apply` without --dry-run would change this file.")
    return "\n".join(lines)


def render_diff(plan: Plan) -> str:
    """The exact text change of a plan as a unified diff."""
    return "".join(
        difflib.unified_diff(
            plan.old_text.splitlines(keepends=True),
            plan.new_text.splitlines(keepends=True),
            "before",
            "after",
        )
    )


def render_write(result: WriteResult) -> str:
    """The outcome of a write, or nothing when nothing was written."""
    if not result.written:
        return ""
    if result.backup is None:
        return "  written; the backup taken for the run is removed"
    return f"  written; the previous file is still at {result.backup}"


def render_resolution(host: Host) -> str:
    """What every managed top-level key resolves to on ``host``."""
    user = host.user or "(unknown)"
    lines = [f"{PROG} {__version__}: {host.platform.value}, user {user}"]
    for leaf in LEAVES:
        found = leaf.resolver.resolve(host)
        value = (
            found
            if found is not None
            else f"(not found: {leaf.resolver.hint})"
        )
        lines += [f"  {leaf.key}", f"    {value}"]
    return "\n".join(lines)
