from __future__ import annotations

import unittest
from pathlib import Path

from _support import MODULE_ROOT  # noqa: F401
from report import FileReport, Finding, ScanSummary, Severity, build_json_report


class ReportTests(unittest.TestCase):
    def test_summary_tracks_worst_severity(self) -> None:
        report = FileReport(Path("sample.pdf"), 10, None)
        report.findings.extend(
            [Finding("metadata", Severity.INFO, "info"), Finding("signature", Severity.CRITICAL, "bad")]
        )
        summary = ScanSummary()
        summary.register(report)
        self.assertEqual(summary.files_with_critical, 1)
        self.assertEqual(summary.files_clean, 0)

    def test_json_payload_is_serializable_shape(self) -> None:
        report = FileReport(Path("sample.pdf"), 10, "abc")
        summary = ScanSummary(files_scanned=1, files_clean=1)
        payload = build_json_report([report], summary)
        self.assertEqual(payload["files"][0]["path"], "sample.pdf")
        self.assertEqual(payload["summary"]["files_clean"], 1)


if __name__ == "__main__":
    unittest.main()
