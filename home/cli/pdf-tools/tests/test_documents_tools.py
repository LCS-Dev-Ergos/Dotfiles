"""Bookmarks, metadata, passwords, compression, DjVu and info."""

import os
import stat
import threading
import unittest

import pikepdf

from tests.support import Folder, script
from tests.test_pages import titles


class BookmarkTests(unittest.TestCase):
    """Showing and copying bookmarks."""

    def setUp(self) -> None:
        """A source with bookmarks and a shorter target without."""
        self.folder = Folder(self)
        self.source = self.folder.pdf("source.pdf", 4, bookmarks=True)
        self.target = self.folder.pdf("target.pdf", 3)

    def test_show_lists_pages_and_depth(self) -> None:
        """One row per bookmark, nested titles indented."""
        status, out, _ = self.folder.run("bookmarks", "show", str(self.source))
        self.assertEqual(status, 0)
        self.assertIn("5 bookmarks", out)
        self.assertIn("1       Section 1.1", out)

    def test_copy_keeps_the_tree_and_drops_missing_pages(self) -> None:
        """Chapter 4 points past the target's end."""
        status, out, _ = self.folder.run(
            "bookmarks", "copy", str(self.source), str(self.target)
        )
        self.assertEqual(status, 0)
        self.assertIn("4 bookmarks · 1 dropped: their pages are missing", out)
        result = self.folder.root / "target_bookmarks.pdf"
        self.assertEqual(
            titles(result),
            [
                (0, "Chapter 1", 1),
                (1, "Section 1.1", 1),
                (0, "Chapter 2", 2),
                (0, "Chapter 3", 3),
            ],
        )

    def test_a_source_without_bookmarks_fails(self) -> None:
        """Nothing to copy is an error, and nothing is written."""
        status, _, err = self.folder.run(
            "bookmarks", "copy", str(self.target), str(self.source)
        )
        self.assertEqual(status, 1)
        self.assertIn("has no bookmarks", err)

    def test_a_broken_outline_in_the_target_is_replaced(self) -> None:
        """An /Outlines that is not a dictionary does not stop the copy."""
        with pikepdf.open(self.target, allow_overwriting_input=True) as pdf:
            pdf.Root.Outlines = pikepdf.Array([1])
            pdf.save()
        status, _, _ = self.folder.run(
            "bookmarks", "copy", str(self.source), str(self.target), "-i"
        )
        self.assertEqual(status, 0)
        self.assertEqual(len(titles(self.target)), 4)


class MetadataTests(unittest.TestCase):
    """Showing and stripping metadata."""

    def setUp(self) -> None:
        """A PDF with document information and an XMP packet."""
        self.folder = Folder(self)
        self.path = self.folder.pdf(
            "doc.pdf", info={"Author": "Ada Lovelace", "Title": "Notes"}
        )
        with pikepdf.open(self.path, allow_overwriting_input=True) as pdf:
            with pdf.open_metadata(
                set_pikepdf_as_editor=False, update_docinfo=False
            ) as meta:
                meta["xmp:CreatorTool"] = "Secret Writer"
            pdf.save(self.path)

    def test_show_lists_info_and_xmp(self) -> None:
        """Both sources, with short XMP prefixes."""
        status, out, _ = self.folder.run("metadata", "show", str(self.path))
        self.assertEqual(status, 0)
        self.assertIn("Ada Lovelace", out)
        self.assertIn("xmp:CreatorTool", out)

    def test_strip_leaves_no_trace_in_the_file(self) -> None:
        """The old values are gone from the bytes, not just hidden."""
        status, out, _ = self.folder.run(
            "metadata", "strip", str(self.path), "--in-place"
        )
        self.assertEqual(status, 0)
        self.assertIn("removed", out)
        data = self.path.read_bytes()
        for secret in (b"Ada", b"Lovelace", b"Secret Writer", b"/Info"):
            self.assertNotIn(secret, data)

    def test_strip_several_reports_failures(self) -> None:
        """A bad file fails alone; -o is refused for several."""
        other = self.folder.pdf("other.pdf")
        missing = self.folder.root / "missing.pdf"
        status, out, err = self.folder.run(
            "metadata", "strip", str(self.path), str(missing), str(other)
        )
        self.assertEqual(status, 1)
        self.assertIn("2 of 3 files stripped", err)
        self.assertTrue((self.folder.root / "other_stripped.pdf").exists())
        status, _, err = self.folder.run(
            "metadata", "strip", str(self.path), str(other), "-o", "x.pdf"
        )
        self.assertEqual(status, 2)


class PasswordTests(unittest.TestCase):
    """Protecting and unlocking."""

    def setUp(self) -> None:
        """A PDF and a password file."""
        self.folder = Folder(self)
        self.path = self.folder.pdf("doc.pdf")
        self.secret = self.folder.root / "secret.txt"
        self.secret.write_text("correct horse\n")

    def test_protect_then_unlock(self) -> None:
        """AES-256 with the file's password; unlock removes it."""
        status, out, _ = self.folder.run(
            "protect", str(self.path), "--password-file", str(self.secret)
        )
        self.assertEqual(status, 0)
        locked = self.folder.root / "doc_protected.pdf"
        with self.assertRaises(pikepdf.PasswordError):
            pikepdf.open(locked)
        with pikepdf.open(locked, password="correct horse") as pdf:
            self.assertEqual(pdf.encryption.stream_method.name, "aesv3")
        status, _, err = self.folder.run("info", str(locked))
        self.assertIn("pdf-tools unlock", err)
        status, out, _ = self.folder.run(
            "unlock", str(locked), "--password-file", str(self.secret)
        )
        self.assertEqual(status, 0)
        with pikepdf.open(
            self.folder.root / "doc_protected_unlocked.pdf"
        ) as pdf:
            self.assertFalse(pdf.is_encrypted)

    def test_owner_restrictions_are_lifted_without_a_password(self) -> None:
        """An owner password alone does not stop opening."""
        restricted = self.folder.pdf("r.pdf", owner="boss")
        status, _, _ = self.folder.run("unlock", str(restricted), "-i")
        self.assertEqual(status, 0)
        with pikepdf.open(restricted) as pdf:
            self.assertFalse(pdf.is_encrypted)

    def test_no_terminal_and_no_file(self) -> None:
        """The password is never guessed or taken from argv."""
        status, _, err = self.folder.run("protect", str(self.path))
        self.assertEqual(status, 1)
        self.assertIn("--password-file", err)
        self.assertFalse((self.folder.root / "doc_protected.pdf").exists())

    def test_the_password_can_come_through_a_pipe(self) -> None:
        """A FIFO, as from <(op read ...), is read like a file."""
        pipe = self.folder.root / "pipe"
        os.mkfifo(pipe)

        def feed() -> None:
            """Write the password into the pipe once it is opened."""
            pipe.write_text("piped secret\n")

        writer = threading.Thread(target=feed)
        writer.start()
        status, _, _ = self.folder.run(
            "protect", str(self.path), "--password-file", str(pipe)
        )
        writer.join()
        self.assertEqual(status, 0)
        locked = self.folder.root / "doc_protected.pdf"
        with pikepdf.open(locked, password="piped secret") as pdf:
            self.assertTrue(pdf.is_encrypted)


class CompressTests(unittest.TestCase):
    """Making files smaller."""

    def setUp(self) -> None:
        """A PDF and a fake Ghostscript that copies its input."""
        self.folder = Folder(self)
        self.path = self.folder.pdf("doc.pdf", 20)
        self.log = self.folder.root / "gs.log"
        script(
            self.folder.root / "bin",
            "gs",
            f'echo "$@" > "{self.log}"\n'
            "for a; do\n"
            '  case "$a" in -sOutputFile=*) out="${a#*=}";; esac\n'
            "done\n"
            'eval "last=\\${$#}"\ncp "$last" "$out"\n',
        )

    def test_lossless_shrinks_and_keeps_pages(self) -> None:
        """Object streams and recompression, nothing lost."""
        status, out, _ = self.folder.run("compress", str(self.path))
        self.assertEqual(status, 0)
        result = self.folder.root / "doc_compressed.pdf"
        self.assertLess(result.stat().st_size, self.path.stat().st_size)
        self.assertIn("→", out)
        self.assertEqual(len(self.folder.texts(result)), 20)

    def test_lossy_runs_ghostscript_safely(self) -> None:
        """SAFER, the preset, an absolute input; lossless wins a tie."""
        status, out, _ = self.folder.run(
            "compress", str(self.path), "--quality", "medium"
        )
        self.assertEqual(status, 0)
        arguments = self.log.read_text()
        self.assertIn("-dSAFER", arguments)
        self.assertIn("-dPDFSETTINGS=/ebook", arguments)
        self.assertTrue(arguments.strip().endswith(str(self.path)))
        self.assertIn("lossless was smaller than resampling", out)

    def test_lossy_refuses_an_owner_password(self) -> None:
        """Ghostscript would drop it silently."""
        restricted = self.folder.pdf("r.pdf", owner="boss")
        status, _, err = self.folder.run(
            "compress", str(restricted), "-q", "low"
        )
        self.assertEqual(status, 1)
        self.assertIn("owner password", err)

    def test_missing_ghostscript_is_named(self) -> None:
        """The error says what to install."""
        status, _, err = self.folder.run(
            "compress", str(self.path), "-q", "low", env={"PATH": ""}
        )
        self.assertEqual(status, 1)
        self.assertIn("gs is not installed", err)


class DjvuTests(unittest.TestCase):
    """Converting DjVu documents."""

    def test_conversion_through_ddjvu(self) -> None:
        """ddjvu writes the temporary file that becomes the PDF."""
        folder = Folder(self)
        sample = folder.pdf("sample.pdf", 2)
        script(
            folder.root / "bin",
            "ddjvu",
            f'[ "$1" = -format=pdf ] || exit 9\ncp "{sample}" "$3"\n',
        )
        book = folder.root / "book.djvu"
        book.write_bytes(b"AT&TFORM\x00\x00\x00\x10DJVM")
        status, out, _ = folder.run("from-djvu", str(book))
        self.assertEqual(status, 0)
        self.assertIn("book.pdf · 2 pages", out)
        result = folder.root / "book.pdf"
        self.assertEqual(
            stat.S_IMODE(result.stat().st_mode) & 0o077 != 0, True
        )
        status, _, err = folder.run("from-djvu", str(sample))
        self.assertEqual(status, 1)
        self.assertIn("is not a DjVu document", err)


class InfoTests(unittest.TestCase):
    """Describing documents."""

    def test_facts_and_restrictions(self) -> None:
        """Pages, size name, protection and bookmarks."""
        folder = Folder(self)
        restricted = folder.pdf("r.pdf", 2, owner="boss", bookmarks=True)
        status, out, _ = folder.run("info", str(restricted))
        self.assertEqual(status, 0)
        self.assertIn("Letter", out)
        self.assertIn("owner forbids copying", out)
        self.assertIn("Bookmarks    3", out)


if __name__ == "__main__":
    unittest.main()
