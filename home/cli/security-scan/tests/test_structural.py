"""The structural layer against crafted files."""

import os
import unittest

from core.findings import Severity
from core.structural import check, check_signature
from tests.support import ELF, PE, Folder


def summary(findings) -> list[tuple[str, Severity]]:
    """Each finding's check and severity."""
    return [(finding.check, finding.severity) for finding in findings]


class SignatureTests(unittest.TestCase):
    """Content against extension."""

    def setUp(self) -> None:
        """A folder for the samples."""
        self.folder = Folder(self)

    def test_matching_content_passes(self) -> None:
        """A real header, an empty file or an unknown type is no finding."""
        samples = (
            ("pdf", b"%PDF-1.7\n%%EOF"),
            ("pdf", b"\n\n  junk %PDF-1.4\n"),
            ("jpg", b"\xff\xd8\xff\xe0"),
            ("epub", b"PK\x03\x04"),
            ("pdf", b""),
            ("unknown", b"MZ anything"),
        )
        for kind, head in samples:
            with self.subTest(kind=kind, head=head):
                self.assertIsNone(check_signature(kind, head))

    def test_a_program_under_a_document_name_is_critical(self) -> None:
        """Windows, Linux and macOS programs and scripts are named."""
        samples = {
            "invoice.pdf": (PE, "Windows program"),
            "book.epub": (ELF, "Linux program"),
            "photo.png": (b"\xcf\xfa\xed\xfe" + b"\x00" * 8, "macOS"),
            "letter.docx": (b"#!/bin/sh\nrm -rf ~\n", "script"),
        }
        for name, (content, what) in samples.items():
            with self.subTest(name=name):
                findings = check(self.folder.file(name, content))
                self.assertEqual(
                    summary(findings), [("signature", Severity.CRITICAL)]
                )
                self.assertIn(what, findings[0].message)

    def test_other_mismatches_are_warnings(self) -> None:
        """A tar archive is named as such; anything else is a mismatch."""
        tar = b"x" * 257 + b"ustar" + b"\x00" * 64
        findings = check(self.folder.file("book.epub", tar))
        self.assertEqual(summary(findings), [("signature", Severity.WARNING)])
        self.assertIn("tar archive", findings[0].message)
        findings = check(self.folder.file("book.pdf", b"<html>"))
        self.assertEqual(summary(findings), [("signature", Severity.WARNING)])
        self.assertIn(
            "Is an XML or HTML file named as a .pdf", findings[0].message
        )
        findings = check(self.folder.file("book.pdf", b"plain text"))
        self.assertIn("does not match", findings[0].message)

    def test_a_misnamed_archive_is_still_checked(self) -> None:
        """A ZIP named as a PDF is held to a document's standard."""
        path = self.folder.zip("book.pdf", {"run.exe": b"x"})
        findings = check(path)
        self.assertEqual(
            summary(findings),
            [("signature", Severity.WARNING), ("archive", Severity.CRITICAL)],
        )
        self.assertIn("Is a ZIP archive named as a .pdf", findings[0].message)


class EmbeddedTests(unittest.TestCase):
    """Programs hidden inside other files."""

    def setUp(self) -> None:
        """A folder for the samples."""
        self.folder = Folder(self)

    def test_hidden_programs_are_critical(self) -> None:
        """A Windows or Linux program after the first byte is found."""
        for name, payload in (("a.bin", PE), ("b.bin", ELF)):
            with self.subTest(name=name):
                path = self.folder.file(name, b"data" * 64 + payload)
                self.assertEqual(
                    summary(check(path)), [("embedded", Severity.CRITICAL)]
                )

    def test_programs_and_chance_bytes_are_left_alone(self) -> None:
        """An installer, a package or disk image, a bare magic, a script."""
        samples = {
            "setup.exe": PE + b"\x00" * 64 + PE,
            "app.apk": b"PK\x03\x04" + b"\x00" * 64 + ELF,
            "disk.iso": b"\x00" * 64 + PE,
            "random.bin": b"MZ" + b"\x00" * 300 + b"\x7fELF\x09\x09",
            "install.run": b"#!/bin/sh\nexit 0\n" + ELF,
        }
        for name, content in samples.items():
            with self.subTest(name=name):
                self.assertEqual(check(self.folder.file(name, content)), [])


class PdfTests(unittest.TestCase):
    """What a PDF does when opened, and what it carries."""

    def setUp(self) -> None:
        """A folder for the samples."""
        self.folder = Folder(self)

    def findings(self, **features: bool) -> list[tuple[str, Severity]]:
        """The PDF findings of a sample with the features."""
        return summary(check(self.folder.pdf("sample.pdf", **features)))

    def test_a_plain_pdf_is_clean(self) -> None:
        """One blank page has nothing to report."""
        self.assertEqual(self.findings(), [])

    def test_an_inline_launch_action_is_critical(self) -> None:
        """An action written inside a link still counts, and is named."""
        findings = check(self.folder.pdf("sample.pdf", launch=True))
        self.assertEqual(summary(findings), [("pdf", Severity.CRITICAL)])
        self.assertIn("calc.exe", findings[0].message)

    def test_a_launch_action_to_a_document_is_a_warning(self) -> None:
        """Cross-references between PDFs use Launch actions too."""
        findings = check(self.folder.pdf("sample.pdf", crossref=True))
        self.assertEqual(summary(findings), [("pdf", Severity.WARNING)])
        self.assertEqual(findings[0].detail, {"launch": ["a.pdf"]})
        findings = check(
            self.folder.pdf(
                "sample.pdf", crossref=True, launch=True, attachment=True
            )
        )
        self.assertEqual(
            summary(findings),
            [("pdf", Severity.CRITICAL), ("pdf", Severity.WARNING)],
        )
        self.assertIn("calc.exe", findings[0].message)
        self.assertIn("note.txt", findings[1].message)

    def test_javascript_that_runs_by_itself_is_a_warning(self) -> None:
        """On open, on a page event or from the name tree."""
        for feature in ("opening", "event", "document"):
            with self.subTest(feature=feature):
                self.assertEqual(
                    self.findings(**{feature: True}),
                    [("pdf", Severity.WARNING)],
                )

    def test_javascript_behind_a_link_is_information(self) -> None:
        """Forms and links use JavaScript legitimately."""
        self.assertEqual(self.findings(link=True), [("pdf", Severity.INFO)])

    def test_attachments_are_named(self) -> None:
        """An attached file is a warning that names it."""
        path = self.folder.pdf("sample.pdf", attachment=True)
        findings = check(path)
        self.assertEqual(summary(findings), [("pdf", Severity.WARNING)])
        self.assertIn("note.txt", findings[0].message)
        self.assertEqual(findings[0].detail, {"attachments": ["note.txt"]})

    def test_locked_and_broken_pdfs_are_warnings(self) -> None:
        """Neither can be inspected, and the message says why."""
        self.assertEqual(
            self.findings(password=True), [("pdf", Severity.WARNING)]
        )
        path = self.folder.file("broken.pdf", b"%PDF-1.7\n" + os.urandom(64))
        findings = check(path)
        self.assertEqual(summary(findings), [("pdf", Severity.WARNING)])


class ArchiveTests(unittest.TestCase):
    """What a ZIP-based archive bundles."""

    def setUp(self) -> None:
        """A folder for the samples."""
        self.folder = Folder(self)

    def test_programs_in_a_document_are_critical(self) -> None:
        """An EPUB carrying a program or an app bundle."""
        for entry in ("OEBPS/run.exe", "Tool.app/Contents/MacOS/tool"):
            with self.subTest(entry=entry):
                path = self.folder.zip("book.epub", {entry: b"x"})
                self.assertEqual(
                    summary(check(path)), [("archive", Severity.CRITICAL)]
                )

    def test_an_app_bundle_is_named_once(self) -> None:
        """Its files are one program."""
        entries = {f"Tool.app/Contents/{n}": b"x" for n in ("a", "b", "c")}
        findings = check(self.folder.zip("tools.zip", entries))
        self.assertEqual(
            findings[0].message, "Bundles 1 program or script: Tool.app"
        )

    def test_programs_in_a_plain_zip_are_a_warning(self) -> None:
        """Software ships in ZIP files."""
        path = self.folder.zip("tools.zip", {"setup.exe": b"x"})
        self.assertEqual(summary(check(path)), [("archive", Severity.WARNING)])

    def test_escaping_paths_and_macros_are_warnings(self) -> None:
        """Entries that land outside the target; VBA in an Office file."""
        for entry in ("../evil.txt", "/etc/passwd", "C:\\boot.ini"):
            with self.subTest(entry=entry):
                path = self.folder.zip("files.zip", {entry: b"x"})
                self.assertEqual(
                    summary(check(path)), [("archive", Severity.WARNING)]
                )
        path = self.folder.zip("sheet.xlsm", {"xl/vbaProject.bin": b"x"})
        self.assertEqual(summary(check(path)), [("archive", Severity.WARNING)])
        path = self.folder.zip("files.zip", {"xl/vbaProject.bin": b"x"})
        self.assertEqual(check(path), [])

    def test_a_broken_archive_is_a_warning(self) -> None:
        """The header matches, the directory does not exist."""
        path = self.folder.file("book.epub", b"PK\x03\x04" + b"\x00" * 64)
        self.assertEqual(summary(check(path)), [("archive", Severity.WARNING)])


if __name__ == "__main__":
    unittest.main()
