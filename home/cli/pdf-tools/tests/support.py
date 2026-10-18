"""Shared fixtures: a temporary folder, sample PDFs and fake programs."""

import contextlib
import io
import os
import shutil
import tempfile
import unittest
from pathlib import Path

import pikepdf
import terminal_style as ui
from pikepdf import Array, Dictionary, Name, String

from core import cli

_TOOLS = os.pathsep.join(
    sorted(
        {
            os.path.dirname(found)
            for found in map(shutil.which, ("cp", "cat"))
            if found
        }
    )
)

WATERMARK = (
    b"q /GS0 gs 0.6 g BT /F1 48 Tf 0.7071 0.7071 -0.7071 0.7071 150 200 Tm "
    b"(CONFIDENTIAL) Tj ET Q"
)
"""A rotated, see-through stamp drawn by its own stream."""


def body(number: int) -> bytes:
    """A page's own content: a line of text and a rule."""
    return (
        f"BT /F1 12 Tf 72 720 Td (Body of page {number}) Tj ET "
        "0 0 0 RG 72 700 m 540 700 l S"
    ).encode()


def script(directory: Path, name: str, body_: str) -> Path:
    """An executable shell script that finds the basic tools on any PATH."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(f'#!/bin/sh\nPATH="${{PATH:+$PATH:}}{_TOOLS}"\n{body_}')
    path.chmod(0o755)
    return path


class Folder:
    """A temporary folder with builders for sample documents."""

    def __init__(self, test: unittest.TestCase) -> None:
        """Create the folder for a test."""
        handle = tempfile.TemporaryDirectory(prefix="pdf-tools-test.")
        test.addCleanup(handle.cleanup)
        self.root = Path(handle.name).resolve()
        self.test = test

    def pdf(
        self,
        name: str,
        pages: int = 3,
        *,
        stamp: bytes | None = None,
        bookmarks: bool = False,
        info: dict[str, str] | None = None,
        password: str = "",
        owner: str = "",
    ) -> Path:
        """Write a PDF of numbered text pages.

        ``stamp`` adds a second content stream to every page; ``bookmarks``
        adds a chapter per page with a section under the first; ``info``
        fills the document information; ``password`` locks the file and
        ``owner`` restricts it.
        """
        pdf = pikepdf.new()
        font = Dictionary(
            Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica
        )
        state = Dictionary(Type=Name.ExtGState, ca=0.3, CA=0.3)
        for number in range(1, pages + 1):
            pdf.add_blank_page(page_size=(612, 792))
            page = pdf.pages[-1]
            page.Resources = Dictionary(
                Font=Dictionary(F1=font), ExtGState=Dictionary(GS0=state)
            )
            streams = [pdf.make_stream(body(number))]
            if stamp is not None:
                streams.append(pdf.make_stream(stamp))
            page.Contents = Array(streams)
        if bookmarks:
            with pdf.open_outline() as outline:
                for number in range(pages):
                    item = pikepdf.OutlineItem(f"Chapter {number + 1}", number)
                    if number == 0:
                        item.children.append(
                            pikepdf.OutlineItem(
                                "Section 1.1", 0, "XYZ", top=500
                            )
                        )
                    outline.root.append(item)
        for key, value in (info or {}).items():
            pdf.docinfo[Name(f"/{key}")] = String(value)
        path = self.root / name
        encryption: pikepdf.Encryption | bool = False
        if password or owner:
            encryption = pikepdf.Encryption(
                owner=owner or password,
                user=password,
                allow=pikepdf.Permissions(extract=not owner),
            )
        pdf.save(path, encryption=encryption)
        pdf.close()
        return path

    def texts(self, path: Path, password: str = "") -> list[str]:
        """Each page's content streams, decoded, joined."""
        with pikepdf.open(path, password=password) as pdf:
            return [
                pikepdf.unparse_content_stream(
                    pikepdf.parse_content_stream(page)
                ).decode("latin-1")
                for page in pdf.pages
            ]

    def run(
        self, *argv: str, env: dict[str, str] | None = None
    ) -> tuple[int, str, str]:
        """Run pdf-tools: its status, standard output and error."""
        out, err = io.StringIO(), io.StringIO()
        environ = {"PATH": str(self.root / "bin"), "HOME": str(self.root)}
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                status = cli.main(
                    list(argv), environ | (env or {}), ui.Style(False)
                )
            except SystemExit as error:
                status = int(error.code or 0)
        return status, out.getvalue(), err.getvalue()
