#!/usr/bin/env python3

# ============================================================================ #
"""
Security Scan - Shared Reporting Utilities:
Data model, terminal rendering, and JSON report building shared by every
check module (structural, ClamAV, YARA). Kept dependency-free (stdlib only)
so it always loads, even when optional scanners are unavailable.

Author: Claude (Anthropic)
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import hashlib
import json
import sys
import textwrap
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any


# ++++++++++++++++++++++++++++++++ Constants +++++++++++++++++++++++++++++++++ #

BOX_WIDTH = 78
CHUNK_SIZE = 1024 * 1024


# +++++++++++++++++++++++++++++++++ Severity +++++++++++++++++++++++++++++++++ #

class Severity(str, Enum):
    """Ordered severity levels for a single finding."""

    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"

    @property
    def rank(self) -> int:
        return {"info": 0, "warning": 1, "critical": 2}[self.value]


# ++++++++++++++++++++++++++++++++ Data Model ++++++++++++++++++++++++++++++++ #

@dataclass(slots=True)
class Finding:
    """One concrete observation about a scanned file."""

    check: str
    severity: Severity
    message: str
    detail: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "check": self.check,
            "severity": self.severity.value,
            "message": self.message,
        }
        if self.detail:
            payload["detail"] = self.detail
        return payload


@dataclass(slots=True)
class FileReport:
    """Aggregated findings for a single scanned file."""

    path: Path
    size_bytes: int
    sha256: str | None
    checks_run: list[str] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def worst_severity(self) -> Severity | None:
        if not self.findings:
            return None
        return max((f.severity for f in self.findings), key=lambda s: s.rank)

    @property
    def is_clean(self) -> bool:
        return self.worst_severity is None

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": str(self.path),
            "size_bytes": self.size_bytes,
            "sha256": self.sha256,
            "checks_run": self.checks_run,
            "findings": [f.to_dict() for f in self.findings],
            "errors": self.errors,
        }


@dataclass(slots=True)
class ScanSummary:
    """Totals across an entire scan run."""

    files_scanned: int = 0
    files_clean: int = 0
    files_info_only: int = 0
    files_with_warnings: int = 0
    files_with_critical: int = 0
    files_errored: int = 0
    checks_enabled: list[str] = field(default_factory=list)
    checks_skipped: list[str] = field(default_factory=list)

    def register(self, report: FileReport) -> None:
        self.files_scanned += 1
        if report.errors:
            self.files_errored += 1
        worst = report.worst_severity
        if worst is None:
            self.files_clean += 1
        elif worst is Severity.CRITICAL:
            self.files_with_critical += 1
        elif worst is Severity.WARNING:
            self.files_with_warnings += 1
        elif worst is Severity.INFO:
            self.files_info_only += 1

    def to_dict(self) -> dict[str, Any]:
        return {
            "files_scanned": self.files_scanned,
            "files_clean": self.files_clean,
            "files_info_only": self.files_info_only,
            "files_with_warnings": self.files_with_warnings,
            "files_with_critical": self.files_with_critical,
            "files_errored": self.files_errored,
            "checks_enabled": self.checks_enabled,
            "checks_skipped": self.checks_skipped,
        }


# +++++++++++++++++++++++++++++++++ Hashing ++++++++++++++++++++++++++++++++++ #

def sha256_file(path: Path) -> str | None:
    """Return the SHA-256 hex digest of a file, or None if it cannot be read."""
    try:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(CHUNK_SIZE), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


# +++++++++++++++++++++++++++++ Terminal Output ++++++++++++++++++++++++++++++ #

_ANSI_RESET = "\033[0m"
_ANSI_BOLD = "\033[1m"
_ANSI_RED = "\033[31m"
_ANSI_GREEN = "\033[32m"
_ANSI_YELLOW = "\033[33m"
_ANSI_CYAN = "\033[36m"

_SEVERITY_COLOR = {
    Severity.INFO: _ANSI_CYAN,
    Severity.WARNING: _ANSI_YELLOW,
    Severity.CRITICAL: _ANSI_RED,
}


def _supports_color(stream: Any) -> bool:
    return bool(getattr(stream, "isatty", lambda: False)())


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
    print(f"{status_prefix(level)} {message}", file=output, flush=True)


def _wrap_box_lines(text: str, width: int) -> list[str]:
    return textwrap.wrap(
        str(text), width=max(1, width), break_long_words=False, break_on_hyphens=False
    ) or [""]


def render_box(title: str, rows: list[tuple[str, str]], *, width: int = BOX_WIDTH) -> str:
    """Render a simple ASCII box for terminal-friendly summaries."""
    inner_width = max(20, width - 4)
    border = "+" + "-" * (width - 2) + "+"
    label_width = min(24, max((len(label) for label, _ in rows), default=12))
    lines = [border]
    for line in _wrap_box_lines(title, inner_width):
        lines.append(f"| {line:<{inner_width}} |")
    lines.append(border)

    value_width = max(18, inner_width - label_width - 1)
    for label, value in rows:
        wrapped = _wrap_box_lines(str(value), value_width) or [""]
        for index, chunk in enumerate(wrapped):
            prefix = f"{label:<{label_width}} " if index == 0 else f"{'':<{label_width}} "
            lines.append(f"| {(prefix + chunk)[:inner_width]:<{inner_width}} |")
    lines.append(border)
    return "\n".join(lines)


def render_finding_line(finding: Finding, *, color: bool) -> str:
    """Render one finding as a single readable terminal line."""
    tag = f"[{finding.severity.value.upper()}]"
    if color:
        c = _SEVERITY_COLOR[finding.severity]
        tag = f"{c}{tag}{_ANSI_RESET}"
    return f"  {tag} {finding.check}: {finding.message}"


def print_file_report(report: FileReport, *, verbose: bool, stream: Any | None = None) -> None:
    """Print a per-file block, skipping clean files unless verbose is set."""
    output = sys.stdout if stream is None else stream
    if report.is_clean and not report.errors and not verbose:
        return

    color = _supports_color(output)
    header = str(report.path)
    if report.is_clean and not report.errors:
        status = f"{_ANSI_GREEN}CLEAN{_ANSI_RESET}" if color else "CLEAN"
    else:
        worst = report.worst_severity
        label = worst.value.upper() if worst else "ERROR"
        c = _SEVERITY_COLOR.get(worst, _ANSI_RED) if worst else _ANSI_RED
        status = f"{c}{label}{_ANSI_RESET}" if color else label

    print(f"\n{header}", file=output, flush=True)
    print(f"  status: {status}  (checks: {', '.join(report.checks_run) or 'none'})", file=output, flush=True)
    for finding in report.findings:
        print(render_finding_line(finding, color=color), file=output, flush=True)
    for err in report.errors:
        prefix = f"{_ANSI_RED}[ERROR]{_ANSI_RESET}" if color else "[ERROR]"
        print(f"  {prefix} {err}", file=output, flush=True)


def print_progress(done: int, total: int, label: str, *, stream: Any | None = None) -> None:
    """Print an in-place, carriage-return-updated progress counter.

    Falls back to plain (non-overwriting) lines when stdout is not a tty
    (e.g. redirected to a file), since '\\r' only makes sense on a live
    terminal — otherwise every update would just accumulate as separate
    lines, which is still useful evidence that the scan is progressing.
    """
    output = sys.stdout if stream is None else stream
    message = f"{label}: {done}/{total} files"
    if _supports_color(output):
        print(f"\r{message}", end="", file=output, flush=True)
        if done >= total:
            print(file=output, flush=True)
    else:
        # Non-tty: only emit periodically to avoid flooding a log file.
        if done >= total or done % max(1, total // 20) == 0:
            print(message, file=output, flush=True)


def print_summary(summary: ScanSummary, *, stream: Any | None = None) -> None:
    """Print the aggregate summary box for the whole run."""
    output = sys.stdout if stream is None else stream
    rows = [
        ("Files scanned", str(summary.files_scanned)),
        ("Clean", str(summary.files_clean)),
        ("Info-only", str(summary.files_info_only)),
        ("Warnings", str(summary.files_with_warnings)),
        ("Critical", str(summary.files_with_critical)),
        ("Errors", str(summary.files_errored)),
        ("Checks run", ", ".join(summary.checks_enabled) or "none"),
    ]
    if summary.checks_skipped:
        rows.append(("Checks skipped", ", ".join(summary.checks_skipped)))
    print(render_box("Security Scan Summary", rows), file=output, flush=True)


# +++++++++++++++++++++++++++++++ JSON Report ++++++++++++++++++++++++++++++++ #

def build_json_report(
    reports: list[FileReport],
    summary: ScanSummary,
    *,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build the full JSON-serializable report payload."""
    payload: dict[str, Any] = {
        "summary": summary.to_dict(),
        "files": [r.to_dict() for r in reports],
    }
    if extra:
        payload.update(extra)
    return payload


def write_json_report(path: Path, payload: dict[str, Any]) -> None:
    """Write the JSON report to disk with stable, readable formatting."""
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

# ============================================================================ #
# End of script.
