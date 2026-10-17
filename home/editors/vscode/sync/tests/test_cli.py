"""The command line, end to end in a throwaway home."""

import json
import unittest
from unittest.mock import patch

from core.cli import ExitCode
from tests.support import INSIDERS, STABLE, Machine
from tests.test_guards import script

RUNNING = ["/usr/share/code/code --type=renderer"]


class CommandTests(unittest.TestCase):
    """Each command's report, refusals and changes."""

    def setUp(self) -> None:
        """Insiders with its own copy of Stable's build and own settings."""
        self.machine = Machine(self)
        self.folder = self.machine.extension(STABLE, "pub.tool", "1.0.0")
        self.machine.manifest(STABLE, [self.folder])
        self.machine.extension(INSIDERS, "pub.tool", "1.0.0")
        self.machine.manifest(INSIDERS, [self.folder])
        self.machine.user_file(STABLE, "settings.json", '{"s": 1}')
        self.machine.user_file(INSIDERS, "settings.json", '{"own": 1}')

    def test_status_and_check(self) -> None:
        """Status always succeeds; check exits 1 while work is due."""
        code, out, _ = self.machine.run("status")
        self.assertEqual(code, ExitCode.OK)
        self.assertIn("vscode-sync · Stable → Insiders", out)
        self.assertIn("2 changes; vscode-sync setup applies them.", out)
        code, out, _ = self.machine.run("check", "--json")
        self.assertEqual(code, ExitCode.ATTENTION)
        report = json.loads(out)
        self.assertEqual(
            [change["kind"] for change in report["changes"]],
            ["link-item", "link-folder"],
        )

    def test_dry_run_changes_nothing(self) -> None:
        """A dry run reports and exits 1 when something is due."""
        before = self.machine.tree()
        code, out, _ = self.machine.run("setup", "--dry-run")
        self.assertEqual(code, ExitCode.ATTENTION)
        self.assertIn("Changes · 2", out)
        self.assertEqual(self.machine.tree(), before)

    def test_refusals(self) -> None:
        """No terminal, a running editor or a leftover run stop a change."""
        before = self.machine.tree()
        code, _, err = self.machine.run("setup")
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("pass --yes", err)
        code, _, err = self.machine.run("setup", "--yes", processes=RUNNING)
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("close VS Code Stable first", err)
        leftover = self.machine.host.state_dir() / "runs" / "old"
        leftover.mkdir(parents=True)
        code, _, err = self.machine.run("setup", "--yes")
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("interrupted", err)
        self.assertEqual(self.machine.tree(), before)

    def test_setup_then_remove(self) -> None:
        """Setup shares and keeps Insiders' own settings; remove undoes."""
        code, out, err = self.machine.run("setup", "--yes")
        self.assertEqual((code, err), (ExitCode.OK, ""))
        self.assertIn("Applied 2 changes", out)
        self.assertIn("kept Insiders' own", out)
        shared = self.machine.root(INSIDERS) / self.folder
        self.assertTrue(shared.is_symlink())
        self.assertEqual(self.machine.run("check")[0], ExitCode.OK)
        kept = list((self.machine.host.state_dir() / "kept").rglob("*.json"))
        self.assertEqual([path.read_text() for path in kept], ['{"own": 1}'])
        self.assertFalse(
            any((self.machine.host.state_dir() / "runs").iterdir())
        )
        code, out, _ = self.machine.run("remove", "--yes")
        self.assertEqual(code, ExitCode.OK)
        self.assertFalse(shared.is_symlink())
        self.assertTrue((shared / "package.json").is_file())
        self.assertEqual(self.machine.run("remove", "--dry-run")[0], 0)

    def test_declining_changes_nothing(self) -> None:
        """No at the prompt leaves everything as it was."""
        before = self.machine.tree()
        with patch("builtins.input", return_value="n"):
            code, out, _ = self.machine.run("setup", terminal=True)
        self.assertEqual(code, ExitCode.OK)
        self.assertIn("Nothing was changed.", out)
        self.assertEqual(self.machine.tree(), before)

    def test_clean(self) -> None:
        """Clean quarantines unused duplicates and reports where."""
        old = self.machine.extension(STABLE, "pub.tool", "0.5.0")
        code, out, _ = self.machine.run("clean", "--dry-run")
        self.assertEqual(code, ExitCode.ATTENTION)
        self.assertIn(old, out)
        code, out, _ = self.machine.run(
            "clean", "--yes", "--edition", "stable"
        )
        self.assertEqual(code, ExitCode.OK)
        self.assertIn("Quarantined 1 folder", out)
        self.assertFalse((self.machine.root(STABLE) / old).exists())
        quarantined = self.machine.host.state_dir() / "quarantine"
        self.assertEqual(len(list(quarantined.glob("*/stable/*"))), 1)

    def test_version(self) -> None:
        """--version prints the package version."""
        code, out, _ = self.machine.run("--version")
        self.assertEqual((code, out.strip()), (0, "vscode-sync 1.0.0"))


class UpdateCommandTests(unittest.TestCase):
    """``update`` with fake editions that install a newer build."""

    def test_insiders_follows_stables_update(self) -> None:
        """Stable updates, Insiders follows, the old build is quarantined."""
        machine = Machine(self)
        old = machine.extension(STABLE, "pub.tool", "1.0.0")
        machine.manifest(STABLE, [old])
        machine.link(old)
        machine.manifest(INSIDERS, [old])
        new = "pub.tool-2.0.0"
        entry = json.dumps([machine.entry(STABLE, new)])
        bin_dir = machine.home / "bin"
        stable_root = machine.root(STABLE)
        script(
            bin_dir,
            "code",
            f'mkdir "{stable_root}/{new}"\n'
            f'echo \'{{"publisher":"pub","name":"tool",'
            f'"version":"2.0.0"}}\' > "{stable_root}/{new}/package.json"\n'
            f"echo '{entry}' > \"{stable_root}/extensions.json\"\n"
            "echo \"Extension 'pub.tool' v2.0.0 was successfully updated.\"",
        )
        script(bin_dir, "code-insiders", 'echo "All extensions up to date"')
        machine.set_env(PATH=str(bin_dir))
        code, out, err = machine.run("update", "--yes")
        self.assertEqual((code, err), (ExitCode.OK, ""), out)
        self.assertIn("1 extension updated", out)
        self.assertIn("Quarantined 1 folder", out)
        link = machine.root(INSIDERS) / new
        self.assertTrue(link.is_symlink())
        self.assertFalse((machine.root(INSIDERS) / old).exists())
        self.assertFalse((stable_root / old).exists())
        self.assertEqual(
            machine.read_manifest(INSIDERS)[0]["relativeLocation"], new
        )

    def test_update_needs_the_stable_command(self) -> None:
        """Without code on PATH nothing runs."""
        machine = Machine(self)
        code, _, err = machine.run("update", "--yes")
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("code is not on PATH", err)


if __name__ == "__main__":
    unittest.main()
