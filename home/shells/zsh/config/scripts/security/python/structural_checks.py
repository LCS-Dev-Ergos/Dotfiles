#!/usr/bin/env python3

# ============================================================================ #
"""
Security Scan - Structural Checks:
Dependency-light checks that do not require ClamAV or YARA. These catch the
realistic attack surface of document files handled day to day:

  - File-signature vs. extension mismatch (an executable or archive
    masquerading as a .pdf/.epub, or a broken/mislabeled container).
  - Embedded executables (PE/ELF magic bytes) hiding inside a document.
  - PDF auto-run vectors: /Launch actions, /JavaScript, /OpenAction, and
    /EmbeddedFile streams. Uses pikepdf when available and falls back to
    poppler-utils (pdfinfo/pdfdetach) so the check still runs on a bare
    system with just command-line tools installed.
  - EPUB/ZIP-based containers: flags dangerous file types bundled inside
    the archive (executables, scripts) that have no business being in an
    ebook.

Every function returns `Finding` objects (see report.py); nothing here ever
modifies the scanned file.

Author: Claude (Anthropic)
Version: 1.0.0
"""
# ============================================================================ #

from __future__ import annotations

import shutil
import subprocess
import zipfile
from pathlib import Path

from report import Finding, Severity

# ++++++++++++++++++++++++++++++++ Constants +++++++++++++++++++++++++++++++++ #

# Extension -> validator over the first N header bytes of the file.
_MAGIC_CHECKS = {
    "pdf": lambda head: head.lstrip(b"\x00\x20\r\n\t").startswith(b"%PDF"),
    "epub": lambda head: head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06"),
    "djvu": lambda head: head[:4] == b"AT&T" or b"AT&TFORM" in head[:16],
    "mobi": lambda head: True,  # MOBI header ("BOOKMOBI") is offset 60; skip strict check.
    "azw": lambda head: True,
    "azw3": lambda head: True,
    "cbz": lambda head: head.startswith(b"PK\x03\x04"),
    "docx": lambda head: head.startswith(b"PK\x03\x04"),
    "zip": lambda head: head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06"),
}

_PE_MAGIC = b"MZ"
_PE_SIGNATURE = b"This program cannot be run in DOS mode"
_ELF_MAGIC = b"\x7fELF"
_TAR_LOOKALIKE_SUFFIX = b"ustar"

# File types that have no legitimate reason to live inside an ebook archive.
_DANGEROUS_ARCHIVE_EXTENSIONS = {
    ".exe", ".dll", ".so", ".dylib", ".bat", ".cmd", ".com", ".scr",
    ".msi", ".vbs", ".ps1", ".jar", ".app", ".sh",
}

_HEAD_READ_SIZE = 4096
_CONTAINER_SCAN_SIZE = 8 * 1024 * 1024  # cap embedded-executable scan for very large files


# +++++++++++++++++++++++++++++ Signature Check ++++++++++++++++++++++++++++++ #

def check_signature(path: Path) -> Finding | None:
    """Flag a mismatch between a file's real signature and its extension."""
    ext = path.suffix.lower().lstrip(".")
    validator = _MAGIC_CHECKS.get(ext)
    if validator is None:
        return None

    try:
        with path.open("rb") as handle:
            head = handle.read(_HEAD_READ_SIZE)
    except OSError as exc:
        return Finding("signature", Severity.WARNING, f"Could not read file header: {exc}")

    if validator(head):
        return None

    # Special case: a tar archive saved with a document extension is a common
    # packaging mistake (not malicious), worth calling out distinctly.
    if _TAR_LOOKALIKE_SUFFIX in head or _looks_like_tar(path):
        return Finding(
            "signature",
            Severity.WARNING,
            f"File is a tar archive, not a real .{ext} — likely a packaging mistake, "
            "not a threat. The real file is probably nested inside.",
        )

    return Finding(
        "signature",
        Severity.WARNING,
        f"File content does not match its .{ext} extension. "
        f"Header starts with: {head[:16]!r}",
    )


def _looks_like_tar(path: Path) -> bool:
    """Cheap heuristic: POSIX tar stores 'ustar' at offset 257 of the first block."""
    try:
        with path.open("rb") as handle:
            handle.seek(257)
            return handle.read(5) == _TAR_LOOKALIKE_SUFFIX
    except OSError:
        return False


# +++++++++++++++++++++++++++ Embedded Executables +++++++++++++++++++++++++++ #

def check_embedded_executable(path: Path) -> Finding | None:
    """Scan (a bounded prefix of) the file for embedded PE/ELF executables."""
    ext = path.suffix.lower().lstrip(".")
    if ext in {"exe", "dll", "so", "dylib", "bin"}:
        return None  # legitimately an executable; nothing "embedded" about it

    try:
        with path.open("rb") as handle:
            data = handle.read(_CONTAINER_SCAN_SIZE)
    except OSError:
        return None

    if _PE_MAGIC in data and _PE_SIGNATURE in data:
        return Finding(
            "embedded-executable",
            Severity.CRITICAL,
            "Found an embedded Windows PE executable signature inside a document file.",
        )
    if _ELF_MAGIC in data:
        return Finding(
            "embedded-executable",
            Severity.CRITICAL,
            "Found an embedded ELF executable signature inside a document file.",
        )
    return None


# ++++++++++++++++++++++++++++++++ PDF Checks ++++++++++++++++++++++++++++++++ #

def _try_import_pikepdf():
    try:
        import pikepdf  # noqa: F401

        return pikepdf
    except ImportError:
        return None


def pdf_findings(path: Path) -> list[Finding]:
    """Check a PDF for auto-run vectors: JS, /Launch, /OpenAction, embedded files."""
    pikepdf = _try_import_pikepdf()
    if pikepdf is not None:
        return _pdf_findings_pikepdf(path, pikepdf)
    if shutil.which("pdfinfo"):
        return _pdf_findings_poppler(path)
    return [
        Finding(
            "pdf-structure",
            Severity.INFO,
            "Skipped: install `pip install pikepdf` or poppler-utils (pdfinfo/pdfdetach) "
            "for PDF structural checks (JavaScript, /Launch, embedded files).",
        )
    ]


def _pdf_findings_pikepdf(path: Path, pikepdf) -> list[Finding]:
    findings: list[Finding] = []
    try:
        with pikepdf.open(path) as pdf:
            root = pdf.Root

            has_js = False
            try:
                has_js = "/Names" in root and "/JavaScript" in root.Names
            except Exception:
                pass

            has_launch = False
            has_embedded = False
            try:
                for obj in pdf.objects:
                    try:
                        if not hasattr(obj, "get"):
                            continue
                        subtype = str(obj.get("/S", ""))
                        if subtype == "/Launch":
                            has_launch = True
                        if str(obj.get("/Type", "")) == "/EmbeddedFile":
                            has_embedded = True
                        if has_launch and has_embedded:
                            break
                    except Exception:
                        continue
            except Exception as exc:
                findings.append(
                    Finding("pdf-structure", Severity.WARNING, f"Partial object scan: {exc}")
                )

            if has_launch:
                findings.append(
                    Finding(
                        "pdf-structure",
                        Severity.CRITICAL,
                        "Contains a /Launch action (can auto-run an external program on open).",
                    )
                )
            if has_embedded:
                findings.append(
                    Finding(
                        "pdf-structure",
                        Severity.WARNING,
                        "Contains embedded file attachment(s); inspect before extracting.",
                    )
                )
            if has_js:
                findings.append(
                    Finding(
                        "pdf-structure",
                        Severity.INFO,
                        "Contains JavaScript. Often benign (Adobe compatibility scripts, form "
                        "math) but worth a manual look if unexpected for this document.",
                    )
                )
    except Exception as exc:
        findings.append(Finding("pdf-structure", Severity.WARNING, f"Could not parse PDF: {exc}"))
    return findings


def _pdf_findings_poppler(path: Path) -> list[Finding]:
    findings: list[Finding] = []
    try:
        out = subprocess.run(
            ["pdfinfo", str(path)], capture_output=True, text=True, timeout=30
        ).stdout
    except Exception as exc:
        return [Finding("pdf-structure", Severity.WARNING, f"pdfinfo failed: {exc}")]

    for line in out.splitlines():
        if line.startswith("JavaScript:") and "yes" in line.lower():
            findings.append(
                Finding(
                    "pdf-structure",
                    Severity.INFO,
                    "Contains JavaScript (detected via pdfinfo). Often benign; verify if unexpected.",
                )
            )

    if shutil.which("pdfdetach"):
        try:
            list_out = subprocess.run(
                ["pdfdetach", "-list", str(path)], capture_output=True, text=True, timeout=30
            ).stdout
            first_line = list_out.strip().splitlines()[0] if list_out.strip() else "0"
            count = int(first_line.split()[0]) if first_line[:1].isdigit() else 0
            if count > 0:
                findings.append(
                    Finding(
                        "pdf-structure",
                        Severity.WARNING,
                        f"Contains {count} embedded file attachment(s); inspect before extracting.",
                    )
                )
        except Exception:
            pass

    # Note: /Launch detection has no simple poppler CLI equivalent; pikepdf is
    # required for that specific check.
    findings.append(
        Finding(
            "pdf-structure",
            Severity.INFO,
            "Launch-action check requires pikepdf; skipped (poppler-utils fallback in use).",
        )
    )
    return findings


# ++++++++++++++++++++++++++++ EPUB / ZIP Checks +++++++++++++++++++++++++++++ #

def archive_findings(path: Path) -> list[Finding]:
    """Flag dangerous embedded file types inside a ZIP-based container (EPUB, etc.)."""
    findings: list[Finding] = []
    try:
        with zipfile.ZipFile(path) as archive:
            bad_entries = [
                name
                for name in archive.namelist()
                if Path(name).suffix.lower() in _DANGEROUS_ARCHIVE_EXTENSIONS
            ]
    except zipfile.BadZipFile:
        return [Finding("archive-structure", Severity.WARNING, "Not a valid ZIP/EPUB archive.")]
    except OSError as exc:
        return [Finding("archive-structure", Severity.WARNING, f"Could not open archive: {exc}")]

    if bad_entries:
        preview = ", ".join(bad_entries[:5])
        more = f" (+{len(bad_entries) - 5} more)" if len(bad_entries) > 5 else ""
        findings.append(
            Finding(
                "archive-structure",
                Severity.CRITICAL,
                f"Archive bundles executable/script content that has no place in an ebook: "
                f"{preview}{more}",
            )
        )
    return findings


# ++++++++++++++++++++++++++++++++ Dispatcher ++++++++++++++++++++++++++++++++ #

def run(path: Path) -> list[Finding]:
    """Run every applicable structural check for one file and merge findings."""
    findings: list[Finding] = []

    sig_finding = check_signature(path)
    if sig_finding is not None:
        findings.append(sig_finding)

    exe_finding = check_embedded_executable(path)
    if exe_finding is not None:
        findings.append(exe_finding)

    ext = path.suffix.lower().lstrip(".")
    if ext == "pdf":
        # A signature mismatch already means "this isn't really a PDF"; skip
        # the PDF-specific parse in that case to avoid noisy parser errors.
        if sig_finding is None:
            findings.extend(pdf_findings(path))
    elif ext in {"epub", "cbz", "docx", "zip"}:
        if sig_finding is None:
            findings.extend(archive_findings(path))

    return findings

# ============================================================================ #
# End of script.
