"""The command line from end to end."""

import contextlib
import io
import json
import os
import stat
import unittest
from pathlib import Path
from unittest.mock import patch

import terminal_style as ui

from core import __version__, cli
from tests.support import EICAR, PE, Folder


class CommandTests(unittest.TestCase):
    """Exit statuses, output and the JSON report."""

    def setUp(self) -> None:
        """A folder with a clean file and a fake ClamAV with a database."""
        self.folder = Folder(self)
        self.clean = self.folder.file("docs/notes.txt", b"hello")
        self.env = self.folder.clamscan()

    def run_cli(
        self, *argv: str, env: dict[str, str] | None = None
    ) -> tuple[int, str, str]:
        """Run the command: its status, standard output and error."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                status = cli.main(
                    list(argv),
                    self.env if env is None else env,
                    ui.Style(False),
                )
            except SystemExit as error:
                status = int(error.code or 0)
        return status, out.getvalue(), err.getvalue()

    def test_a_clean_folder_exits_zero(self) -> None:
        """Every layer ran on every file, and the summary says clean."""
        status, out, _ = self.run_cli(str(self.folder.root / "docs"))
        self.assertEqual(status, 0)
        self.assertIn("1.5.4 · database 27412 · 2026-10-18", out)
        self.assertTrue(out.splitlines()[-1].startswith("[OK]"))
        self.assertIn("1 clean.", out)

    def test_a_flagged_file_exits_one(self) -> None:
        """Even with a missing path beside it, a finding wins."""
        self.folder.file("docs/invoice.pdf", PE)
        status, out, _ = self.run_cli(
            str(self.folder.root / "docs"), str(self.folder.root / "nope")
        )
        self.assertEqual(status, 1)
        self.assertIn("Is a Windows program named as a .pdf file", out)
        self.assertIn("Not found", out)
        self.assertIn("1 critical, 1 clean, 1 not fully scanned.", out)

    def test_an_incomplete_scan_exits_two(self) -> None:
        """A file ClamAV could not read leaves the scan incomplete."""
        self.folder.file("docs/denied.txt", b"x")
        status, out, _ = self.run_cli(str(self.folder.root / "docs"))
        self.assertEqual(status, 2)
        self.assertIn("ClamAV: Access denied", out)
        self.assertTrue(out.splitlines()[-1].startswith("[ERROR]"))

    def test_a_failed_layer_exits_two(self) -> None:
        """ClamAV failing as a whole is named in its layer."""
        env = self.env | {"CLAM_MODE": "fail"}
        status, out, _ = self.run_cli(str(self.clean), env=env)
        self.assertEqual(status, 2)
        self.assertIn("ClamAV failed: LibClamAV Error", out)
        self.assertIn("The scan is incomplete.", out)

    def test_a_missing_clamav_only_says_so(self) -> None:
        """An absent layer is reported, and the scan still completes."""
        status, out, _ = self.run_cli(str(self.clean), env={"PATH": ""})
        self.assertEqual(status, 0)
        self.assertIn("Not installed", out)
        self.assertIn("fix: Install ClamAV, then run freshclam", out)

    def test_the_json_report(self) -> None:
        """Written whole, private, with hashes and findings."""
        self.folder.file("docs/eicar.txt", EICAR)
        report = self.folder.root / "out" / "report.json"
        report.parent.mkdir()
        status, out, _ = self.run_cli(
            str(self.folder.root / "docs"), "--report", str(report), "--hash"
        )
        self.assertEqual(status, 1)
        self.assertIn(f"Report saved in {report}", out)
        self.assertEqual(stat.S_IMODE(report.stat().st_mode), 0o600)
        self.assertEqual(os.listdir(report.parent), ["report.json"])
        payload = json.loads(report.read_text())
        self.assertEqual(payload["version"], __version__)
        self.assertEqual(payload["status"], 1)
        self.assertTrue(payload["complete"])
        files = {Path(item["path"]).name: item for item in payload["files"]}
        self.assertEqual(len(files["notes.txt"]["sha256"]), 64)
        self.assertEqual(
            files["eicar.txt"]["layers"], ["structural", "yara", "clamav"]
        )
        self.assertEqual(
            files["eicar.txt"]["findings"][0]["detail"],
            {"rule": "EICAR_Test_String"},
        )

    def test_a_bad_report_path_stops_before_scanning(self) -> None:
        """A missing folder, or a folder as the file."""
        for target in (self.folder.root / "no" / "r.json", self.folder.root):
            with self.subTest(target=target):
                status, out, err = self.run_cli(
                    str(self.clean), "--report", str(target)
                )
                self.assertEqual((status, out), (2, ""))
                self.assertIn("--report", err)

    def test_a_failed_write_is_reported(self) -> None:
        """The report is printed; the status says the run failed."""
        report = self.folder.root / "report.json"
        with patch(
            "core.cli.os.replace", side_effect=PermissionError(13, "Denied")
        ):
            status, out, err = self.run_cli(
                str(self.clean), "--report", str(report)
            )
        self.assertEqual(status, 2)
        self.assertIn("1 clean", out)
        self.assertIn("Cannot write", err)
        self.assertEqual(os.listdir(self.folder.root), ["bin", "docs"])

    def test_quiet_and_verbose(self) -> None:
        """Quiet prints the summary alone; verbose lists clean files."""
        status, out, _ = self.run_cli("-q", str(self.clean))
        self.assertEqual((status, len(out.splitlines())), (0, 1))
        _, out, _ = self.run_cli("-v", str(self.clean))
        self.assertIn("Clean · 1", out)
        self.assertIn("structural, yara, clamav", out)

    def test_layers_can_be_turned_off(self) -> None:
        """A turned-off layer says so and does not run."""
        self.folder.file("docs/eicar.txt", EICAR)
        status, out, _ = self.run_cli(
            "--no-yara", "--no-clamav", str(self.folder.root / "docs")
        )
        self.assertEqual(status, 0)
        self.assertEqual(out.count("Turned off"), 2)

    def test_untrusted_names_cannot_drive_the_terminal(self) -> None:
        """Control characters in a file name are escaped."""
        self.folder.file("docs/\x1b[2Jevil.pdf", PE)
        _, out, _ = self.run_cli(str(self.folder.root / "docs"))
        self.assertNotIn("\x1b", out)
        self.assertIn("\\x1b[2Jevil.pdf", out)

    def test_usage_errors(self) -> None:
        """Capitalized, with status 2."""
        cases = (
            (["--hash", "x"], "--hash needs --report"),
            (
                ["--no-structural", "--no-yara", "--no-clamav", "x"],
                "Every layer is turned off",
            ),
            ([], "The following arguments are required: PATH"),
        )
        for argv, message in cases:
            with self.subTest(argv=argv):
                status, _, err = self.run_cli(*argv)
                self.assertEqual(status, 2)
                self.assertIn(f"security-scan: {message}", err)
        status, _, err = self.run_cli(
            "--yara-rules", str(self.folder.root / "none.yar"), "x"
        )
        self.assertEqual(status, 2)
        self.assertIn("No YARA rules file", err)

    def test_help_and_version(self) -> None:
        """Help in capitalized sentences, with examples and statuses."""
        status, out, _ = self.run_cli("--help")
        self.assertEqual(status, 0)
        for text in ("Usage: security-scan", "Layers:", "Exit status:"):
            self.assertIn(text, out)
        status, out, _ = self.run_cli("--version")
        self.assertEqual(out.strip(), f"security-scan {__version__}")


if __name__ == "__main__":
    unittest.main()
