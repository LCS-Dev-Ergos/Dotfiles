"""Shared fixtures: a temporary folder, sample documents and a fake ClamAV."""

import os
import shutil
import tempfile
import unittest
import zipfile
from pathlib import Path

import pikepdf
from pikepdf import Array, Dictionary, Name, String

_TOOLS = os.pathsep.join(
    sorted(
        {
            os.path.dirname(found)
            for found in map(shutil.which, ("mkdir", "sleep"))
            if found
        }
    )
)

PE = (
    b"MZ\x90\x00"
    + b"\x00" * 60
    + b"\x0e\x1f\xba\x0e\x00\xb4\x09\xcd\x21\xb8\x01\x4c\xcd\x21"
    + b"This program cannot be run in DOS mode.\r\r\n$"
)
"""The start of a Windows program: DOS header, stub code and message."""

ELF = b"\x7fELF\x02\x01\x01\x00" + b"\x00" * 8
"""The start of a 64-bit little-endian ELF program."""

EICAR = (
    rb"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
)
"""The antivirus test string, harmless by design."""

CLAMSCAN = """\
[ -z "${CLAM_ARGS:-}" ] || echo "$*" >> "$CLAM_ARGS"
for argument; do
  case "$argument" in
    --version) echo "$CLAM_VERSION"; exit "${CLAM_STATUS:-0}";;
    --file-list=*) list="${argument#--file-list=}";;
  esac
done
case "${CLAM_MODE:-}" in
  fail) echo "LibClamAV Error: No supported database files found" >&2; exit 2;;
  hang) (sleep 1; mkdir "$CLAM_MARK") & sleep 5; exit 0;;
esac
status=0
while IFS= read -r file; do
  case "$file" in
    *infected*) echo "$file: Win.Test.Sig FOUND"; status=1;;
    *eicar*) echo "$file: Eicar-Test-Signature FOUND"; status=1;;
    *heuristic*) echo "$file: Heuristics.Broken.Executable FOUND"; status=1;;
    *huge*)
      echo "$file: Heuristics.Limits.Exceeded.MaxFileSize FOUND"
      echo "$file: Virus(es) detected ERROR"
      status=1;;
    *denied*) echo "$file: Access denied"; status=2;;
    *ignored*) ;;
    *empty*) echo "$file: Empty file";;
    *) echo "$file: OK";;
  esac
done < "$list"
exit "$status"
"""
"""A clamscan that answers by file name, as the real one formats it."""

DATABASE = "ClamAV 1.5.4/27412/Sat Oct 18 08:12:00 2026"
"""What clamscan --version prints with a database."""


def script(directory: Path, name: str, body: str) -> Path:
    """An executable shell script that finds the basic tools on any PATH.

    The tools' directories come from the test's own PATH, since a build
    sandbox has no /usr/bin.
    """
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(f'#!/bin/sh\nPATH="${{PATH:+$PATH:}}{_TOOLS}"\n{body}')
    path.chmod(0o755)
    return path


class Folder:
    """A temporary folder, removed when the test ends."""

    def __init__(self, test: unittest.TestCase) -> None:
        """Create the folder for a test."""
        handle = tempfile.TemporaryDirectory(prefix="security-scan-test.")
        test.addCleanup(handle.cleanup)
        self.root = Path(handle.name).resolve()

    def file(self, name: str, content: bytes = b"") -> Path:
        """Write a file, and the folders on its way."""
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def zip(self, name: str, entries: dict[str, bytes]) -> Path:
        """Write a ZIP archive with the given entries."""
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w") as archive:
            for entry, content in entries.items():
                archive.writestr(entry, content)
        return path

    def pdf(self, name: str, **features: bool) -> Path:
        """Write a one-page PDF with the features asked for.

        ``launch`` puts a Launch action for a program inline in a link,
        ``crossref`` one that opens another PDF; ``opening`` runs
        JavaScript on open, ``event`` on a page event, ``link`` behind a
        link, ``document`` from the document's name tree; ``attachment``
        attaches a file and ``password`` locks the whole file.
        """
        pdf = pikepdf.new()
        pdf.add_blank_page()
        page = pdf.pages[0]
        javascript = Dictionary(S=Name.JavaScript, JS=String("app.alert(1)"))
        annotations = []
        for feature, target in (("launch", "calc.exe"), ("crossref", "a.pdf")):
            if features.get(feature):
                action = Dictionary(S=Name.Launch, F=String(target))
                annotations.append(_link(action))
        if features.get("link"):
            annotations.append(_link(javascript))
        if annotations:
            page.Annots = pdf.make_indirect(
                Array([pdf.make_indirect(item) for item in annotations])
            )
        if features.get("opening"):
            pdf.Root.OpenAction = pdf.make_indirect(javascript)
        if features.get("event"):
            page.AA = Dictionary(O=javascript)
        if features.get("document"):
            tree = Dictionary(Names=Array([String("a"), javascript]))
            pdf.Root.Names = Dictionary(JavaScript=tree)
        if features.get("attachment"):
            pdf.attachments["note.txt"] = pikepdf.AttachedFileSpec(
                pdf, b"hello", mime_type="text/plain"
            )
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        encryption = pikepdf.Encryption(owner="o", user="u")
        pdf.save(
            path, encryption=encryption if features.get("password") else False
        )
        return path

    def clamscan(self, version: str = DATABASE) -> dict[str, str]:
        """Install the fake clamscan; the environment that finds it."""
        bin_dir = self.root / "bin"
        script(bin_dir, "clamscan", CLAMSCAN)
        return {
            "PATH": str(bin_dir),
            "HOME": str(self.root / "home"),
            "CLAM_VERSION": version,
        }


def _link(action: Dictionary) -> Dictionary:
    """A link annotation that runs an action, written inline."""
    return Dictionary(
        Type=Name.Annot, Subtype=Name.Link, Rect=[0, 0, 10, 10], A=action
    )
