from __future__ import annotations

import tempfile
import unittest
import zipfile
from pathlib import Path

from _support import MODULE_ROOT  # noqa: F401
from report import Severity
from structural_checks import (
    _pdf_findings_pikepdf,
    archive_findings,
    check_embedded_executable,
    check_signature,
)


class SignatureTests(unittest.TestCase):
    def test_accepts_real_pdf_header(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "book.pdf"
            path.write_bytes(b"%PDF-1.7\n%%EOF")
            self.assertIsNone(check_signature(path))

    def test_flags_executable_disguised_as_pdf(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "invoice.pdf"
            path.write_bytes(b"MZ" + b"\0" * 64 + b"This program cannot be run in DOS mode")
            finding = check_signature(path)
            self.assertIsNotNone(finding)
            self.assertEqual(finding.severity, Severity.WARNING)


class ContainerTests(unittest.TestCase):
    def test_finds_embedded_pe_signature(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "notes.bin.pdf"
            path.write_bytes(b"%PDF\nMZ...This program cannot be run in DOS mode")
            finding = check_embedded_executable(path)
            self.assertIsNotNone(finding)
            self.assertEqual(finding.severity, Severity.CRITICAL)

    def test_flags_executable_in_epub(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "book.epub"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("mimetype", "application/epub+zip")
                archive.writestr("payload/run.exe", b"MZ")
            findings = archive_findings(path)
            self.assertEqual(len(findings), 1)
            self.assertEqual(findings[0].severity, Severity.CRITICAL)


class _FakeObject(dict):
    pass


class _FakeRoot(dict):
    @property
    def Names(self):
        return self["/Names"]


class _FakePdf:
    Root = _FakeRoot({"/Names": {"/JavaScript": {}}})
    objects = [
        _FakeObject({"/S": "/Launch"}),
        _FakeObject({"/Type": "/EmbeddedFile"}),
    ]

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


class _FakePikePdf:
    @staticmethod
    def open(_path: Path) -> _FakePdf:
        return _FakePdf()


class PdfStructureTests(unittest.TestCase):
    def test_detects_launch_javascript_and_attachment(self) -> None:
        findings = _pdf_findings_pikepdf(Path("fixture.pdf"), _FakePikePdf)
        messages = " ".join(finding.message for finding in findings)
        self.assertIn("/Launch", messages)
        self.assertIn("embedded file", messages)
        self.assertIn("JavaScript", messages)


if __name__ == "__main__":
    unittest.main()
