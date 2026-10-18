"""Extracting, deleting, rotating, merging and splitting pages."""

import unittest

import pikepdf

from core import outline
from tests.support import Folder


def titles(path) -> list[tuple[int, str, int | None]]:
    """Each bookmark's depth, title and page, counted from 1."""
    with pikepdf.open(path) as pdf:
        return [
            (depth, mark.title, None if mark.page is None else mark.page + 1)
            for depth, mark in outline.flatten(outline.read(pdf))
        ]


class ExtractTests(unittest.TestCase):
    """Keeping chosen pages."""

    def setUp(self) -> None:
        """A five-page book with bookmarks and a title."""
        self.folder = Folder(self)
        self.book = self.folder.pdf(
            "book.pdf", 5, bookmarks=True, info={"Title": "Book"}
        )

    def test_pages_order_info_and_bookmarks(self) -> None:
        """Chosen pages in order; bookmarks follow their pages."""
        status, out, _ = self.folder.run("extract", str(self.book), "4,1-2")
        self.assertEqual(status, 0)
        result = self.folder.root / "book_pages_4,1-2.pdf"
        self.assertIn(f"Wrote {result} · 3 pages", out)
        texts = self.folder.texts(result)
        self.assertIn("Body of page 4", texts[0])
        self.assertIn("Body of page 2", texts[2])
        self.assertEqual(
            titles(result),
            [
                (0, "Chapter 1", 2),
                (1, "Section 1.1", 2),
                (0, "Chapter 2", 3),
                (0, "Chapter 4", 1),
            ],
        )
        with pikepdf.open(result) as pdf:
            self.assertEqual(str(pdf.docinfo.Title), "Book")

    def test_outputs_are_never_overwritten_silently(self) -> None:
        """A second run needs --force."""
        target = self.folder.root / "one.pdf"
        self.folder.run("extract", str(self.book), "1", "-o", str(target))
        status, _, err = self.folder.run(
            "extract", str(self.book), "2", "-o", str(target)
        )
        self.assertEqual(status, 1)
        self.assertIn("--force replaces it", err)
        self.assertIn("Body of page 1", self.folder.texts(target)[0])
        status, _, _ = self.folder.run(
            "extract", str(self.book), "2", "-o", str(target), "--force"
        )
        self.assertEqual(status, 0)
        self.assertIn("Body of page 2", self.folder.texts(target)[0])

    def test_a_missing_page_is_a_usage_error(self) -> None:
        """Nothing is written."""
        status, _, err = self.folder.run("extract", str(self.book), "9")
        self.assertEqual(status, 2)
        self.assertIn("Page 9 is outside", err)
        self.assertEqual(
            sorted(p.name for p in self.folder.root.iterdir()), ["book.pdf"]
        )

    def test_an_owner_password_is_not_dropped(self) -> None:
        """A new document cannot keep it, so the commands refuse."""
        restricted = self.folder.pdf("r.pdf", 2, owner="boss")
        joined = str(self.folder.root / "joined.pdf")
        for argv in (
            ("extract", str(restricted), "1"),
            ("delete", str(restricted), "1"),
            ("split", str(restricted)),
            ("merge", str(self.book), str(restricted), "-o", joined),
        ):
            with self.subTest(command=argv[0]):
                status, _, err = self.folder.run(*argv)
                self.assertEqual(status, 1)
                self.assertIn("pdf-tools unlock removes it first", err)
        self.assertEqual(
            sorted(p.name for p in self.folder.root.iterdir()),
            ["book.pdf", "r.pdf"],
        )


class DeleteRotateTests(unittest.TestCase):
    """Removing and turning pages."""

    def setUp(self) -> None:
        """A four-page book."""
        self.folder = Folder(self)
        self.book = self.folder.pdf("book.pdf", 4, bookmarks=True)

    def test_delete_in_place_keeps_other_bookmarks(self) -> None:
        """The input is replaced; bookmarks of removed pages go."""
        status, out, _ = self.folder.run(
            "delete", str(self.book), "2-3", "--in-place"
        )
        self.assertEqual(status, 0)
        self.assertIn("removed 2 pages · 2 left", out)
        self.assertEqual(len(self.folder.texts(self.book)), 2)
        self.assertEqual(
            [title for _, title, _ in titles(self.book)],
            ["Chapter 1", "Section 1.1", "Chapter 4"],
        )

    def test_delete_refuses_to_empty_the_document(self) -> None:
        """Removing every page is a usage error."""
        status, _, err = self.folder.run("delete", str(self.book), "1-z")
        self.assertEqual(status, 2)
        self.assertIn("nothing would remain", err)

    def test_in_place_follows_a_link(self) -> None:
        """The linked file changes; the link stays a link."""
        link = self.folder.root / "link.pdf"
        link.symlink_to(self.book.name)
        status, _, _ = self.folder.run("rotate", str(link), "right", "-i")
        self.assertEqual(status, 0)
        self.assertTrue(link.is_symlink())
        with pikepdf.open(self.book) as pdf:
            self.assertEqual(pdf.pages[0].obj.Rotate, 90)

    def test_rotation_adds_to_the_current_turn(self) -> None:
        """Turning right twice is 180 degrees; other pages stay."""
        self.folder.run("rotate", str(self.book), "right", "1", "-i")
        self.folder.run("rotate", str(self.book), "90", "1,2", "-i")
        with pikepdf.open(self.book) as pdf:
            turns = [int(page.obj.get("/Rotate", 0)) for page in pdf.pages]
        self.assertEqual(turns, [180, 90, 0, 0])


class MergeSplitTests(unittest.TestCase):
    """Joining and splitting."""

    def setUp(self) -> None:
        """Two books."""
        self.folder = Folder(self)
        self.first = self.folder.pdf("first.pdf", 2, bookmarks=True)
        self.second = self.folder.pdf("second.pdf", 3)

    def test_merge_nests_each_files_bookmarks(self) -> None:
        """One bookmark per file, its own beneath it, pages shifted."""
        target = self.folder.root / "all.pdf"
        status, out, _ = self.folder.run(
            "merge", str(self.first), str(self.second), "-o", str(target)
        )
        self.assertEqual(status, 0)
        self.assertIn("2 files · 5 pages", out)
        self.assertEqual(
            titles(target),
            [
                (0, "first", 1),
                (1, "Chapter 1", 1),
                (2, "Section 1.1", 1),
                (1, "Chapter 2", 2),
                (0, "second", 3),
            ],
        )
        self.assertIn("Body of page 1", self.folder.texts(target)[2])

    def test_split_every_and_at(self) -> None:
        """Equal parts, or parts starting at chosen pages."""
        book = self.folder.pdf("book.pdf", 5)
        status, out, _ = self.folder.run("split", str(book), "--every", "2")
        self.assertEqual(status, 0)
        folder = self.folder.root / "book_parts"
        self.assertIn(f"Wrote 3 parts to {folder}", out)
        names = sorted(path.name for path in folder.iterdir())
        self.assertEqual(names, ["book_1.pdf", "book_2.pdf", "book_3.pdf"])
        self.assertEqual(len(self.folder.texts(folder / "book_3.pdf")), 1)
        status, _, err = self.folder.run("split", str(book), "--at", "3")
        self.assertEqual(status, 1)
        self.assertIn("is not empty", err)
        status, _, _ = self.folder.run(
            "split", str(book), "--at", "3", "-o", str(self.folder.root / "p")
        )
        sizes = [
            len(self.folder.texts(self.folder.root / "p" / f"book_{n}.pdf"))
            for n in (1, 2)
        ]
        self.assertEqual(sizes, [2, 3])

    def test_an_unwritable_folder_is_an_error(self) -> None:
        """A system error is reported, not a traceback."""
        book = self.folder.pdf("book.pdf", 2)
        locked = self.folder.root / "locked"
        locked.mkdir(mode=0o500)
        self.addCleanup(locked.chmod, 0o700)
        status, _, err = self.folder.run(
            "split", str(book), "-o", str(locked / "parts")
        )
        self.assertEqual(status, 1)
        self.assertIn("Permission denied", err)


if __name__ == "__main__":
    unittest.main()
