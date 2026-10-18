"""Page selections, outputs and safe saving."""

import os
import stat
import unittest

import pikepdf

from core.documents import (
    ToolError,
    UsageError,
    check_target,
    compact,
    open_pdf,
    parse_pages,
    replacing,
    save,
)
from tests.support import Folder


class SelectionTests(unittest.TestCase):
    """Reading page selections."""

    def test_pages_ranges_and_the_last_page(self) -> None:
        """Order is kept, ranges may run backwards, z is the last page."""
        self.assertEqual(
            parse_pages("1-3,7,10-z", 12), [0, 1, 2, 6, 9, 10, 11]
        )
        self.assertEqual(parse_pages("3-1", 5), [2, 1, 0])
        self.assertEqual(parse_pages("last, 1", 4), [3, 0])

    def test_bad_selections_are_usage_errors(self) -> None:
        """Malformed parts and missing pages say what is wrong."""
        for spec, message in (
            ("0", "Page 0 is outside"),
            ("2-9", "Page 9 is outside the document, which has 5 pages"),
            ("1,,2", "has an empty part"),
            ("a-b", "Not a page or range: a-b"),
            ("1-" + "9" * 5000, "Not a page or range"),
        ):
            with self.subTest(spec=spec):
                with self.assertRaisesRegex(UsageError, message):
                    parse_pages(spec, 5)

    def test_compact_writes_runs(self) -> None:
        """Consecutive pages fold into ranges."""
        self.assertEqual(compact([0, 1, 2, 6, 9, 10]), "1-3,7,10-11")
        self.assertEqual(compact([4]), "5")


class TargetTests(unittest.TestCase):
    """Refusing outputs that would lose data."""

    def setUp(self) -> None:
        """A folder with one PDF."""
        self.folder = Folder(self)
        self.source = self.folder.pdf("a.pdf")

    def test_existing_outputs_need_force(self) -> None:
        """An existing file, the input itself, a folder or a missing parent."""
        other = self.folder.pdf("b.pdf")
        with self.assertRaisesRegex(ToolError, "--force replaces it"):
            check_target(other, force=False)
        check_target(other, force=True)
        with self.assertRaisesRegex(ToolError, "--in-place replaces it"):
            check_target(self.source, force=True, sources=(self.source,))
        with self.assertRaisesRegex(ToolError, "is a folder"):
            check_target(self.folder.root, force=True)
        with self.assertRaisesRegex(ToolError, "does not exist"):
            check_target(self.folder.root / "no" / "x.pdf", force=True)

    def test_a_failed_write_leaves_the_target(self) -> None:
        """The temporary file goes, the old file stays."""
        before = self.source.read_bytes()
        with self.assertRaises(RuntimeError):
            with replacing(self.source) as temporary:
                temporary.write_bytes(b"half")
                raise RuntimeError
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(os.listdir(self.folder.root), ["a.pdf"])

    def test_modes_new_and_in_place(self) -> None:
        """A new file follows the umask; an in-place one keeps its mode."""
        self.source.chmod(0o640)
        with open_pdf(self.source) as pdf:
            save(pdf, self.source, keep_mode_of=self.source)
            fresh = self.folder.root / "fresh.pdf"
            save(pdf, fresh)
        self.assertEqual(stat.S_IMODE(self.source.stat().st_mode), 0o640)
        umask = os.umask(0)
        os.umask(umask)
        self.assertEqual(stat.S_IMODE(fresh.stat().st_mode), 0o666 & ~umask)


class OpenTests(unittest.TestCase):
    """Opening documents."""

    def test_errors_name_the_problem(self) -> None:
        """Missing, not a PDF, locked."""
        folder = Folder(self)
        with self.assertRaisesRegex(ToolError, "does not exist"):
            open_pdf(folder.root / "none.pdf")
        junk = folder.root / "junk.pdf"
        junk.write_bytes(b"not a pdf at all")
        with self.assertRaisesRegex(ToolError, "not a readable PDF"):
            open_pdf(junk)
        locked = folder.pdf("locked.pdf", password="secret")
        with self.assertRaisesRegex(ToolError, "pdf-tools unlock"):
            open_pdf(locked)
        with self.assertRaisesRegex(ToolError, "Wrong password"):
            open_pdf(locked, "nope")
        with open_pdf(locked, "secret") as pdf:
            self.assertEqual(len(pdf.pages), 3)

    def test_saving_keeps_an_owner_password(self) -> None:
        """pikepdf alone would drop the restriction."""
        folder = Folder(self)
        restricted = folder.pdf("r.pdf", owner="boss")
        copy = folder.root / "copy.pdf"
        with open_pdf(restricted) as pdf:
            save(pdf, copy)
        with pikepdf.open(copy) as pdf:
            self.assertTrue(pdf.is_encrypted)
            self.assertFalse(pdf.allow.extract)


if __name__ == "__main__":
    unittest.main()
