"""The command line, run in-process against a throwaway machine."""

import contextlib
import io
import unittest
from pathlib import Path
from unittest import mock

from core import cli
from core.cli import ExitCode, main
from core.host import Host
from core.manifest import LEAVES
from core.plan import Plan
from core.storage import WriteResult
from tests.support import CRLF_SETTINGS, Machine


class CommandLineTests(unittest.TestCase):
    """The commands, their output streams and their exit status."""

    def setUp(self) -> None:
        """Give the machine a clangd, so every plan has something to write."""
        self.m = Machine(self)
        self.m.tool("clangd")

    def run_cli(self, *argv: str) -> tuple[int, str, str]:
        """Run the command line; the exit status, stdout and stderr."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = main(list(argv), self.m.host)
            except SystemExit as exit_:
                code = exit_.code if isinstance(exit_.code, int) else -1
        return code, out.getvalue(), err.getvalue()

    def backups(self) -> list[Path]:
        """The backups left in the machine's state directory."""
        directory = self.m.state / "vscode-host-settings" / "backups"
        return sorted(directory.glob("settings-*.json"))

    def test_dry_run_reports_drift_without_writing(self) -> None:
        """A dry run exits with 1, writes nothing and makes no backup."""
        path = self.m.settings(CRLF_SETTINGS)
        before = path.read_bytes()
        code, out, _ = self.run_cli(
            "apply", "--dry-run", "--settings", str(path)
        )
        self.assertEqual(code, ExitCode.DRIFT)
        self.assertIn("clangd.path", out)
        self.assertIn("would change this file", out)
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse((self.m.state / "vscode-host-settings").exists())

    def test_apply_then_dry_run_is_clean(self) -> None:
        """After an apply, no backup remains and nothing is left to do."""
        path = self.m.settings(CRLF_SETTINGS)
        code, out, _ = self.run_cli("apply", "--settings", str(path))
        self.assertEqual(code, ExitCode.OK)
        self.assertIn("the backup taken for the run is removed", out)
        self.assertEqual(self.backups(), [])
        code, out, _ = self.run_cli(
            "apply", "--dry-run", "--settings", str(path)
        )
        self.assertEqual(code, ExitCode.OK)
        self.assertIn("already correct", out)

    def test_diff_shows_the_text_change(self) -> None:
        """--diff prints a unified diff of the planned text."""
        path = self.m.settings(CRLF_SETTINGS)
        argv = ("apply", "--dry-run", "--diff", "--settings", str(path))
        _, out, _ = self.run_cli(*argv)
        self.assertIn("--- before", out)
        self.assertIn(f'+  "clangd.path": "{self.m.profile}/bin/clangd"', out)

    def test_errors_exit_with_the_error_code_and_stay_on_stderr(self) -> None:
        """An error goes to stderr, and later files are still processed."""
        broken = self.m.settings("not json")
        fine = self.m.settings(CRLF_SETTINGS, "other.json")
        argv = ("apply", "--settings", str(broken), "--settings", str(fine))
        code, out, err = self.run_cli(*argv)
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("not valid JSONC", err)
        self.assertNotIn("not valid JSONC", out)
        self.assertIn(str(fine), out)

    def test_a_failed_write_reports_the_kept_backup(self) -> None:
        """A write that fails names the backup it leaves behind."""
        path = self.m.settings(CRLF_SETTINGS)
        real_plan = cli.build_plan

        def edit_meanwhile(source: Path, text: str, host: Host) -> Plan:
            """Plan as usual, then change the file under the run."""
            plan = real_plan(source, text, host)
            path.write_text(CRLF_SETTINGS + "// edited meanwhile\n")
            return plan

        with mock.patch.object(cli, "build_plan", edit_meanwhile):
            code, _, err = self.run_cli("apply", "--settings", str(path))
        self.assertEqual(code, ExitCode.ERROR)
        (backup,) = self.backups()
        self.assertIn(f"the previous file is kept at {backup}", err)

    def test_same_file_through_two_names_is_processed_once(self) -> None:
        """A file named twice, directly and through a link, runs once."""
        real = self.m.settings(CRLF_SETTINGS)
        link = self.m.root / "link.json"
        link.symlink_to(real)
        argv = ("apply", "--dry-run", "--settings", str(real))
        _, out, _ = self.run_cli(*argv, "--settings", str(link))
        self.assertEqual(out.count("would change this file"), 1)

    def test_default_file_is_the_users_settings(self) -> None:
        """Without --settings, the edition's user settings file is used."""
        config = self.m.root / "config"
        self.m.set_env(XDG_CONFIG_HOME=str(config))
        path = config / "Code - Insiders" / "User" / "settings.json"
        path.parent.mkdir(parents=True)
        path.write_text(CRLF_SETTINGS)
        code, out, _ = self.run_cli(
            "apply", "--dry-run", "--edition", "insiders"
        )
        self.assertEqual(code, ExitCode.DRIFT)
        self.assertTrue(out.startswith(f"{path}\n"))

    def test_write_warnings_go_to_stderr(self) -> None:
        """Warnings of a successful write go to stderr; the exit is 0."""
        path = self.m.settings(CRLF_SETTINGS)
        result = WriteResult(True, Path("/backup"), ("could not flush",))
        with mock.patch.object(cli, "commit", return_value=result):
            code, out, err = self.run_cli("apply", "--settings", str(path))
        self.assertEqual(code, ExitCode.OK)
        self.assertIn("the previous file is still at /backup", out)
        self.assertIn("warning: could not flush", err)

    def test_resolve_prints_every_key(self) -> None:
        """resolve lists every managed key with what it resolves to."""
        code, out, _ = self.run_cli("resolve")
        self.assertEqual(code, ExitCode.OK)
        for leaf in LEAVES:
            self.assertIn(leaf.key, out)
        self.assertIn(str(self.m.profile / "bin" / "clangd"), out)

    def test_check_is_gone_and_usage_errors_exit_with_two(self) -> None:
        """The retired check command is a usage error."""
        code, _, err = self.run_cli("check")
        self.assertEqual(code, ExitCode.USAGE)
        self.assertIn("invalid choice", err)


if __name__ == "__main__":
    unittest.main()
