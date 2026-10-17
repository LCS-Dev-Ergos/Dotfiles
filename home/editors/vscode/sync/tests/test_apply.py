"""Applying plans: atomic writes, transactions, rollback and quarantine."""

import os
import stat
import unittest
from pathlib import Path

from core.errors import SyncError
from core.plan import (
    LinkFolder,
    Quarantine,
    UnlinkFolder,
    WriteFile,
    plan_clean,
    plan_setup,
)
from core.storage import prune, same_content, stamp, write_atomically
from core.transaction import Transaction, quarantine
from tests.support import INSIDERS, STABLE, Machine


class WriteTests(unittest.TestCase):
    """Files are replaced whole, and only if unchanged since read."""

    def setUp(self) -> None:
        """A file to replace."""
        self.machine = Machine(self)
        self.path = self.machine.home / "file.json"
        self.path.write_bytes(b"old")
        self.path.chmod(0o640)

    def test_replacement_keeps_the_mode(self) -> None:
        """The new file has the old one's permissions."""
        write_atomically(self.path, b"old", b"new")
        self.assertEqual(self.path.read_bytes(), b"new")
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o640)

    def test_a_changed_file_is_not_replaced(self) -> None:
        """What changed after reading is never overwritten."""
        with self.assertRaises(SyncError):
            write_atomically(self.path, b"something else", b"new")
        self.assertEqual(self.path.read_bytes(), b"old")
        with self.assertRaises(SyncError):
            write_atomically(self.path, None, b"new")

    def test_a_link_is_written_through(self) -> None:
        """A symlinked file stays a symlink."""
        link = self.machine.home / "link.json"
        link.symlink_to(self.path)
        write_atomically(link, b"old", b"new")
        self.assertTrue(link.is_symlink())
        self.assertEqual(self.path.read_bytes(), b"new")

    def test_no_temporary_file_is_left(self) -> None:
        """Only the file itself remains next to it."""
        before = sorted(self.machine.home.iterdir())
        write_atomically(self.path, b"old", b"new")
        self.assertEqual(sorted(self.machine.home.iterdir()), before)


class StorageTests(unittest.TestCase):
    """Retention and content comparison."""

    def test_prune_keeps_the_newest(self) -> None:
        """Older stamped entries go; foreign names are never touched."""
        machine = Machine(self)
        directory = machine.home / "kept"
        directory.mkdir()
        names = [f"2026010{day}T000000Z-1-setup" for day in range(1, 6)]
        for name in names:
            (directory / name).mkdir()
        (directory / "mine").mkdir()
        self.assertEqual(prune(directory, 2), [])
        self.assertEqual(
            sorted(p.name for p in directory.iterdir()),
            [*names[-2:], "mine"],
        )
        self.assertRegex(stamp("clean"), r"^\d{8}T\d{6}Z-\d+-clean$")

    def test_same_content_compares_trees(self) -> None:
        """Files by bytes, directories by every file inside."""
        machine = Machine(self)
        left, right = machine.home / "l", machine.home / "r"
        for side in (left, right):
            (side / "sub").mkdir(parents=True)
            (side / "sub" / "a").write_text("1")
        self.assertTrue(same_content(left, right))
        (right / "sub" / "a").write_text("2")
        self.assertFalse(same_content(left, right))
        (right / "sub" / "a").write_text("1")
        (right / "extra").write_text("")
        self.assertFalse(same_content(left, right))


class TransactionTests(unittest.TestCase):
    """A transaction applies, keeps, or undoes everything."""

    def setUp(self) -> None:
        """Insiders with its own copy of Stable's build and own settings."""
        self.machine = Machine(self)
        self.folder = self.machine.extension(STABLE, "pub.tool", "1.0.0")
        self.machine.manifest(STABLE, [self.folder])
        old = self.machine.extension(INSIDERS, "pub.tool", "0.5.0")
        self.machine.manifest(INSIDERS, [old])
        self.machine.user_file(STABLE, "settings.json", '{"s": 1}')
        self.machine.user_file(INSIDERS, "settings.json", '{"own": 1}')
        self.machine.user_file(STABLE, "mcp.json", "{}")
        self.machine.user_file(INSIDERS, "mcp.json", "{}")
        self.state = self.machine.host.state_dir()
        self.workspace = self.state / "runs" / "test"
        self.workspace.mkdir(parents=True)

    def transaction(self) -> Transaction:
        """A transaction in the test workspace."""
        return Transaction(self.workspace, self.state / "kept" / "test")

    def test_rollback_restores_everything(self) -> None:
        """A failing step undoes every step before it, byte for byte."""
        before = self.machine.tree()
        plan = plan_setup(self.machine.snapshot())
        transaction = self.transaction()
        for operation in plan.operations:
            transaction.apply(operation)
        stale = WriteFile("test", self.machine.home / "x", b"gone", b"")
        with self.assertRaises(SyncError):
            transaction.apply(stale)
        self.assertEqual(transaction.rollback(), [])
        self.assertEqual(self.machine.tree(), before)

    def test_commit_keeps_only_differing_user_files(self) -> None:
        """Insiders' own settings are kept; an identical file is not."""
        plan = plan_setup(self.machine.snapshot())
        transaction = self.transaction()
        for operation in plan.operations:
            transaction.apply(operation)
        journal = (self.workspace / "journal.txt").read_text()
        self.assertEqual(journal.count("\n"), len(plan.operations))
        kept, warnings = transaction.commit()
        self.assertEqual(warnings, [])
        self.assertEqual([path.read_text() for path in kept], ['{"own": 1}'])
        self.assertFalse(self.workspace.exists())

    def test_a_failed_link_puts_the_original_back(self) -> None:
        """A step that fails half way leaves nothing changed."""
        target = self.machine.root(INSIDERS) / "pub.tool-0.5.0"
        blocked = self.machine.root(INSIDERS)
        blocked.chmod(0o500)
        self.addCleanup(blocked.chmod, 0o755)
        transaction = self.transaction()
        operation = LinkFolder("pub.tool-0.5.0", target, Path("/nowhere"))
        with self.assertRaises(SyncError):
            transaction.apply(operation)
        self.assertTrue(target.is_dir())
        self.assertFalse(target.is_symlink())

    def test_unlink_only_takes_links(self) -> None:
        """Removing a directory as if it were a link fails."""
        target = self.machine.root(INSIDERS) / "pub.tool-0.5.0"
        with self.assertRaises(SyncError):
            self.transaction().apply(UnlinkFolder(target.name, target))
        self.assertTrue(target.is_dir())


class QuarantineTests(unittest.TestCase):
    """Clean moves folders aside, and only real ones."""

    def test_folders_move_into_the_quarantine(self) -> None:
        """The moved folders keep their content; a changed one stays."""
        machine = Machine(self)
        old = machine.extension(STABLE, "pub.tool", "1.0.0")
        gone = machine.extension(STABLE, "pub.tool", "1.5.0")
        machine.extension(STABLE, "pub.tool", "2.0.0")
        plan = plan_clean(machine.snapshot(), [STABLE])
        os.rename(machine.root(STABLE) / gone, machine.home / "moved")
        (machine.root(STABLE) / gone).symlink_to(machine.home / "moved")
        roots = {
            STABLE: machine.root(STABLE),
            INSIDERS: machine.root(INSIDERS),
        }
        operations = [
            op for op in plan.operations if isinstance(op, Quarantine)
        ]
        result = quarantine(operations, roots, machine.host.state_dir())
        self.assertEqual(len(result.moved), 1)
        self.assertTrue((result.moved[0] / "package.json").is_file())
        self.assertFalse((machine.root(STABLE) / old).exists())
        self.assertEqual(len(result.failed), 1)
        self.assertTrue((machine.home / "moved").is_dir())


if __name__ == "__main__":
    unittest.main()
