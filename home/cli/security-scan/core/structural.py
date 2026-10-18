"""The structural layer: what a file is, against what it claims to be.

It reads a file the way a careful person would before opening it: does the
content match the extension, or is it a program under a document's name?
Does a program hide inside it? Does a PDF start something when opened, or
carry attachments? Does a document archive bundle scripts or programs?
Every check reads; none writes.
"""

import re
import zipfile
from collections.abc import Iterator, Sequence
from pathlib import Path, PurePosixPath
from typing import BinaryIO

import pikepdf

from .files import open_regular
from .findings import Finding, Severity

PREFIX = 8 * 1024 * 1024
"""How much of each file the signature and embedding checks read."""

_ZIP = (b"PK\x03\x04", b"PK\x05\x06")
_OLE = (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1",)
_SIGNATURES: dict[str, tuple[bytes, ...]] = {
    "epub": _ZIP,
    "cbz": _ZIP,
    "zip": _ZIP,
    "docx": _ZIP,
    "docm": _ZIP,
    "xlsx": _ZIP,
    "xlsm": _ZIP,
    "pptx": _ZIP,
    "pptm": _ZIP,
    "odt": _ZIP,
    "ods": _ZIP,
    "odp": _ZIP,
    "doc": _OLE,
    "xls": _OLE,
    "ppt": _OLE,
    "rtf": (b"{\\rtf",),
    "djvu": (b"AT&TFORM",),
    "png": (b"\x89PNG\r\n\x1a\n",),
    "jpg": (b"\xff\xd8\xff",),
    "jpeg": (b"\xff\xd8\xff",),
    "gif": (b"GIF87a", b"GIF89a"),
}
"""The first bytes each document or image type starts with."""

_PROGRAMS = (
    (b"MZ", "a Windows program"),
    (b"\x7fELF", "a Linux program"),
    (b"\xcf\xfa\xed\xfe", "a macOS program"),
    (b"\xce\xfa\xed\xfe", "a macOS program"),
    (b"\xca\xfe\xba\xbe", "a macOS or Java program"),
    (b"#!", "a script"),
)
"""The first bytes of programs, and what each is."""

_PE = re.compile(rb"MZ.{60,200}?This program cannot be run in DOS mode", re.S)
_ELF = re.compile(rb"\x7fELF[\x01\x02][\x01\x02]\x01")
"""A Windows program's header and DOS stub; an ELF header, strictly.

A bare ``MZ`` or ``\\x7fELF`` turns up by chance in compressed data, so
each pattern asks for the structure around it too.
"""

_IDENTITIES = (
    (_ZIP, "a ZIP archive"),
    (_OLE, "an Office 97-2003 document"),
    ((b"{\\rtf",), "an RTF document"),
    ((b"\x89PNG",), "a PNG image"),
    ((b"\xff\xd8\xff",), "a JPEG image"),
    ((b"GIF8",), "a GIF image"),
    ((b"RIFF",), "a WebP image or another RIFF file"),
    ((b"<?xml", b"<!DOCTYPE", b"<html"), "an XML or HTML file"),
)
"""What a misnamed file really is, by its first bytes."""

_DOCUMENT_ARCHIVES = frozenset(
    {"epub", "cbz", "docx", "docm", "xlsx", "xlsm", "pptx", "pptm"}
    | {"odt", "ods", "odp"}
)
_DOCUMENTS = frozenset(_SIGNATURES) - {"zip"} | {"pdf"}
"""Extensions that promise a document or an image, never software."""

SOFTWARE = frozenset(
    {"iso", "img", "dmg", "vmdk", "vdi", "vhd", "vhdx", "qcow2"}
    | {"apk", "aab", "xapk", "ipa", "appimage", "snap", "flatpak"}
    | {"deb", "rpm", "pkg", "msi", "msix", "appx", "cab", "exe", "app"}
    | {"jar", "war", "whl", "egg", "gem", "nupkg", "crx", "xpi"}
    | {"tar", "tgz", "gz", "bz2", "xz", "zst", "7z", "rar", "zip"}
)
"""Software packages, disk images and archives, which carry programs."""

_OPENABLE = frozenset(
    {".pdf", ".djvu", ".ps", ".epub", ".txt", ".htm", ".html"}
    | {".png", ".jpg", ".jpeg", ".gif"}
)
"""Launch targets that open in a viewer rather than run."""
_RUNNABLE = frozenset(
    {".exe", ".dll", ".scr", ".com", ".pif", ".cpl", ".msi", ".lnk"}
    | {".bat", ".cmd", ".ps1", ".vbs", ".vbe", ".jse", ".wsf", ".hta"}
    | {".so", ".dylib", ".app", ".command", ".sh", ".jar"}
)
"""Entries that run when opened, which no document needs to carry."""

_LISTED = 5
"""How many entry names a message lists before counting the rest."""


def check(path: Path) -> list[Finding]:
    """Every structural finding about one file.

    The deeper checks follow the content, not the name: a ZIP archive named
    as a PDF is still checked as an archive, and as strictly as the
    document it pretends to be.

    Raises:
        OSError: If the file cannot be read.
    """
    with open_regular(path) as handle:
        head = handle.read(PREFIX)
        kind = path.suffix.lower().removeprefix(".")
        findings: list[Finding] = []
        signature = check_signature(kind, head)
        if signature is not None:
            findings.append(signature)
        embedded = check_embedded(kind, head)
        if embedded is not None:
            findings.append(embedded)
        archive = kind in _DOCUMENT_ARCHIVES | {"zip"} or signature is not None
        if _is_pdf(head):
            handle.seek(0)
            findings += check_pdf(handle)
        elif head.startswith(_ZIP) and archive:
            handle.seek(0)
            findings += check_archive(handle, kind)
    return findings


# Signatures -------------------------------------------------------------------


def check_signature(kind: str, head: bytes) -> Finding | None:
    """A finding when the content contradicts the extension.

    A program under a document's name is the classic disguise and is
    critical; any other mismatch is a warning. An empty file, or an
    extension this check does not know, is left alone.
    """
    expected = (b"%PDF-",) if kind == "pdf" else _SIGNATURES.get(kind)
    if expected is None or not head:
        return None
    if _is_pdf(head) if kind == "pdf" else head.startswith(expected):
        return None
    for magic, what in _PROGRAMS:
        if head.startswith(magic):
            return Finding(
                "signature",
                Severity.CRITICAL,
                f"Is {what} named as a .{kind} file",
                {"header": head[:16].hex()},
            )
    if head[257:262] == b"ustar":
        return Finding(
            "signature",
            Severity.WARNING,
            f"Is a tar archive named as a .{kind} file; the real file is "
            "probably inside",
            {"header": head[:16].hex()},
        )
    what = "a PDF" if _is_pdf(head) else None
    for magics, identity in _IDENTITIES:
        if what is None and head.startswith(magics):
            what = identity
    return Finding(
        "signature",
        Severity.WARNING,
        f"Is {what} named as a .{kind} file"
        if what
        else f"Content does not match the .{kind} extension",
        {"header": head[:16].hex()},
    )


def _is_pdf(head: bytes) -> bool:
    """Whether the content is a PDF: readers accept junk before the marker."""
    return b"%PDF-" in head[:1024]


# Embedded programs ------------------------------------------------------------


def check_embedded(kind: str, head: bytes) -> Finding | None:
    """A finding when a program hides inside a file that is not one.

    A program that carries others, such as an installer or a
    self-extracting script, is left alone, and so is a software package
    or a disk image, whose job is to carry programs.
    """
    if kind in SOFTWARE:
        return None
    if any(head.startswith(magic) for magic, _ in _PROGRAMS):
        return None
    if _PE.search(head):
        return Finding(
            "embedded", Severity.CRITICAL, "Carries a Windows program inside"
        )
    if _ELF.search(head):
        return Finding(
            "embedded", Severity.CRITICAL, "Carries a Linux program inside"
        )
    return None


# PDF --------------------------------------------------------------------------


def check_pdf(handle: BinaryIO) -> list[Finding]:
    """What a PDF can do when opened, and what it carries.

    Every object is visited, with the dictionaries nested directly inside
    it: an action written inline in a link, rather than as an object of its
    own, still counts.
    """
    try:
        with pikepdf.open(handle) as pdf:
            return _pdf_findings(pdf)
    except pikepdf.PasswordError:
        return [
            Finding(
                "pdf",
                Severity.WARNING,
                "Is locked with a password, so its contents were not checked",
            )
        ]
    except pikepdf.PdfError as error:
        return [
            Finding(
                "pdf",
                Severity.WARNING,
                f"Cannot be read as a PDF: {_first_line(error)}",
            )
        ]


def _pdf_findings(pdf: pikepdf.Pdf) -> list[Finding]:
    """The findings of an open PDF."""
    scripts = automatic = embedded = 0
    programs: list[str] = []
    documents: list[str] = []
    for item in pdf.objects:
        for dictionary in _dictionaries(item):
            if dictionary.get("/S") == pikepdf.Name.Launch:
                target, document = _launch_target(dictionary)
                (documents if document else programs).append(target)
            if _is_script(dictionary):
                scripts += 1
            if dictionary.get("/Type") == pikepdf.Name.EmbeddedFile:
                embedded += 1
            if "/AA" in dictionary:
                automatic += _scripted_events(dictionary["/AA"])
    root = pdf.Root
    opening = root.get("/OpenAction")
    if isinstance(opening, pikepdf.Dictionary) and _is_script(opening):
        automatic += 1
    names = root.get("/Names")
    if isinstance(names, pikepdf.Dictionary) and "/JavaScript" in names:
        automatic += 1
    files = list(pdf.attachments)
    attachments = max(embedded, len(files))

    findings: list[Finding] = []
    if programs:
        named = _unique(programs)
        findings.append(
            Finding(
                "pdf",
                Severity.CRITICAL,
                "Can start another program (a Launch action)"
                + (f": {_listed(named)}" if named else ""),
                {"launch": named[:100]},
            )
        )
    elif documents:
        named = _unique(documents)
        findings.append(
            Finding(
                "pdf",
                Severity.WARNING,
                "Can open other files through Launch actions: "
                + _listed(named),
                {"launch": named[:100]},
            )
        )
    if automatic:
        findings.append(
            Finding(
                "pdf",
                Severity.WARNING,
                "Runs JavaScript by itself, when opened or on a page event",
                {"scripts": scripts},
            )
        )
    elif scripts:
        findings.append(
            Finding(
                "pdf",
                Severity.INFO,
                "Contains JavaScript, as forms and links often do",
                {"scripts": scripts},
            )
        )
    if attachments:
        findings.append(
            Finding(
                "pdf",
                Severity.WARNING,
                f"Carries {_count(attachments, 'attached file')}"
                + (f": {_listed(files)}" if files else ""),
                {"attachments": files[:100]},
            )
        )
    return findings


def _dictionaries(
    item: object, depth: int = 0
) -> Iterator[pikepdf.Dictionary]:
    """The dictionaries of an object and those nested directly inside it.

    Indirect objects are left for their own visit; the depth bound keeps a
    crafted file from exhausting the stack.
    """
    if depth > 32:
        return
    if isinstance(item, pikepdf.Stream):
        item = item.stream_dict
    if isinstance(item, pikepdf.Dictionary):
        yield item
        children = item.values()
    elif isinstance(item, pikepdf.Array):
        children = list(item)
    else:
        return
    for child in children:
        if isinstance(child, pikepdf.Dictionary | pikepdf.Array) and (
            not child.is_indirect
        ):
            yield from _dictionaries(child, depth + 1)


def _launch_target(action: pikepdf.Dictionary) -> tuple[str, bool]:
    """What a Launch action opens, and whether that is only a document.

    Platform entries (``/Win``, ``/Mac``, ``/Unix``) name a program and its
    arguments, so they never count as a document.
    """
    for platform in ("/Win", "/Mac", "/Unix"):
        parameters = action.get(platform)
        if isinstance(parameters, pikepdf.Dictionary):
            return _file_name(parameters.get("/F")), False
    name = _file_name(action.get("/F"))
    suffix = PurePosixPath(name.replace("\\", "/")).suffix.lower()
    return name, suffix in _OPENABLE


def _file_name(value: object) -> str:
    """The name in a file specification: a string or a dictionary."""
    if isinstance(value, pikepdf.Dictionary):
        value = value.get("/UF") or value.get("/F")
    return str(value) if isinstance(value, pikepdf.String) else ""


def _is_script(action: pikepdf.Dictionary) -> bool:
    """Whether an action dictionary runs JavaScript."""
    return action.get("/S") == pikepdf.Name.JavaScript or "/JS" in action


def _scripted_events(events: object) -> int:
    """How many event actions (an ``/AA`` dictionary) run JavaScript."""
    if not isinstance(events, pikepdf.Dictionary):
        return 0
    return sum(
        1
        for action in events.values()
        if isinstance(action, pikepdf.Dictionary) and _is_script(action)
    )


# Archives ---------------------------------------------------------------------


def check_archive(handle: BinaryIO, kind: str) -> list[Finding]:
    """What a ZIP-based archive bundles.

    Programs and scripts are critical inside a document (an EPUB, an
    Office file) and a warning in a plain ZIP, where software ships. Only
    the archive's directory is read: nothing is extracted, so a ZIP bomb
    costs nothing.
    """
    try:
        with zipfile.ZipFile(handle) as archive:
            names = archive.namelist()
    except (zipfile.BadZipFile, ValueError) as error:
        return [
            Finding(
                "archive",
                Severity.WARNING,
                f"Cannot be read as a ZIP archive: {_first_line(error)}",
            )
        ]
    findings: list[Finding] = []
    runnable = _unique([_runnable(name) for name in names])
    if runnable:
        document = kind in _DOCUMENTS
        what = _count(
            len(runnable), "program or script", "programs or scripts"
        )
        findings.append(
            Finding(
                "archive",
                Severity.CRITICAL if document else Severity.WARNING,
                f"Bundles {what}"
                + (" that no document needs" if document else "")
                + f": {_listed(runnable)}",
                {"entries": runnable[:100]},
            )
        )
    escaping = [name for name in names if _escapes(name)]
    if escaping:
        findings.append(
            Finding(
                "archive",
                Severity.WARNING,
                f"Holds {_count(len(escaping), 'path')} that would land "
                f"outside the folder it is extracted to: {_listed(escaping)}",
                {"entries": escaping[:100]},
            )
        )
    macros = [n for n in names if n.lower().endswith("vbaproject.bin")]
    if macros and kind not in ("zip", "epub", "cbz"):
        findings.append(
            Finding(
                "archive",
                Severity.WARNING,
                "Contains VBA macros, which can run when the document opens",
                {"entries": macros[:100]},
            )
        )
    return findings


def _runnable(name: str) -> str:
    """The part of an entry's path that runs when opened, or nothing.

    Every file inside an app bundle is part of one program, so the bundle
    is named once rather than each of its files.
    """
    parts = PurePosixPath(name.replace("\\", "/")).parts
    for index, part in enumerate(parts):
        if PurePosixPath(part).suffix.lower() in _RUNNABLE:
            return "/".join(parts[: index + 1])
    return ""


def _escapes(name: str) -> bool:
    """Whether an entry's path climbs out of, or ignores, the target."""
    path = name.replace("\\", "/")
    return (
        path.startswith("/")
        or re.match(r"[A-Za-z]:", path) is not None
        or ".." in path.split("/")
    )


# Wording ----------------------------------------------------------------------


def _count(number: int, noun: str, plural: str = "") -> str:
    """``1 noun`` or ``n nouns``."""
    return f"{number} {noun if number == 1 else plural or noun + 's'}"


def _listed(names: Sequence[str]) -> str:
    """The first few names, then how many more."""
    shown = ", ".join(names[:_LISTED])
    rest = len(names) - _LISTED
    return f"{shown} (and {rest} more)" if rest > 0 else shown


def _unique(names: Sequence[str]) -> list[str]:
    """The non-empty names, each once, in order."""
    return list(dict.fromkeys(name for name in names if name))


def _first_line(error: Exception) -> str:
    """An exception's message, first line only, as a sentence."""
    text = str(error).strip().splitlines()[0] if str(error).strip() else ""
    return text or type(error).__name__
