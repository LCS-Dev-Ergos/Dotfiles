"""The YARA and ClamAV layers."""

import os
import time
import unittest
from datetime import datetime, timedelta

from core import antivirus
from core.findings import LayerError, ScanError, Severity
from core.patterns import DEFAULT_RULES, Patterns
from tests.support import EICAR, ELF, PE, Folder


class PatternTests(unittest.TestCase):
    """The bundled rules and custom ones."""

    def setUp(self) -> None:
        """A folder and the bundled rules."""
        self.folder = Folder(self)
        self.patterns = Patterns(DEFAULT_RULES)

    def rules(self, path) -> list[str]:
        """The rules that match a file."""
        return [
            str(found.detail["rule"]) for found in self.patterns.match(path)
        ]

    def test_the_bundled_rules_compile(self) -> None:
        """Every rule is there."""
        self.assertEqual(self.patterns.count, 6)

    def test_threats_match_with_the_rules_severity(self) -> None:
        """Hidden programs are critical, the test string a warning."""
        cases = {
            "a.bin": (b"data" * 8 + PE, "Embedded_PE_Executable"),
            "b.bin": (b"data" * 8 + ELF, "Embedded_ELF_Executable"),
            "c.pdf": (b"%PDF-1.7\nutil.printf(", "PDF_Exploit_JavaScript"),
            "d.pdf": (b"%PDF-1.7\napp.launchURL(", "PDF_Risky_JavaScript"),
            "e.doc": (
                b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1 AutoOpen Shell(",
                "Office_AutoExec_Macro",
            ),
        }
        for name, (content, rule) in cases.items():
            with self.subTest(name=name):
                path = self.folder.file(name, content)
                self.assertEqual(self.rules(path), [rule])
        found = self.patterns.match(self.folder.file("e.txt", EICAR))
        self.assertEqual(found[0].severity, Severity.WARNING)
        self.assertTrue(found[0].message.startswith("Holds the EICAR"))

    def test_programs_and_plain_text_do_not_match(self) -> None:
        """An installer, a self-extracting script, JavaScript outside PDF."""
        samples = {
            "setup.exe": PE + b"\x00" * 64 + PE,
            "install.run": b"#!/bin/sh\n" + ELF,
            "app.apk": b"PK\x03\x04" + b"\x00" * 64 + ELF,
            "disk.iso": b"\x00" * 64 + PE,
            "page.html": b"<script>eval(unescape('%u4141'))</script>",
            "plugin.js": b"function AutoOpen() { CreateObject(x) }",
        }
        for name, content in samples.items():
            with self.subTest(name=name):
                self.assertEqual(
                    self.rules(self.folder.file(name, content)), []
                )

    def test_custom_rules_and_their_meta(self) -> None:
        """Severity and description come from the meta, or defaults."""
        rules = self.folder.file(
            "custom.yar",
            b'rule loud { meta: severity = "critical" description = "bad"'
            b' strings: $a = "needle" condition: $a }\n'
            b'rule quiet { strings: $a = "needle" condition: $a }\n',
        )
        found = Patterns(rules).match(self.folder.file("x", b"a needle"))
        self.assertEqual(
            [(item.severity, item.message) for item in found],
            [
                (Severity.CRITICAL, "Bad"),
                (Severity.WARNING, "Matches the rule quiet"),
            ],
        )

    def test_bad_rules_stop_the_scan(self) -> None:
        """A missing file or a syntax error is a ScanError."""
        with self.assertRaisesRegex(ScanError, "No YARA rules file"):
            Patterns(self.folder.root / "missing.yar")
        broken = self.folder.file("broken.yar", b"rule { condition: }")
        with self.assertRaisesRegex(ScanError, "broken.yar"):
            Patterns(broken)

    def test_an_unreadable_file_is_a_layer_error(self) -> None:
        """The file's error, not the scan's."""
        with self.assertRaises(LayerError):
            self.patterns.match(self.folder.root / "missing")


class FindTests(unittest.TestCase):
    """Whether ClamAV can scan."""

    def setUp(self) -> None:
        """A folder for the fake clamscan."""
        self.folder = Folder(self)

    def test_the_database_is_read_from_the_version(self) -> None:
        """Engine, database version and date."""
        clamav, reason = antivirus.find(self.folder.clamscan())
        assert clamav is not None
        self.assertEqual(
            (clamav.version, clamav.database, reason), ("1.5.4", "27412", "")
        )
        assert clamav.updated is not None
        self.assertEqual(clamav.updated.isoformat(), "2026-10-18T08:12:00")

    def test_missing_clamscan_or_database(self) -> None:
        """Each says why ClamAV cannot scan."""
        self.assertEqual(antivirus.find({"PATH": ""}), (None, "Not installed"))
        env = self.folder.clamscan("ClamAV 1.5.4")
        self.assertEqual(antivirus.find(env), (None, "No signature database"))
        env = self.folder.clamscan("") | {"CLAM_STATUS": "2"}
        clamav, reason = antivirus.find(env)
        self.assertIsNone(clamav)
        self.assertTrue(reason.startswith("Cannot run clamscan"))


class ScanTests(unittest.TestCase):
    """ClamAV over a batch."""

    def setUp(self) -> None:
        """The fake clamscan and its database."""
        self.folder = Folder(self)
        self.env = self.folder.clamscan()
        clamav, _ = antivirus.find(self.env)
        assert clamav is not None
        self.clamav = clamav

    def test_each_verdict_is_read(self) -> None:
        """Clean, found, limits, heuristics and errors, by exact path."""
        names = [
            "clean.pdf",
            "empty.txt",
            "infected.exe",
            "huge.iso",
            "heuristic.bin",
            "denied.txt",
            "ignored.txt",
            "odd: OK",
        ]
        paths = [self.folder.file(name, b"x") for name in names]
        done: list[int] = []
        outcome = antivirus.scan(self.clamav, paths, self.env, done.append)
        clean = {path.name for path in outcome.clean}
        self.assertEqual(clean, {"clean.pdf", "empty.txt", "odd: OK"})
        severities = {
            path.name: [finding.severity for finding in findings]
            for path, findings in outcome.findings.items()
        }
        self.assertEqual(
            severities,
            {
                "infected.exe": [Severity.CRITICAL],
                "huge.iso": [Severity.INFO],
                "heuristic.bin": [Severity.WARNING],
            },
        )
        errors = {path.name: text for path, text in outcome.errors.items()}
        self.assertEqual(
            errors,
            {
                "denied.txt": "ClamAV: Access denied",
                "ignored.txt": "ClamAV did not report on this file",
            },
        )
        self.assertEqual(done, list(range(1, 8)))

    def test_a_name_with_a_line_break_is_not_sent(self) -> None:
        """It could not be told apart from two names in the list."""
        path = self.folder.file("two\nlines", b"x")
        outcome = antivirus.scan(self.clamav, [path], self.env)
        self.assertIn("line break", outcome.errors[path])

    def test_a_failed_run_is_a_layer_error(self) -> None:
        """ClamAV's own message explains it."""
        path = self.folder.file("a.txt", b"x")
        env = self.env | {"CLAM_MODE": "fail"}
        with self.assertRaisesRegex(LayerError, "No supported database"):
            antivirus.scan(self.clamav, [path], env)

    def test_a_timeout_stops_everything_clamscan_started(self) -> None:
        """No child outlives the run."""
        path = self.folder.file("a.txt", b"x")
        mark = self.folder.root / "mark"
        env = self.env | {"CLAM_MODE": "hang", "CLAM_MARK": str(mark)}
        with self.assertRaisesRegex(LayerError, "longer than"):
            antivirus.scan(self.clamav, [path], env, timeout=0.3)
        time.sleep(1.5)
        self.assertFalse(mark.exists())

    def test_the_file_list_stays_private(self) -> None:
        """The temporary list is gone after the run."""
        path = self.folder.file("a.txt", b"x")
        before = set(os.listdir(self.folder.root))
        antivirus.scan(self.clamav, [path], self.env)
        self.assertEqual(set(os.listdir(self.folder.root)), before)


class StaleTests(unittest.TestCase):
    """The database's age."""

    def test_a_week_old_database_is_stale(self) -> None:
        """Seven days are fine, eight are not."""
        updated = datetime(2026, 10, 1)
        clamav = antivirus.ClamAV(Folder(self).root, "1", "2", updated)
        self.assertFalse(clamav.stale(updated + timedelta(days=7)))
        self.assertTrue(clamav.stale(updated + timedelta(days=8)))


if __name__ == "__main__":
    unittest.main()
