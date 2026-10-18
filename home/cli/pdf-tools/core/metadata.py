"""Document metadata: shown, and stripped for good.

A PDF carries metadata in its document information dictionary, in XMP
packets (one for the document, others on images and pages) and in
application data (``/PieceInfo``). Stripping removes all of them and
rewrites the whole file: an editor that only appends an update leaves the
old values readable in the file, which a rewrite does not. The file
identifier is rebuilt from the content, so it no longer ties the copy to
the original.
"""

from dataclasses import dataclass

import pikepdf

PREFIXES = {
    "http://purl.org/dc/elements/1.1/": "dc",
    "http://ns.adobe.com/xap/1.0/": "xmp",
    "http://ns.adobe.com/pdf/1.3/": "pdf",
    "http://ns.adobe.com/xap/1.0/mm/": "xmpMM",
    "http://ns.adobe.com/photoshop/1.0/": "photoshop",
    "http://ns.adobe.com/xap/1.0/rights/": "xmpRights",
    "http://www.aiim.org/pdfa/ns/id/": "pdfaid",
}
"""Short prefixes for the XMP namespaces PDFs commonly use."""

_HIDDEN = ("/Metadata", "/PieceInfo")


@dataclass
class Entry:
    """One metadata field and where it lives."""

    source: str
    key: str
    value: str


@dataclass
class Stripped:
    """What stripping removed."""

    fields: int = 0
    packets: int = 0
    application: int = 0

    @property
    def total(self) -> int:
        """Everything removed."""
        return self.fields + self.packets + self.application


def entries(pdf: pikepdf.Pdf) -> list[Entry]:
    """The document information and the document's XMP fields."""
    found = []
    if "/Info" in pdf.trailer:
        for key, value in pdf.docinfo.items():
            found.append(Entry("Info", str(key).removeprefix("/"), str(value)))
    if "/Metadata" in pdf.Root:
        for key, value in pdf.open_metadata().items():
            found.append(Entry("XMP", _qualified(key), _text(value)))
    return found


def hidden(pdf: pikepdf.Pdf) -> int:
    """XMP packets and application data beyond the document's own."""
    count = 0
    for item in pdf.objects:
        if not isinstance(item, pikepdf.Dictionary | pikepdf.Stream):
            continue
        count += sum(key in item for key in _HIDDEN)
    return count - ("/Metadata" in pdf.Root)


def _qualified(key: str) -> str:
    """``{namespace}name`` written as ``prefix:name``."""
    if not key.startswith("{"):
        return key
    namespace, _, name = key[1:].partition("}")
    return f"{PREFIXES.get(namespace, namespace)}:{name}"


def _text(value: object) -> str:
    """An XMP value as one line."""
    if isinstance(value, list | set | tuple):
        return "; ".join(str(item) for item in value)
    return str(value)


def strip(pdf: pikepdf.Pdf) -> Stripped:
    """Remove every metadata field, packet and application record."""
    result = Stripped()
    if "/Info" in pdf.trailer:
        result.fields = len(pdf.docinfo)
        del pdf.trailer["/Info"]
    for item in pdf.objects:
        if not isinstance(item, pikepdf.Dictionary | pikepdf.Stream):
            continue
        if "/Metadata" in item:
            del item["/Metadata"]
            result.packets += 1
        if "/PieceInfo" in item:
            del item["/PieceInfo"]
            result.application += 1
    return result
