"""Reading, backing up and atomically replacing settings files."""

import stat
import unittest
from pathlib import Path
from unittest import mock

from core import storage
from core.errors import SettingsError
from core.plan import build_plan
from core.storage import Backups, SettingsFile, WriteResult, commit, load
from tests.support import CRLF_SETTINGS, Machine


class FileTests(unittest.TestCase):
    """A whole run over a settings file on a throwaway machine."""

    def setUp(self) -> None:
        """Give the machine a clangd, so every plan has something to write."""
        self.m = Machine(self)
        self.m.tool("clangd")
        self.backups = Backups.for_host(self.m.host)

    def planned(self, path: Path) -> tuple[SettingsFile, str]:
        """Load ``path`` and plan a run over it."""
        file = load(path)
        return file, build_plan(file.path, file.text, self.m.host).new_text

    def apply(self, path: Path) -> WriteResult:
        """Plan and commit a run over ``path``."""
        file, text = self.planned(path)
        return commit(file, text, self.backups)

    def saved(self) -> list[Path]:
        """The backups currently on disk, oldest first."""
        return sorted(self.backups.directory.glob("settings-*.json"))

    def test_backups_live_in_the_state_directory(self) -> None:
        """Backups go below XDG_STATE_HOME, never next to the settings."""
        expected = self.m.state / "vscode-host-settings" / "backups"
        self.assertEqual(self.backups.directory, expected)

    def test_apply_keeps_the_mode_and_discards_its_backup(self) -> None:
        """A successful write keeps the file mode and leaves no backup."""
        path = self.m.settings(CRLF_SETTINGS)
        path.chmod(0o640)
        before = path.read_bytes()
        result = self.apply(path)
        self.assertNotEqual(path.read_bytes(), before)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
        self.assertEqual(result, WriteResult(written=True))
        self.assertEqual(self.saved(), [])

    def test_the_backup_exists_while_the_write_runs(self) -> None:
        """The original is on disk, private, before the file is replaced."""
        path = self.m.settings(CRLF_SETTINGS)
        before = path.read_bytes()
        file, text = self.planned(path)
        seen: list[tuple[bytes, int, int]] = []
        real_replace = storage.replace_atomically

        def observing(target: Path, expected: bytes, data: bytes) -> list[str]:
            """Record the backup as it is at the moment of replacement."""
            (backup,) = self.saved()
            seen.append(
                (
                    backup.read_bytes(),
                    stat.S_IMODE(backup.stat().st_mode),
                    stat.S_IMODE(backup.parent.stat().st_mode),
                )
            )
            return real_replace(target, expected, data)

        with mock.patch.object(storage, "replace_atomically", observing):
            commit(file, text, self.backups)
        self.assertEqual(seen, [(before, 0o600, 0o700)])
        self.assertEqual(self.saved(), [])

    def test_a_failed_write_keeps_the_backup_and_names_it(self) -> None:
        """A refused write leaves the backup, and the error names it."""
        path = self.m.settings(CRLF_SETTINGS)
        file, text = self.planned(path)
        path.write_bytes(file.raw + b"// edited meanwhile\r\n")
        with self.assertRaisesRegex(SettingsError, "changed while") as caught:
            commit(file, text, self.backups)
        (backup,) = self.saved()
        self.assertIn(
            f"the previous file is kept at {backup}", str(caught.exception)
        )
        self.assertEqual(backup.read_bytes(), file.raw)
        self.assertTrue(path.read_bytes().endswith(b"// edited meanwhile\r\n"))
        self.assertEqual(list(self.m.root.glob(".settings.json.*")), [])

    def test_a_backup_that_cannot_be_removed_is_reported(self) -> None:
        """A leftover backup is returned with the reason, not hidden."""
        path = self.m.settings(CRLF_SETTINGS)
        with mock.patch.object(Backups, "discard", return_value=["busy"]):
            result = self.apply(path)
        self.assertTrue(result.written)
        self.assertEqual(result.backup, self.saved()[0])
        self.assertEqual(result.warnings, ("busy",))

    def test_second_apply_writes_nothing_and_makes_no_backup(self) -> None:
        """A run with nothing to change neither writes nor backs up."""
        path = self.m.settings(CRLF_SETTINGS)
        self.apply(path)
        stamp = path.stat().st_mtime_ns
        self.assertEqual(self.apply(path), WriteResult(written=False))
        self.assertEqual(path.stat().st_mtime_ns, stamp)
        self.assertEqual(self.saved(), [])

    def test_symlink_is_followed_and_kept(self) -> None:
        """The real file behind a link is written and the link survives."""
        real = self.m.settings(CRLF_SETTINGS)
        link = self.m.root / "insiders.json"
        link.symlink_to(real)
        self.apply(link)
        self.assertTrue(link.is_symlink())
        self.assertIn(str(self.m.profile), real.read_text())

    def test_bom_is_preserved(self) -> None:
        """A byte order mark is written back exactly once."""
        path = self.m.root / "settings.json"
        path.write_bytes(b"\xef\xbb\xbf" + CRLF_SETTINGS.encode())
        self.apply(path)
        self.assertTrue(path.read_bytes().startswith(b"\xef\xbb\xbf{"))

    def test_invalid_utf8_is_refused_and_untouched(self) -> None:
        """Bytes that are not UTF-8 stop the run before any planning."""
        path = self.m.root / "settings.json"
        path.write_bytes(b'{"a": "\xff"}')
        with self.assertRaisesRegex(SettingsError, "UTF-8"):
            load(path)
        self.assertEqual(path.read_bytes(), b'{"a": "\xff"}')

    def test_unparseable_file_is_never_written(self) -> None:
        """Invalid JSONC is refused before a backup is even made."""
        path = self.m.settings('{"a": ')
        with self.assertRaises(SettingsError):
            self.apply(path)
        self.assertEqual(path.read_text(), '{"a": ')
        self.assertFalse(self.backups.directory.exists())

    def test_missing_directory_and_looping_targets_are_refused(self) -> None:
        """Only an existing regular file, reached without a loop, is read."""
        loop = self.m.root / "loop.json"
        loop.symlink_to(loop)
        for path in (self.m.root / "nope.json", self.m.root, loop):
            with self.subTest(path=path), self.assertRaises(SettingsError):
                load(path)

    def test_oversized_file_is_refused(self) -> None:
        """A file above the size limit is not read at all."""
        path = self.m.settings("{" + " " * 16 + "}")
        with mock.patch.object(storage, "MAX_SETTINGS_BYTES", 8):
            with self.assertRaisesRegex(SettingsError, "larger than"):
                load(path)

    def test_a_failed_read_back_restores_the_original(self) -> None:
        """A file that reads back differently is replaced by the original."""
        path = self.m.settings(CRLF_SETTINGS)
        file, text = self.planned(path)
        real_replace = storage.replace_atomically

        def corrupting(
            target: Path, expected: bytes, data: bytes
        ) -> list[str]:
            """Replace as usual, then damage the new content."""
            warnings = real_replace(target, expected, data)
            if data != file.raw:
                target.write_bytes(data + b" ")
            return warnings

        with mock.patch.object(storage, "replace_atomically", corrupting):
            with self.assertRaisesRegex(SettingsError, "original is back"):
                commit(file, text, self.backups)
        self.assertEqual(path.read_bytes(), file.raw)
        self.assertEqual(len(self.saved()), 1)


class BackupTests(unittest.TestCase):
    """The backup directory on its own."""

    def setUp(self) -> None:
        """A backup directory that keeps three files."""
        self.m = Machine(self)
        self.backups = Backups(self.m.root / "backups", keep=3)

    def fill(self, count: int) -> None:
        """Leave ``count`` old backups in the directory."""
        self.backups.directory.mkdir()
        for index in range(count):
            name = f"settings-0000{index}.json"
            (self.backups.directory / name).write_text("")

    def test_backups_are_pruned_to_the_newest(self) -> None:
        """Saving a backup removes all but the newest ``keep``."""
        self.fill(5)
        newest, warnings = self.backups.save(b"{}")
        kept = sorted(self.backups.directory.glob("settings-*.json"))
        self.assertEqual(len(kept), 3)
        self.assertEqual(kept[-1], newest)
        self.assertEqual(warnings, [])

    def test_a_failed_prune_is_a_warning(self) -> None:
        """A backup that cannot be pruned is reported, and the save stands."""
        self.fill(3)
        with mock.patch.object(Path, "unlink", side_effect=PermissionError):
            _, warnings = self.backups.save(b"{}")
        self.assertEqual(len(warnings), 1)
        self.assertIn("cannot remove", warnings[0])

    def test_discard_removes_or_reports(self) -> None:
        """Discarding removes the file, or says why it could not."""
        backup, _ = self.backups.save(b"{}")
        self.assertEqual(self.backups.discard(backup), [])
        self.assertFalse(backup.exists())
        warnings = self.backups.discard(backup)
        self.assertEqual(len(warnings), 1)
        self.assertIn("cannot remove the backup", warnings[0])

    def test_an_existing_backup_is_never_overwritten(self) -> None:
        """A name collision fails the save instead of replacing the file."""
        first, _ = self.backups.save(b"{}")
        stamp = first.name.split("-")[1]
        with mock.patch.object(storage, "datetime") as clock:
            clock.now.return_value.strftime.return_value = stamp
            with self.assertRaisesRegex(SettingsError, "cannot create"):
                self.backups.save(b"{}")
        self.assertEqual(first.read_bytes(), b"{}")

    def test_at_least_one_backup_is_kept(self) -> None:
        """A directory that keeps nothing is a configuration error."""
        with self.assertRaises(ValueError):
            Backups(self.m.root, keep=0)

    def test_a_directory_that_cannot_be_flushed_is_a_warning(self) -> None:
        """A failed directory flush is reported without failing the write."""
        warnings = storage.sync_directory(self.m.root / "missing")
        self.assertEqual(len(warnings), 1)
        self.assertIn("may not survive a crash", warnings[0])


if __name__ == "__main__":
    unittest.main()
