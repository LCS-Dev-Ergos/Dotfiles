"""Choosing the files to scan, and opening them."""

import os
import unittest
from pathlib import Path

from core.files import open_regular, select, sha256
from tests.support import Folder


class SelectTests(unittest.TestCase):
    """Which files a scan covers."""

    def setUp(self) -> None:
        """A folder with files, a subfolder, links and a named pipe."""
        self.folder = Folder(self)
        root = self.folder.root
        self.a = self.folder.file("a.txt", b"a")
        self.b = self.folder.file("sub/b.txt", b"b")
        os.symlink(self.a, root / "link.txt")
        os.symlink(root / "sub", root / "linked")
        os.mkfifo(root / "pipe")
        os.link(self.a, root / "hard.txt")

    def test_a_folder_is_walked_without_links_or_pipes(self) -> None:
        """Regular files once each; links and the pipe are counted."""
        selection = select([self.folder.root])
        self.assertEqual(selection.files, [self.a, self.b])
        self.assertEqual(selection.skipped, {"link": 2, "special": 1})
        self.assertEqual(selection.problems, [])

    def test_no_recursive_stays_at_the_top(self) -> None:
        """Only the folder's own files."""
        selection = select([self.folder.root], recursive=False)
        self.assertEqual(selection.files, [self.a])

    def test_named_paths_are_followed_and_checked(self) -> None:
        """A named link is followed; missing paths and pipes are problems."""
        root = self.folder.root
        selection = select(
            [root / "link.txt", root / "missing", root / "pipe", self.a]
        )
        self.assertEqual(selection.files, [root / "link.txt"])
        self.assertEqual(
            selection.problems,
            [
                (root / "missing", "Not found"),
                (root / "pipe", "Not a regular file"),
            ],
        )

    def test_relative_paths_become_absolute(self) -> None:
        """Paths read as given, from the current folder."""
        here = Path.cwd()
        os.chdir(self.folder.root)
        self.addCleanup(os.chdir, here)
        selection = select([Path("sub")])
        self.assertEqual(selection.files, [self.b])

    @unittest.skipIf(os.geteuid() == 0, "root reads every folder")
    def test_an_unreadable_folder_is_a_problem(self) -> None:
        """A gap in the walk is reported, never silent."""
        locked = self.folder.root / "sub"
        locked.chmod(0)
        self.addCleanup(locked.chmod, 0o755)
        selection = select([self.folder.root])
        self.assertEqual(selection.files, [self.a])
        self.assertEqual(selection.problems, [(locked, "Permission denied")])


class OpenTests(unittest.TestCase):
    """Opening a file to read it."""

    def test_a_pipe_is_refused_without_waiting(self) -> None:
        """Opening a named pipe with no writer would block forever."""
        folder = Folder(self)
        pipe = folder.root / "pipe"
        os.mkfifo(pipe)
        with self.assertRaisesRegex(OSError, "Not a regular file"):
            open_regular(pipe)

    def test_the_digest_covers_the_whole_file(self) -> None:
        """SHA-256 of a known content."""
        path = Folder(self).file("data", b"abc")
        self.assertEqual(
            sha256(path),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        )


if __name__ == "__main__":
    unittest.main()
