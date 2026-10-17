"""What the tool manages, and how each value is found.

``LEAVES`` are top-level keys whose whole value is host-bound; one that is
missing from the file is added to the generated block. ``NESTED`` are strings
inside a container that must already exist; they are updated, never created.
"""

import re
from dataclasses import dataclass
from typing import TypeAlias

from .host import Platform
from .jsonc import describe_path
from .resolvers import (
    CacheDirectory,
    CompilerAllowList,
    Executable,
    FirstExisting,
    FirstOf,
    Fixed,
    Resolver,
    SdkmanJdk,
    SharedLibrary,
)

IGNORED_KEY = "settingsSync.ignoredSettings"
"""The Settings Sync exclusion list every managed top-level key joins."""

QUERY_DRIVER_KEY = "hostLocal.clangdQueryDriver"
"""The per-machine key holding clangd's compiler driver allow-list."""

QUERY_DRIVER_ARGUMENT = f"--query-driver=${{config:{QUERY_DRIVER_KEY}}}"
"""The synced clangd argument that points at the per-machine allow-list.

clangd expands ``${config:...}`` in its arguments, so this argument stays
identical on every machine while the list behind it is generated per host.
"""

COMPILER_DRIVERS = ("clang", "clang++", "gcc", "g++", "cc", "c++")
"""The driver names the allow-list may contain."""

HOST_BOUND = re.compile(
    r"(?:^|[\s=,:\"'])(?:/Users/[^/\s]+|/home/[^/\s]+"
    r"|/etc/profiles/per-user/[^/\s]+|[A-Za-z]:\\Users\\)"
)
"""Text that names a user's home or profile directory.

A string that still matches after a run holds a value the manifest does not
cover, and is reported.
"""


@dataclass(frozen=True, slots=True)
class Leaf:
    """A top-level key whose whole value is a host-bound string."""

    key: str
    resolver: Resolver


@dataclass(frozen=True, slots=True)
class Key:
    """The member of an object called ``name``."""

    name: str

    @property
    def label(self) -> str:
        """The step as it appears in a report."""
        return self.name


@dataclass(frozen=True, slots=True)
class ObjectWith:
    """An array element that is an object whose ``key`` holds ``value``."""

    key: str
    value: str

    @property
    def label(self) -> str:
        """The step as it appears in a report."""
        return self.value


@dataclass(frozen=True, slots=True)
class StringWithPrefix:
    """An array element that is a string starting with ``prefix``."""

    prefix: str

    @property
    def label(self) -> str:
        """The step as it appears in a report."""
        return self.prefix


Step: TypeAlias = Key | ObjectWith | StringWithPrefix


@dataclass(frozen=True, slots=True)
class Nested:
    """A string reached from the root through ``steps``."""

    steps: tuple[Step, ...]
    resolver: Resolver

    @property
    def label(self) -> str:
        """The target as it appears in a report."""
        return describe_path(tuple(step.label for step in self.steps))


_POSIX = frozenset({Platform.DARWIN, Platform.LINUX})

LEAVES: tuple[Leaf, ...] = (
    Leaf("clangd.path", Executable("clangd")),
    Leaf(QUERY_DRIVER_KEY, CompilerAllowList(COMPILER_DRIVERS)),
    Leaf("C_Cpp.default.compilerPath", Executable("clang++")),
    Leaf("cmake.cmakePath", Executable("cmake")),
    Leaf("clang-format.executable", Executable("clang-format")),
    Leaf("bashIde.shellcheckPath", Executable("shellcheck")),
    Leaf("bashIde.shfmt.path", Executable("shfmt")),
    Leaf("nix.serverPath", Executable("nixd")),
    Leaf("nix.formatterPath", Executable("nixfmt")),
    Leaf("lldb.library", SharedLibrary("lldb")),
    Leaf("java.jdt.ls.java.home", SdkmanJdk(25)),
    Leaf("java.import.gradle.java.home", SdkmanJdk(21)),
    Leaf("java.sharedIndexes.location", CacheDirectory(".jdt/index")),
    Leaf(
        "vsrocq.path",
        FirstExisting(
            "no vsrocqtop in the rocq opam switch",
            _POSIX,
            ("~/.opam/rocq/bin/vsrocqtop",),
        ),
    ),
    Leaf(
        "godotTools.editorPath.godot4",
        FirstOf(
            (
                FirstExisting(
                    "no Godot.app",
                    frozenset({Platform.DARWIN}),
                    ("/Applications/Godot.app", "~/Applications/Godot.app"),
                ),
                Executable("godot", ("godot4",)),
            )
        ),
    ),
)

NESTED: tuple[Nested, ...] = (
    Nested(
        (Key("clangd.arguments"), StringWithPrefix("--query-driver=")),
        Fixed(QUERY_DRIVER_ARGUMENT),
    ),
    Nested(
        (
            Key("java.configuration.runtimes"),
            ObjectWith("name", "JavaSE-21"),
            Key("path"),
        ),
        SdkmanJdk(21),
    ),
    Nested(
        (
            Key("java.configuration.runtimes"),
            ObjectWith("name", "JavaSE-25"),
            Key("path"),
        ),
        SdkmanJdk(25),
    ),
)
