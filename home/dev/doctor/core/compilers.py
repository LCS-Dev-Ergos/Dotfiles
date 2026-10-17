"""C and C++ compilers: how ``CC`` is read and what a binary really is.

``dev-doctor``, ``toolchain info``, ``toolchain sdk`` and the compiler
selection all read ``CC`` and ``CXX`` the same way and identify a compiler
from its own ``--version`` banner, never from its name: ``gcc`` on macOS is
Apple's Clang unless something else comes first.
"""

import os
import re
import shlex
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from . import process
from .host import Host
from .versions import first_line, token

BASE_NAMES = ("cc", "c++", "gcc", "g++", "clang", "clang++")
"""The compiler names ``toolchain info`` always reports."""

_VERSIONED = re.compile(r"(gcc|g\+\+|clang|clang\+\+)-(\d+)")
_CCACHE_FALLBACKS = (
    "/usr/bin",
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "/Applications/Xcode.app/Contents/Developer/Toolchains/"
    "XcodeDefault.xctoolchain/usr/bin",
)
_NIX = ("/nix/store/", "/etc/profiles/per-user/", "/run/current-system/sw/")


class Kind(Enum):
    """The compiler family a banner names."""

    CLANG = "Clang"
    GCC = "GCC"
    UNKNOWN = "Unknown"


@dataclass(frozen=True)
class Identity:
    """What a compiler says it is.

    Attributes:
        kind: Its family.
        vendor: Who built it, such as ``Apple`` or ``Nix LLVM``.
        banner: The first line of its ``--version``; empty when it did not
            run.
        gnu: Whether the banner credits the Free Software Foundation, which
            only a real GNU compiler does.
    """

    kind: Kind
    vendor: str
    banner: str
    gnu: bool = False

    @property
    def ran(self) -> bool:
        """Whether ``--version`` succeeded."""
        return bool(self.banner)

    @property
    def version(self) -> str:
        """The version number in the banner, such as ``23.1.3``."""
        found = re.search(r"\d+\.\d+(\.\d+)?", self.banner)
        return found[0] if found else token(self.banner)

    @property
    def toolchain(self) -> str:
        """The vendor and family, such as ``Nix LLVM Clang``."""
        return " ".join(
            part for part in (self.vendor, self.kind.value) if part
        )


def command(spec: str) -> tuple[str, ...]:
    """``CC`` or ``CXX`` as arguments, launcher and flags included.

    A value that names an executable as a whole is one argument even if it
    holds spaces; anything else is split the way a POSIX shell splits
    quoted words, without expanding or evaluating anything. A value that
    cannot be split stays one argument, so running it fails visibly.
    """
    if os.path.isfile(spec) and os.access(spec, os.X_OK):
        return (spec,)
    try:
        words = tuple(shlex.split(spec))
    except ValueError:
        return (spec,)
    return words or (spec,)


def selected(host: Host, variable: str) -> tuple[str, ...]:
    """The compiler ``CC`` or ``CXX`` selects, or ``cc``/``c++`` without it."""
    default = "cc" if variable == "CC" else "c++"
    return command(host.get(variable) or default)


def identify(host: Host, argv: tuple[str, ...], timeout: float) -> Identity:
    """Run ``argv --version`` and read the banner.

    The vendor is judged from the banner and from where the compiler really
    lives, so the first program of ``argv`` should be its real path.
    """
    outcome = process.run([*argv, "--version"], host.env, timeout)
    if not outcome.ok:
        return Identity(Kind.UNKNOWN, "", "")
    banner = first_line(outcome.output).replace("\r", "")
    gnu = "Free Software Foundation" in outcome.output
    path = argv[0] if argv else ""
    if "Apple clang" in banner or "clang version" in banner:
        return Identity(Kind.CLANG, _clang_vendor(banner, path), banner)
    if any(
        mark in banner for mark in ("(GCC)", "gcc version", "Homebrew GCC")
    ):
        return Identity(Kind.GCC, _gcc_vendor(banner, path), banner, gnu)
    return Identity(Kind.UNKNOWN, "", banner, gnu)


def _clang_vendor(banner: str, path: str) -> str:
    """Who built a Clang: Apple, Nix, Homebrew or a distribution."""
    if "Apple clang" in banner:
        return "Apple"
    if path.startswith(_NIX):
        return "Nix LLVM"
    for mark, vendor in (
        ("Homebrew", "Homebrew LLVM"),
        ("Ubuntu", "LLVM (Ubuntu)"),
        ("Debian", "LLVM (Debian)"),
    ):
        if mark in banner:
            return vendor
    return "LLVM (system)" if path.startswith("/usr/bin/") else "LLVM"


def _gcc_vendor(banner: str, path: str) -> str:
    """Who built a GCC: Nix, Homebrew or a distribution."""
    if "Homebrew" in banner or "/Cellar/gcc/" in path:
        return "Homebrew GNU"
    if path.startswith(_NIX):
        return "Nix GNU"
    for marks, vendor in (
        (("Ubuntu",), "GNU (Ubuntu)"),
        (("Debian",), "GNU (Debian)"),
        (("Arch Linux", "Archlinux"), "GNU (Arch)"),
    ):
        if any(mark in banner for mark in marks):
            return vendor
    return "GNU (system)" if path.startswith("/usr/bin/") else "GNU"


def names(host: Host) -> list[str]:
    """The compiler names to report: the usual ones, then versioned ones.

    Versioned names (``gcc-16``, ``clang-23``) are what Homebrew's GCC and
    some distributions' LLVM install, so each one found on PATH is listed
    after the usual names, by family and then by version.
    """
    versioned: set[tuple[int, int, str]] = set()
    for directory in host.search_path():
        try:
            entries = os.listdir(directory)
        except OSError:
            continue
        for entry in entries:
            matched = _VERSIONED.fullmatch(entry)
            if matched:
                family = BASE_NAMES.index(matched[1])
                versioned.add((family, int(matched[2]), entry))
    return [*BASE_NAMES, *(name for _, _, name in sorted(versioned))]


def real_path(host: Host, path: Path) -> Path:
    """The compiler a link or a ccache masquerade directory stands for.

    ccache's masquerade directory holds links named after compilers that
    all point at ccache, so the real one is the next of that name on PATH
    outside any ccache directory, or in the usual system locations.
    """
    resolved = Path(os.path.realpath(path))
    if "ccache" not in str(path) and "ccache" not in resolved.name:
        return resolved
    outside = [d for d in host.search_path() if "ccache" not in str(d)]
    for directories in (outside, [Path(d) for d in _CCACHE_FALLBACKS]):
        found = host.which(path.name, directories)
        if found is not None:
            real = Path(os.path.realpath(found))
            if "ccache" not in real.name:
                return real
    return resolved


@dataclass(frozen=True)
class Entry:
    """One compiler name and what PATH makes of it.

    Attributes:
        name: The name looked up, such as ``gcc``.
        path: Where PATH finds it, or ``None``.
        real: The compiler it stands for, behind links and ccache.
        identity: What the real compiler says it is.
        wrapper: What the found binary itself says it is.
    """

    name: str
    path: Path | None = None
    real: Path | None = None
    identity: Identity | None = None
    wrapper: Identity | None = None

    @property
    def masquerade(self) -> str:
        """The family this name claims and does not have, if it lies."""
        if self.identity is None:
            return ""
        family = self.name.split("-")[0]
        if family in ("gcc", "g++") and self.identity.kind is Kind.CLANG:
            return "Clang"
        if family in ("clang", "clang++") and self.identity.kind is Kind.GCC:
            return "GCC"
        return ""

    @property
    def resolution(self) -> str:
        """The path PATH found and, when different, the real compiler."""
        if self.path is None:
            return ""
        if self.real is None or self.real == self.path:
            return str(self.path)
        found = str(self.path)
        if "/ccache/" in found or "ccache/bin" in found:
            return f"ccache: {found} → {self.real}"
        return f"{found} → {self.real}"


def inspect(host: Host, timeout: float) -> list[Entry]:
    """Every compiler name ``names`` lists, identified side by side."""

    def entry(name: str) -> Entry:
        """One name, found and identified."""
        path = host.which(name)
        if path is None:
            return Entry(name)
        real = real_path(host, path)
        identity = identify(host, (str(real),), timeout)
        wrapper = identity
        if real != path:
            wrapper = identify(host, (str(path),), timeout)
        return Entry(name, path, real, identity, wrapper)

    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(entry, names(host)))
