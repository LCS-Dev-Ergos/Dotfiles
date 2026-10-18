"""The external programs: Ghostscript for lossy compression, ddjvu for DjVu.

Both come from the caller's PATH. They run with literal arguments and
absolute paths, so a file name starting with a dash cannot pass for an
option, and write only to the temporary file they are given. Ghostscript
runs with ``-dSAFER``, which keeps a document's PostScript from reaching
the file system.
"""

import os
import shutil
import subprocess
from collections.abc import Mapping
from pathlib import Path

from .documents import ToolError

QUALITY = {"high": "printer", "medium": "ebook", "low": "screen"}
"""Lossy compression levels and Ghostscript's matching presets."""


def program(name: str, purpose: str, environ: Mapping[str, str]) -> str:
    """The path of a program on PATH.

    Raises:
        ToolError: If it is not installed.
    """
    found = shutil.which(name, path=environ.get("PATH", ""))
    if found is None:
        raise ToolError(f"{name} is not installed; {purpose} needs it")
    return found


def run(command: list[str], environ: Mapping[str, str]) -> None:
    """Run a program to completion.

    Raises:
        ToolError: If it cannot start or fails; its last error line says why.
    """
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            errors="replace",
            env=dict(environ),
            check=False,
        )
    except OSError as error:
        raise ToolError(
            f"Cannot run {command[0]}: {error.strerror}"
        ) from error
    if result.returncode != 0:
        lines = (result.stderr or result.stdout).strip().splitlines()
        detail = lines[-1] if lines else f"status {result.returncode}"
        name = Path(command[0]).name
        raise ToolError(f"{name} failed: {detail}")


def ghostscript(
    source: Path, output: Path, quality: str, environ: Mapping[str, str]
) -> None:
    """Rewrite a PDF through Ghostscript at a quality preset.

    A ``%`` in the output name is doubled, since Ghostscript would read it
    as a page-number format.

    Raises:
        ToolError: If Ghostscript is missing or fails.
    """
    gs = program("gs", "lossy compression", environ)
    run(
        [
            gs,
            "-q",
            "-dSAFER",
            "-dBATCH",
            "-dNOPAUSE",
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.7",
            f"-dPDFSETTINGS=/{QUALITY[quality]}",
            "-dDetectDuplicateImages=true",
            f"-sOutputFile={str(output.absolute()).replace('%', '%%')}",
            os.path.abspath(source),
        ],
        environ,
    )


def is_djvu(path: Path) -> bool:
    """Whether a file is a DjVu document, by its first bytes."""
    try:
        with path.open("rb") as handle:
            return handle.read(8) == b"AT&TFORM"
    except OSError:
        return False


def djvu(source: Path, output: Path, environ: Mapping[str, str]) -> None:
    """Convert a DjVu document to PDF with ddjvu.

    Raises:
        ToolError: If ddjvu is missing or fails.
    """
    ddjvu = program("ddjvu", "converting DjVu", environ)
    run(
        [
            ddjvu,
            "-format=pdf",
            os.path.abspath(source),
            str(output.absolute()),
        ],
        environ,
    )
