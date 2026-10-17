"""The command line, end to end in a throwaway home."""

import json
import shutil
import unittest
from unittest.mock import patch

from core.cli import ExitCode
from core.plan import LinkItem
from core.transaction import Transaction
from tests.support import INSIDERS, SERVER, STABLE, Machine
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
        (report,) = json.loads(out)
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
        """No terminal or a running editor stop a change."""
        before = self.machine.tree()
        code, _, err = self.machine.run("setup")
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("pass --yes", err)
        code, _, err = self.machine.run("setup", "--yes", processes=RUNNING)
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("close VS Code Stable first", err)
        self.assertEqual(self.machine.tree(), before)

    def test_an_interrupted_run_is_undone_first(self) -> None:
        """Status reports it; the next change undoes it and goes on."""
        before = self.machine.tree()
        workspace = self.machine.host.state_dir() / "runs" / "old"
        workspace.mkdir(parents=True)
        settings = self.machine.host.user_dir(INSIDERS) / "settings.json"
        source = self.machine.host.user_dir(STABLE) / "settings.json"
        Transaction(workspace).apply(
            LinkItem("settings.json", settings, source)
        )
        self.assertNotEqual(self.machine.tree(), before)
        code, out, _ = self.machine.run("check")
        self.assertEqual(code, ExitCode.ATTENTION)
        self.assertIn("the next change undoes it", out)
        code, out, err = self.machine.run("remove", "--yes")
        self.assertEqual((code, err), (ExitCode.OK, ""))
        self.assertIn("Undid an interrupted run (1 step)", out)
        self.assertEqual(self.machine.tree(), before)
        self.assertFalse(workspace.exists())

    def test_the_environment_is_reported(self) -> None:
        """Status names a running editor and the backups."""
        _, out, _ = self.machine.run("status", processes=RUNNING)
        self.assertIn("running; a change waits until it is closed", out)
        self.machine.run("setup", "--yes")
        _, out, _ = self.machine.run("status")
        self.assertIn("1 in ", out)

    def test_setup_then_remove(self) -> None:
        """Setup shares and keeps Insiders' own settings; remove undoes."""
        code, out, err = self.machine.run("setup", "--yes")
        self.assertEqual((code, err), (ExitCode.OK, ""))
        self.assertIn("Applied 2 changes", out)
        self.assertIn("Backed up to", out)
        shared = self.machine.root(INSIDERS) / self.folder
        self.assertTrue(shared.is_symlink())
        self.assertEqual(self.machine.run("check")[0], ExitCode.OK)
        backups = self.machine.host.state_dir() / "backups"
        saved = {
            path.name: path.read_text() for path in backups.rglob("*.json")
        }
        self.assertEqual(saved["settings.json"], '{"own": 1}')
        self.assertIn("extensions.json", saved)
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


DOWNLOAD = """\
while [ $# -gt 0 ]; do
  case "$1" in
    --extensions-dir) ext="$2"; shift ;;
    --install-extension) spec="$2"; shift ;;
  esac
  shift
done
echo "$spec" >> "{log}"
case "$spec" in *@*) exit 1 ;; esac
mkdir -p "$ext/pub.gone-2.0.0"
echo '{{"publisher":"pub","name":"gone","version":"2.0.0"}}' \\
  > "$ext/pub.gone-2.0.0/package.json"
echo '[{{"identifier":{{"id":"pub.gone"}},"version":"2.0.0",\
"relativeLocation":"pub.gone-2.0.0"}}]' > "$ext/extensions.json"
"""


class RepairCommandTests(unittest.TestCase):
    """A missing folder is downloaded again with Insiders' command line."""

    def setUp(self) -> None:
        """Insiders lists a build whose folder is gone."""
        self.machine = Machine(self)
        self.machine.manifest(INSIDERS, ["pub.gone-1.0.0"])
        self.bin = self.machine.home / "bin"
        self.log = self.machine.home / "downloads.log"
        self.machine.set_env(PATH=str(self.bin))

    def test_the_build_is_downloaded_and_adopted(self) -> None:
        """The named version is tried first, then the latest is adopted."""
        script(self.bin, "code-insiders", DOWNLOAD.format(log=self.log))
        code, out, err = self.machine.run("setup", "--yes")
        self.assertEqual((code, err), (ExitCode.OK, ""), out)
        self.assertEqual(
            self.log.read_text().split(), ["pub.gone@1.0.0", "pub.gone"]
        )
        adopted = self.machine.root(INSIDERS) / "pub.gone-2.0.0"
        self.assertTrue((adopted / "package.json").is_file())
        (entry,) = self.machine.read_manifest(INSIDERS)
        self.assertEqual(
            (entry["relativeLocation"], entry["version"]),
            ("pub.gone-2.0.0", "2.0.0"),
        )
        downloads = self.machine.host.state_dir() / "downloads"
        self.assertEqual(list(downloads.iterdir()), [])
        self.assertEqual(self.machine.run("check")[0], ExitCode.OK)

    def test_a_failed_download_is_an_error(self) -> None:
        """Everything else is applied; the entry stays for the next run."""
        script(self.bin, "code-insiders", "exit 1")
        self.machine.user_file(STABLE, "settings.json", "{}")
        code, out, _ = self.machine.run("setup", "--yes")
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("Not downloaded", out)
        settings = self.machine.host.user_dir(INSIDERS) / "settings.json"
        self.assertTrue(settings.is_symlink())
        self.assertEqual(
            self.machine.read_manifest(INSIDERS)[0]["relativeLocation"],
            "pub.gone-1.0.0",
        )
        self.assertEqual(self.machine.run("check")[0], ExitCode.ATTENTION)


class ServerCommandTests(unittest.TestCase):
    """Commands with VS Code Server installed next to Insiders."""

    def setUp(self) -> None:
        """Insiders and a server, both with their own copy of one build."""
        self.machine = Machine(self)
        self.folder = self.machine.extension(STABLE, "pub.tool", "1.0.0")
        self.machine.manifest(STABLE, [self.folder])
        self.command = self.machine.server(SERVER, "1.100.0")
        for consumer in (INSIDERS, SERVER):
            self.machine.extension(consumer, "pub.tool", "1.0.0")
            self.machine.manifest(consumer, [self.folder])

    def test_every_installed_consumer_is_reported(self) -> None:
        """Both by default; ``--target`` picks one."""
        code, out, _ = self.machine.run("check", "--json")
        self.assertEqual(code, ExitCode.ATTENTION)
        consumers = [plan["consumer"] for plan in json.loads(out)]
        self.assertEqual(consumers, ["insiders", "server"])
        _, out, _ = self.machine.run("status", "--target", "server")
        self.assertIn("Stable → Server", out)
        self.assertNotIn("Insiders", out)

    def test_setup_shares_with_both_and_backs_up_once(self) -> None:
        """One question, one backup, one transaction per consumer."""
        code, out, err = self.machine.run("setup", "--yes")
        self.assertEqual((code, err), (ExitCode.OK, ""), out)
        for consumer in (INSIDERS, SERVER):
            self.assertTrue(
                (self.machine.root(consumer) / self.folder).is_symlink()
            )
        backups = self.machine.host.state_dir() / "backups"
        self.assertEqual(len(list(backups.iterdir())), 1)
        self.assertEqual(self.machine.run("check")[0], ExitCode.OK)

    def test_a_connected_client_stops_a_change(self) -> None:
        """The server's processes count as running."""
        server = self.command.parent.parent / "node"
        code, _, err = self.machine.run(
            "setup", "--yes", processes=[f"{server} out/server-main.js"]
        )
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("close VS Code Server first", err)
        _, _, err = self.machine.run(
            "setup",
            "--yes",
            "--target",
            "insiders",
            processes=[f"{server} out/server-main.js"],
        )
        self.assertEqual(err, "")

    def test_update_runs_the_servers_own_command_line(self) -> None:
        """The server's build updates its own extensions."""
        bin_dir = self.machine.home / "bin"
        script(bin_dir, "code", 'echo "All extensions up to date"')
        self.machine.set_env(PATH=str(bin_dir))
        code, out, err = self.machine.run(
            "update", "--yes", "--target", "server"
        )
        self.assertEqual((code, err), (ExitCode.OK, ""), out)
        calls = (self.command.parent.parent / "calls").read_text()
        root = self.machine.root(SERVER)
        self.assertEqual(
            calls.strip(), f"--extensions-dir {root} --update-extensions"
        )

    def test_a_missing_folder_is_downloaded_by_the_server(self) -> None:
        """The download names the server's data directory option."""
        self.machine.manifest(SERVER, ["pub.gone-1.0.0"])
        log = self.machine.home / "downloads.log"
        script(
            self.command.parent,
            "code-server",
            f'echo "$1" >> "{log}"\n'
            + DOWNLOAD.format(log=self.machine.home / "specs.log"),
        )
        code, out, err = self.machine.run(
            "setup", "--yes", "--target", "server"
        )
        self.assertEqual((code, err), (ExitCode.OK, ""), out)
        self.assertEqual(set(log.read_text().split()), {"--server-data-dir"})
        adopted = self.machine.root(SERVER) / "pub.gone-2.0.0"
        self.assertTrue((adopted / "package.json").is_file())


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

    def test_stable_alone_is_updated_without_insiders(self) -> None:
        """A host without Insiders updates and cleans Stable only."""
        machine = Machine(self)
        old = machine.extension(STABLE, "pub.tool", "1.0.0")
        new = machine.extension(STABLE, "pub.tool", "2.0.0")
        machine.manifest(STABLE, [new])
        shutil.rmtree(machine.root(INSIDERS).parent)
        shutil.rmtree(machine.host.user_dir(INSIDERS).parent)
        bin_dir = machine.home / "bin"
        script(bin_dir, "code", 'echo "All extensions up to date"')
        script(bin_dir, "code-insiders", "exit 7")
        machine.set_env(PATH=str(bin_dir))
        code, out, _ = machine.run("status")
        self.assertIn("not installed here; nothing to share", out)
        self.assertNotIn("User files", out)
        code, out, err = machine.run("update", "--yes")
        self.assertEqual((code, err), (ExitCode.OK, ""), out)
        self.assertIn("quarantine unused duplicates in Stable", out)
        self.assertNotIn("code-insiders", out)
        self.assertNotIn("Insiders already follows", out)
        self.assertFalse((machine.root(STABLE) / old).exists())

    def test_update_needs_the_stable_command(self) -> None:
        """Without code on PATH nothing runs."""
        machine = Machine(self)
        code, _, err = machine.run("update", "--yes")
        self.assertEqual(code, ExitCode.ERROR)
        self.assertIn("code is not on PATH", err)


if __name__ == "__main__":
    unittest.main()
