"""The YARA layer: known threat patterns, matched in-process.

The rules are compiled once per scan, then matched against each file with a
time limit, so a pathological file cannot stall the scan. A rule's
``severity`` meta (``info``, ``warning`` or ``critical``) sets its
findings' severity, and its ``description`` their message; a rule without
them reports a warning in its own name.

Rules can read one external variable: ``software`` is true for a software
package or a disk image (by extension), which carries programs by design.
"""

from pathlib import Path

import yara

from . import RULES
from .findings import Finding, LayerError, ScanError, Severity
from .structural import SOFTWARE

DEFAULT_RULES = RULES / "document-threats.yar"
"""The bundled rules."""

TIMEOUT = 60
"""Seconds YARA may spend on one file."""


class Patterns:
    """Compiled rules, ready to match files."""

    def __init__(self, path: Path) -> None:
        """Compile the rules in a file.

        Raises:
            ScanError: If the file is missing or the rules do not compile.
        """
        if not path.is_file():
            raise ScanError(f"No YARA rules file at {path}")
        try:
            self._rules = yara.compile(
                filepath=str(path), externals={"software": False}
            )
        except yara.Error as error:
            raise ScanError(f"The YARA rules in {path}: {error}") from error
        self.path = path
        self.count = sum(1 for _ in self._rules)

    def match(self, path: Path) -> list[Finding]:
        """The findings of every rule that matches a file.

        Raises:
            LayerError: If YARA cannot read the file or runs out of time.
        """
        software = path.suffix.lower().removeprefix(".") in SOFTWARE
        try:
            matches = self._rules.match(
                filepath=str(path),
                externals={"software": software},
                timeout=TIMEOUT,
            )
        except yara.TimeoutError as error:
            raise LayerError(
                f"YARA took longer than {TIMEOUT} s on this file"
            ) from error
        except yara.Error as error:
            raise LayerError(f"YARA could not read this file: {error}") from (
                error
            )
        return [_finding(match.rule, match.meta) for match in matches]


def _finding(rule: str, meta: dict[str, object]) -> Finding:
    """A match as a finding, worded and ranked by the rule's meta."""
    try:
        severity = Severity(str(meta.get("severity", "")).lower())
    except ValueError:
        severity = Severity.WARNING
    description = str(meta.get("description") or f"Matches the rule {rule}")
    return Finding(
        "yara",
        severity,
        description[:1].upper() + description[1:],
        {"rule": rule},
    )
