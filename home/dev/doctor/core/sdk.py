"""Which SDK headers the active C compiler reaches with no extra flags.

Apple bundles a set of third-party libraries inside the macOS SDK, and a
Linux distribution installs its libraries' headers under ``/usr/include``.
A compiler whose sysroot is elsewhere cannot include them: nixpkgs' stdenv
compilers in a ``nix develop`` shell use an apple-sdk that strips them, and
Nix's compiler wrappers on Linux search Nix's glibc, not the distribution.
Whatever compiles C from source against one of them (pyenv, rbenv,
node-gyp, cargo build scripts, opam) then behaves differently depending on
the active compiler, usually by silently leaving a feature out.

Each probe only checks the syntax of a file that includes the header; it
does not tell whether a library is installed, links or runs.
"""

import os
import tempfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from . import process
from .compilers import selected
from .host import Host, Platform

PROBE_TIMEOUT = 10.0
"""Seconds one header probe may take."""

HEADERS = (
    ("zlib.h", "compression (Python zlib, Ruby zlib, git)", "zlib"),
    ("bzlib.h", "compression (Python bz2)", "bzip2"),
    ("lzma.h", "compression (Python lzma)", "xz"),
    ("sqlite3.h", "database (Python sqlite3)", "sqlite"),
    ("editline/readline.h", "line editing (Ruby readline)", "readline"),
    ("readline/readline.h", "line editing (Python readline)", "readline"),
    ("ffi.h", "foreign calls (Python ctypes, Ruby fiddle)", "libffi"),
    ("expat.h", "XML (Python pyexpat)", "expat"),
    ("libxml/parser.h", "XML (Nokogiri, lxml)", "libxml2"),
    ("curl/curl.h", "HTTP (pycurl, curb)", "curl"),
    ("krb5.h", "Kerberos", "krb5"),
    ("tcl.h", "Tcl/Tk (Python tkinter)", "tcl-tk"),
    ("pcap.h", "packet capture", "libpcap"),
    ("iconv.h", "character conversion", "libiconv"),
    ("curses.h", "terminal UI (Python curses)", "ncurses"),
)
"""Each header, what needs it and the Homebrew formula that ships it."""


@dataclass(frozen=True)
class Reach:
    """Whether each compiler reaches one header.

    Attributes:
        header: The header, as ``#include`` names it.
        purpose: What needs it.
        active: Whether the active compiler reaches it.
        system: Whether the system compiler does; ``None`` without one.
        hint: Where Homebrew has it, on macOS when the active one misses it.
    """

    header: str
    purpose: str
    active: bool
    system: bool | None
    hint: str

    @property
    def diverges(self) -> bool:
        """Whether the system compiler reaches it and the active one not."""
        return self.system is not None and self.active != self.system


@dataclass(frozen=True)
class Survey:
    """The probe of every header.

    Attributes:
        active: The active compiler, as ``CC`` names it.
        system: The system compiler, or ``None`` when there is none.
        reaches: One entry per header, in ``HEADERS`` order.
    """

    active: tuple[str, ...]
    system: Path | None
    reaches: tuple[Reach, ...]

    @property
    def divergent(self) -> int:
        """How many headers the system compiler reaches and the active not."""
        return sum(1 for reach in self.reaches if reach.diverges)


def survey(host: Host, system: Path = Path("/usr/bin/cc")) -> Survey:
    """Probe every header with the active and the system compiler.

    The probes run side by side in a private temporary directory, which is
    removed afterwards.
    """
    active = selected(host, "CC")
    usable = system.is_file() and os.access(system, os.X_OK)
    reference = system if usable else None
    with tempfile.TemporaryDirectory(prefix="toolchain-sdk.") as scratch:
        directory = Path(scratch)

        def probe(argv: tuple[str, ...], index: int) -> bool:
            """Whether ``argv`` compiles an include of header ``index``."""
            header = HEADERS[index][0]
            source = directory / f"probe-{index}.c"
            source.write_text(f"#include <{header}>\nint main(void){{}}\n")
            outcome = process.run(
                (*argv, "-fsyntax-only", str(source)),
                host.env,
                PROBE_TIMEOUT,
                cwd=directory,
            )
            return outcome.ok

        indices = range(len(HEADERS))
        seen: list[bool | None] = [None] * len(HEADERS)
        with ThreadPoolExecutor(max_workers=8) as pool:
            reached = list(pool.map(probe, [active] * len(HEADERS), indices))
            if reference is not None:
                argv = (str(reference),)
                seen = list(pool.map(probe, [argv] * len(HEADERS), indices))
    brew = Path(host.brew_prefix()) / "opt"
    reaches: list[Reach] = []
    for (header, purpose, formula), hit, other in zip(
        HEADERS, reached, seen, strict=True
    ):
        hint = ""
        if not hit and host.platform is Platform.MACOS:
            installed = (brew / formula / "include").is_dir()
            hint = (
                f"brew: {formula}" if installed else f"brew install {formula}"
            )
        reaches.append(Reach(header, purpose, hit, other, hint))
    return Survey(active, reference, tuple(reaches))
