"""``dev-doctor --deep``: dev-bootstrap's health check, read as a report.

``dev-bootstrap verify --health`` starts every global selection of the
ecosystems the bootstrap manages, loads the extensions that link host
libraries and runs a small program with each, without changing anything.
dev-doctor runs it, reads its JSON report (schema 1, which the bootstrap
keeps stable for frontends) and shows one row per runtime. No code of the
bootstrap is imported: the report is the whole interface.
"""

import json
from dataclasses import dataclass

from . import process
from .host import Host
from .jsondata import as_array, as_object

DEEP_TIMEOUT = 900.0
"""Seconds the health check may take; it compiles and runs programs."""

SCHEMA = 1
"""The report schema this module reads."""

_LEVELS = {"ok": 0, "external": 0, "blocked": 1, "missing": 1, "present": 1}


@dataclass(frozen=True)
class DeepRow:
    """One runtime of the health report.

    Attributes:
        title: The ecosystem and, for a component, its name.
        state: The bootstrap's state: ``ok``, ``external``, ``conflict``...
        version: The release the selection reported, or the declared one.
        detail: The reason, and the command that would rebuild it.
    """

    title: str
    state: str
    version: str
    detail: str

    @property
    def rank(self) -> int:
        """Its share of the exit status; a conflict, or anything new, is 2."""
        return _LEVELS.get(self.state, 2)


@dataclass(frozen=True)
class Deep:
    """The health check's outcome.

    Attributes:
        rows: One per runtime, in the report's order.
        error: Why there are no rows, when the check could not answer.
        level: The error's share of the exit status.
    """

    rows: tuple[DeepRow, ...] = ()
    error: str = ""
    level: int = 0

    @property
    def rank(self) -> int:
        """The worst share of the exit status."""
        return max([self.level, *(row.rank for row in self.rows)])


def deep(host: Host, timeout: float = DEEP_TIMEOUT) -> Deep:
    """Run the bootstrap's health check and read its report.

    A missing ``dev-bootstrap`` or a check that ran out of time is
    inconclusive; one that failed or printed something unreadable is
    broken, as a check that cannot run is anywhere in the report.
    """
    command = host.which("dev-bootstrap")
    if command is None:
        return Deep(error="dev-bootstrap is not on PATH", level=1)
    outcome = process.run(
        (str(command), "verify", "--health", "--json"), host.env, timeout
    )
    if outcome.timed_out:
        return Deep(error=f"Took longer than {timeout:.0f} seconds", level=1)
    if outcome.status not in (0, 1):
        return Deep(error=f"dev-bootstrap exited {outcome.status}", level=2)
    try:
        return Deep(read(outcome.output))
    except ValueError as error:
        return Deep(error=str(error), level=2)


def read(text: str) -> tuple[DeepRow, ...]:
    """The rows of a schema 1 health report.

    Raises:
        ValueError: If the text is not such a report.
    """
    try:
        report = as_object(json.loads(text))
    except ValueError:
        report = None
    if report is None or report.get("schema") != SCHEMA:
        raise ValueError(f"Not a dev-bootstrap report of schema {SCHEMA}")
    titles = _titles(as_array(report.get("catalog")) or [])
    runtimes = as_array(report.get("runtimes"))
    if runtimes is None:
        raise ValueError("The report has no runtimes")
    rows: list[DeepRow] = []
    for item in runtimes:
        row = as_object(item) or {}
        language = _text(row, "language")
        component = _text(row, "component")
        title, components, primary = titles.get(language, (language, {}, ""))
        part = components.get(component or primary, component)
        details = [_text(row, "reason")]
        if _text(row, "remediation"):
            details.append(f"Rebuild: {_text(row, 'remediation')}")
        rows.append(
            DeepRow(
                f"{title} ({part})" if part else title,
                _text(row, "state") or "unknown",
                _text(row, "actualVersion") or _text(row, "version") or "-",
                "; ".join(detail for detail in details if detail),
            )
        )
    return tuple(rows)


def _titles(
    catalog: list[object],
) -> dict[str, tuple[str, dict[str, str], str]]:
    """Each ecosystem's title, its components' titles and its primary one."""
    titles: dict[str, tuple[str, dict[str, str], str]] = {}
    for item in catalog:
        entry = as_object(item) or {}
        components = as_object(entry.get("componentTitles")) or {}
        named = {k: v for k, v in components.items() if isinstance(v, str)}
        language = _text(entry, "language")
        titles[language] = (
            _text(entry, "title") or language,
            named,
            _text(entry, "primaryComponent"),
        )
    return titles


def _text(data: dict[str, object], key: str) -> str:
    """A string field, or an empty string."""
    value = data.get(key)
    return value if isinstance(value, str) else ""
