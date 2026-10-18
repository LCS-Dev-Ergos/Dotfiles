# Security Scan

`security-scan` checks files and folders for documents that carry more than
they claim: a program under a document's name, a program hidden inside a
file, a PDF that starts something when opened, an archive that bundles
scripts. Home Manager installs it on macOS and Linux, with `secscan` as a
short name, along with a `freshclam` that keeps ClamAV's signatures
current.

```sh
security-scan ~/Downloads/book.pdf                # one file
security-scan ~/Books --report ~/scan.json --hash # a folder, with a JSON report
security-scan . --no-clamav --verbose             # quickly, listing clean files too
security-scan -q ~/Downloads                      # the summary alone
```

Exit status: 0 when every file was scanned by every layer that could run
and nothing was flagged; 1 when a file was flagged with a warning or worse,
even if the scan is incomplete; 2 when the scan is incomplete (a path was
missing, a file unreadable, a layer failed) or cannot run, and for a usage
error; 130 when interrupted.

## Layers

| Layer | Source | What it finds |
| --- | --- | --- |
| Structural | Built in, with pikepdf | Content that contradicts the extension, programs hidden inside files, PDF Launch actions, JavaScript and attachments, programs and escaping paths in ZIP-based documents, VBA macros in Office files |
| YARA | Bundled, with yara-python | The rules in [`rules/document-threats.yar`](rules/document-threats.yar), or `--yara-rules FILE` |
| ClamAV | Bundled, with signatures from `freshclam` | The antivirus's signatures |

All three layers are part of the package. ClamAV's signatures are per
user, in `$XDG_DATA_HOME/clamav`: the module's `freshclam` reads
`~/.config/clamav/freshclam.conf` and updates them once a day, from a
launchd agent on macOS and a systemd user timer on Linux, logging errors
to `$XDG_STATE_HOME/clamav/freshclam.log`. The agent also runs when it
loads; on Linux, run `freshclam` once for the first download. Without
signatures, or with signatures more than a week old, the report says so,
and the scan still completes without ClamAV.

A finding is `critical` (a program in disguise, a Launch action that starts
a program, a signature match), a `warning` (a mismatch worth a look,
JavaScript that runs by itself, attachments, a locked PDF) or `info`
(JavaScript behind a link, a file ClamAV only partly scanned). Programs
inside software packages and disk images (APK, ISO, DMG, ZIP and the like)
are expected and not reported.

YARA rules may set `severity` and `description` in their meta, and read the
external variable `software`, true for those packages and images.

## Guarantees

- Files are only read: the scan opens each read-only, ClamAV runs without
  any option that moves or removes files, and nothing is opened in a
  viewer.
- A folder is walked without following symbolic links, and only regular
  files are read, so a link cannot lead the scan elsewhere and a named pipe
  cannot stall it. Links and special files inside folders are counted; a
  path named on the command line is followed.
- A file counts as clean only when every layer that ran finished on it. A
  file a layer could not read, a folder that could not be listed, or a
  layer that failed is reported, and the exit status says the scan is
  incomplete.
- YARA has 60 seconds per file. ClamAV runs once over the batch, from a
  private file list, under a time limit that stops it and everything it
  started; its size limits are reported instead of passing as clean.
- File names and messages are escaped before they reach the terminal. The
  JSON report is written whole or not at all, readable only by its owner.

## Limits

YARA reads raw bytes, so text inside compressed streams (most PDF
JavaScript, macro source in modern Office files) is invisible to it; the
structural layer covers those containers instead. A clean report means
none of the checks matched, not that a file is safe.

## Tests

`nix build .#security-scan -L` runs the tests in `tests/`, which write their
own samples and use a fake `clamscan`. Without Nix, with pikepdf and
yara-python installed, from this directory:
`python3 -m unittest discover -s tests -t .`.
