# PDF Tools

`pdf-tools` inspects and edits PDF documents from the command line: pages,
compression, passwords, metadata, bookmarks, watermarks and DjVu
conversion. Home Manager installs it on macOS and Linux. The PDF work is
done in-process by pikepdf (libqpdf); Ghostscript (`gs`) and `ddjvu` are
used from PATH for the two tasks that need them.

```sh
pdf-tools info book.pdf                          # pages, size, protection, problems
pdf-tools extract book.pdf 5-10,12 -o part.pdf   # keep pages, in this order
pdf-tools delete book.pdf 1,z --in-place         # drop the first and last page
pdf-tools rotate scan.pdf right 1-3 -i           # turn pages 1-3 clockwise
pdf-tools merge a.pdf b.pdf -o both.pdf          # join, a bookmark per file
pdf-tools split book.pdf --at 10,20              # parts starting at pages 10, 20
pdf-tools compress book.pdf --quality medium     # resample images (Ghostscript)
pdf-tools protect report.pdf                     # AES-256, asks for the password
pdf-tools unlock report.pdf -i                   # remove password or restrictions
pdf-tools metadata show book.pdf                 # Info and XMP fields
pdf-tools metadata strip *.pdf --in-place        # remove all metadata for good
pdf-tools bookmarks copy original.pdf scan.pdf   # bookmarks onto another file
pdf-tools watermarks book.pdf --dry-run          # report overlay candidates
pdf-tools from-djvu book.djvu                    # DjVu to PDF
```

## Commands

| Command | What it does |
| --- | --- |
| `info FILE...` | Pages, page size, PDF version, file size, protection, title and author, bookmarks, attachments, forms, linearization, and the problems qpdf finds |
| `extract FILE PAGES` | A new PDF of the chosen pages, in the order given |
| `delete FILE PAGES` | The PDF without the chosen pages |
| `rotate FILE ANGLE [PAGES]` | Turns pages by `right`, `left` or `180`, on top of their current rotation |
| `merge FILE... -o FILE` | Joins PDFs; each file becomes a bookmark holding its own (`--no-bookmarks` skips them) |
| `split FILE` | One PDF per page, per `--every N` pages, or starting `--at` given pages, into `FILE_parts/` |
| `compress FILE` | `--quality lossless` (default) recompresses streams and packs objects; `high`, `medium` and `low` resample images with Ghostscript and keep whichever result is smaller; `--linearize` orders the file for the web |
| `protect FILE` | Locks the file with AES-256; the password opens and edits it |
| `unlock FILE` | Removes a password (asked for) or an owner's restrictions (no password needed) |
| `metadata show FILE` | The document information and XMP fields, and how many other metadata records there are |
| `metadata strip FILE...` | Removes the document information, every XMP packet and application data, and rewrites the file |
| `bookmarks show FILE` | The bookmark tree with page numbers |
| `bookmarks copy SOURCE TARGET` | Puts the source's bookmarks on the target, page for page, keeping each view |
| `watermarks FILE` | Finds overlays repeated across pages and removes those it is sure of |
| `from-djvu FILE` | Converts a DjVu document to PDF with `ddjvu` |

Pages are counted from 1: `5`, `5-10`, `1-3,7,10-z`, where `z` (or `last`)
is the last page and `10-1` runs backwards. `extract` takes pages in the
order given, so it can also reorder and repeat them.

Exit status: 0 on success, 1 when the task fails, 2 for a usage error
(including a page the document does not have), 130 when interrupted.

## Outputs

- A command writes a new file next to its input, named after it
  (`book_rotated.pdf`, `book_compressed.pdf`), unless `-o` names one.
  `-i`/`--in-place` replaces the input instead, keeping its permissions.
- An existing file is replaced only with `-f`/`--force`, and the input only
  with `--in-place`: naming the input as `-o` is refused.
- Every file is written to a temporary file beside its destination and
  renamed into place, so an interruption or a failure never leaves half a
  PDF and never touches the old file.
- A new document built from chosen pages keeps the document information,
  the XMP metadata and the bookmarks whose pages it still holds.
- Saving keeps the protection a file had: an owner's restrictions survive
  every command except `unlock`. The commands whose output is a new
  document (`extract`, `delete`, `split`, `merge`) and lossy compression
  refuse such a file, because they would drop the restriction; `unlock`
  it first.
- `-i`/`--in-place` on a symbolic link replaces the file the link points
  at, not the link.

## Passwords

A password is never taken from the command line, where the shell history
and the process list would keep it. It is typed at the terminal without
echo (twice for `protect`) or read from the first line of the file named
by `--password-file`. That can be a pipe, so a secret manager hands the
password over without writing it to disk:

```sh
pdf-tools protect a.pdf --password-file <(op read op://Vault/Item/password)
```

## Metadata

`metadata strip` removes the document information dictionary, the
document's XMP packet, those on pages, images and other objects, and
`/PieceInfo` application data, then rewrites the whole file with an
identifier derived from the content. An editor that only appends an
update (as `exiftool` does on its own) leaves the old values in the file;
the rewrite does not.

## Watermarks

The content of each page is read as PDF operators and never rasterized.
Small streams that only draw text or a form, text blocks and drawn
XObjects are clustered across pages by their operators, position, form and
masked text, then scored: how many pages repeat them, a stable position,
transparency, rotation, a form container, text named with `--match-text`.
Only a cluster with a watermark-specific cue and a high score is removed;
the others are reported with `--verbose` and in the `--report` JSON.

Removal keeps the page's drawing state: a block wrapped in `q`/`Q` goes
whole, while from an unwrapped block only the operators that draw are cut,
so a colour, font or transformation later content relies on stays. With
`--redact`, a block whose stream cannot be edited is covered with white
instead, when its extent is known.

## Limits

- Bookmarks pointing into other documents, and links inside pages that use
  named destinations, are not carried over by `extract`, `delete`, `split`
  and `merge`.
- Lossy compression rewrites the whole file through Ghostscript, which can
  change form fields and structure; lossless compression never does.
- `from-djvu` keeps the page images, not DjVu's hidden text layer.
- Watermarks baked into page images, or drawn as part of the page's own
  content, cannot be told apart structurally and stay.

## Tests

`nix build .#pdf-tools -L` runs the tests in `tests/`, which build their own
PDFs with pikepdf and use fake `gs` and `ddjvu`. Without Nix, with pikepdf
installed, from this directory: `python3 -m unittest discover -s tests -t .`.
