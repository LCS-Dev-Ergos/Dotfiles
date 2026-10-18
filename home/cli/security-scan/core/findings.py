"""What a scan reports: findings, each file's result, and the errors."""

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path


class ScanError(Exception):
    """The scan cannot run at all: bad rules, a bad report path."""


class LayerError(Exception):
    """A layer could not finish on a file, or on the whole batch."""


class Severity(Enum):
    """How much a finding matters, least first."""

    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"

    @property
    def rank(self) -> int:
        """The order of severity: info 0, warning 1, critical 2."""
        return list(Severity).index(self)

    @property
    def tone(self) -> str:
        """The terminal tone a finding of this severity is drawn in."""
        return _TONES[self]


_TONES = {
    Severity.INFO: "muted",
    Severity.WARNING: "warn",
    Severity.CRITICAL: "error",
}


@dataclass(frozen=True)
class Finding:
    """One observation about a file, and the check that made it.

    ``check`` names the check (``signature``, ``embedded``, ``pdf``,
    ``archive``, ``yara`` or ``clamav``); ``detail`` holds what a script
    reading the JSON report may want, such as the matching rule.
    """

    check: str
    severity: Severity
    message: str
    detail: dict[str, object] = field(default_factory=dict)

    def to_json(self) -> dict[str, object]:
        """The finding as a JSON object."""
        payload: dict[str, object] = {
            "check": self.check,
            "severity": self.severity.value,
            "message": self.message,
        }
        if self.detail:
            payload["detail"] = self.detail
        return payload


@dataclass
class Result:
    """One file: the layers that finished on it, findings and errors.

    A layer that could not finish leaves an error instead of its name in
    ``layers``, so a file is never reported clean by a layer that did not
    look at it.
    """

    path: Path
    size: int = 0
    sha256: str | None = None
    layers: list[str] = field(default_factory=list[str])
    findings: list[Finding] = field(default_factory=list[Finding])
    errors: list[str] = field(default_factory=list[str])

    @property
    def worst(self) -> Severity | None:
        """The most severe finding's severity; None when there is none."""
        return max(
            (finding.severity for finding in self.findings),
            key=lambda severity: severity.rank,
            default=None,
        )

    @property
    def flagged(self) -> bool:
        """Whether a finding asks for a look: a warning or worse."""
        worst = self.worst
        return worst is not None and worst is not Severity.INFO

    def to_json(self) -> dict[str, object]:
        """The result as a JSON object."""
        return {
            "path": str(self.path),
            "size": self.size,
            "sha256": self.sha256,
            "layers": self.layers,
            "findings": [finding.to_json() for finding in self.findings],
            "errors": self.errors,
        }
