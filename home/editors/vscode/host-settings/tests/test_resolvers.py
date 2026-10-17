"""How managed values are found on a machine."""

import os
import unittest
from pathlib import PurePosixPath, PureWindowsPath

from core.host import Host, Platform
from core.manifest import COMPILER_DRIVERS
from core.resolvers import (
    CacheDirectory,
    CompilerAllowList,
    Executable,
    FirstExisting,
    FirstOf,
    Fixed,
    SdkmanJdk,
    SharedLibrary,
    home_relative,
)
from tests.support import Machine, make_executable

ALLOW_LIST = CompilerAllowList(COMPILER_DRIVERS)


class ExecutableTests(unittest.TestCase):
    """Executables in the Nix profiles and on PATH."""

    def test_profile_beats_path(self) -> None:
        """A tool in a profile wins over one on PATH."""
        m = Machine(self)
        elsewhere = m.tool("clangd", "elsewhere")
        m.set_env(PATH=str(elsewhere.parent))
        profile = m.tool("clangd")
        self.assertEqual(Executable("clangd").resolve(m.host), str(profile))

    def test_path_is_used_when_the_profile_lacks_the_tool(self) -> None:
        """PATH is searched when no profile has the tool."""
        m = Machine(self)
        elsewhere = m.tool("cmake", "elsewhere")
        m.set_env(PATH=str(elsewhere.parent))
        self.assertEqual(Executable("cmake").resolve(m.host), str(elsewhere))

    def test_relative_empty_and_working_directories_are_ignored(self) -> None:
        """Neither relative PATH entries nor the working directory count."""
        m = Machine(self)
        make_executable(m.root / "relative" / "cmake")
        make_executable(m.root / "cmake")
        previous = os.getcwd()
        os.chdir(m.root)
        self.addCleanup(os.chdir, previous)
        m.set_env(PATH=os.pathsep.join(["", "relative"]))
        self.assertIsNone(Executable("cmake").resolve(m.host))

    def test_alternatives_are_tried_in_order(self) -> None:
        """Alternative names are tried in order and named in the hint."""
        m = Machine(self)
        second = m.tool("godot4")
        resolver = Executable("godot", ("godot4",))
        self.assertEqual(resolver.resolve(m.host), str(second))
        self.assertEqual(
            resolver.hint, "no godot or godot4 in the Nix profiles or on PATH"
        )

    def test_non_executable_file_is_not_a_tool(self) -> None:
        """A file without the execute bit is not a tool."""
        m = Machine(self)
        m.tool("shfmt").chmod(0o644)
        self.assertIsNone(Executable("shfmt").resolve(m.host))

    def test_directory_is_not_a_tool(self) -> None:
        """A directory with the tool's name is not a tool."""
        m = Machine(self)
        (m.profile / "bin" / "cmake").mkdir(parents=True)
        self.assertIsNone(Executable("cmake").resolve(m.host))

    def test_symlink_is_kept_not_resolved(self) -> None:
        """The profile link is returned, not the store path behind it."""
        m = Machine(self)
        real = make_executable(m.root / "store" / "clangd")
        link = m.profile / "bin" / "clangd"
        link.parent.mkdir(parents=True)
        link.symlink_to(real)
        self.assertEqual(Executable("clangd").resolve(m.host), str(link))


class JdkTests(unittest.TestCase):
    """SDKMAN JDKs chosen by major release."""

    def test_sdkman_picks_the_newest_of_the_major(self) -> None:
        """The newest release of the major wins; 'current' is ignored."""
        m = Machine(self)
        base = m.home / ".sdkman" / "candidates" / "java"
        for name in ("21.0.8-tem", "21.0.12+1.1-tem", "25.0.4-tem", "17-tem"):
            make_executable(base / name / "bin" / "java")
        (base / "current").symlink_to(base / "25.0.4-tem")
        newest_21 = str(base / "21.0.12+1.1-tem")
        self.assertEqual(SdkmanJdk(21).resolve(m.host), newest_21)
        self.assertEqual(
            SdkmanJdk(25).resolve(m.host), str(base / "25.0.4-tem")
        )
        self.assertIsNone(SdkmanJdk(11).resolve(m.host))

    def test_sdkman_ignores_directories_without_a_java(self) -> None:
        """A candidate without bin/java is not a JDK."""
        m = Machine(self)
        java = m.home / ".sdkman" / "candidates" / "java"
        (java / "21.0.1-tem").mkdir(parents=True)
        self.assertIsNone(SdkmanJdk(21).resolve(m.host))

    def test_sdkman_locations_from_the_environment(self) -> None:
        """SDKMAN_DIR is honored and a relative candidates dir ignored."""
        m = Machine(self)
        custom = m.root / "sdk" / "candidates" / "java" / "21.0.1-tem"
        make_executable(custom / "bin" / "java")
        m.set_env(SDKMAN_DIR=str(m.root / "sdk"))
        self.assertEqual(SdkmanJdk(21).resolve(m.host), str(custom))
        m.set_env(SDKMAN_CANDIDATES_DIR="relative")
        self.assertEqual(SdkmanJdk(21).resolve(m.host), str(custom))
        m.set_env(SDKMAN_CANDIDATES_DIR=str(m.root / "none"))
        self.assertIsNone(SdkmanJdk(21).resolve(m.host))


class LibraryTests(unittest.TestCase):
    """Shared libraries in the Nix profiles."""

    def test_library_prefers_the_home_manager_gcroot(self) -> None:
        """The gcroot is searched before the other profiles."""
        m = Machine(self)
        for lib in (m.gcroot / "lib", m.profile / "lib"):
            lib.mkdir(parents=True)
            (lib / "liblldb.so").write_text("")
        found = SharedLibrary("lldb").resolve(m.host)
        self.assertEqual(found, str(m.gcroot / "lib" / "liblldb.so"))

    def test_library_falls_back_to_the_newest_versioned_name(self) -> None:
        """Versioned names compare numerically, newest first."""
        m = Machine(self)
        lib = m.profile / "lib"
        lib.mkdir(parents=True)
        for name in ("liblldb.so.9", "liblldb.so.22", "liblldb.so.22.1"):
            (lib / name).write_text("")
        found = SharedLibrary("lldb").resolve(m.host)
        self.assertEqual(found, str(lib / "liblldb.so.22.1"))

    def test_library_suffix_follows_the_platform(self) -> None:
        """macOS looks for .dylib, not .so."""
        m = Machine(self, Platform.DARWIN)
        lib = m.profile / "lib"
        lib.mkdir(parents=True)
        (lib / "liblldb.so").write_text("")
        self.assertIsNone(SharedLibrary("lldb").resolve(m.host))
        (lib / "liblldb.dylib").write_text("")
        found = SharedLibrary("lldb").resolve(m.host)
        self.assertEqual(found, str(lib / "liblldb.dylib"))


class AllowListTests(unittest.TestCase):
    """The compiler driver allow-list for clangd."""

    def listed(self, host: Host) -> list[str]:
        """The allow-list for ``host`` as a list."""
        value: str = ALLOW_LIST.resolve(host) or ""
        return value.split(",")

    def test_only_trusted_directories_are_listed(self) -> None:
        """Drivers on PATH are never listed."""
        m = Machine(self)
        trusted = m.tool("clang")
        stray = m.tool("clang", "stray")
        m.set_env(PATH=str(stray.parent))
        listed = self.listed(m.host)
        self.assertIn(str(trusted), listed)
        self.assertNotIn(str(stray), listed)

    def test_a_driver_is_listed_once_per_real_file(self) -> None:
        """A profile and its gcroot list the same file once."""
        m = Machine(self)
        first = m.tool("clang")
        (m.gcroot / "bin").mkdir(parents=True)
        (m.gcroot / "bin" / "clang").symlink_to(first)
        listed = self.listed(m.host)
        self.assertIn(str(first), listed)
        self.assertNotIn(str(m.gcroot / "bin" / "clang"), listed)

    def test_paths_that_could_widen_the_match_are_dropped(self) -> None:
        """A path with a comma or glob character is left out."""
        m = Machine(self)
        odd_home = m.root / "home,odd" / "tester"
        make_executable(odd_home / ".nix-profile" / "bin" / "clang")
        host = Host(Platform.LINUX, odd_home, "tester", {"PATH": ""})
        self.assertNotIn("home,odd", ALLOW_LIST.resolve(host) or "")
        clean = m.tool("clang")
        self.assertIn(str(clean), self.listed(m.host))

    def test_no_driver_is_no_value(self) -> None:
        """Without any driver there is no value, not an empty list."""
        m = Machine(self)
        drivers = CompilerAllowList(("no-such-compiler-driver",))
        self.assertIsNone(drivers.resolve(m.host))


class PathTests(unittest.TestCase):
    """Fixed candidates, fallbacks and cache directories."""

    def test_first_existing_expands_home_and_respects_platforms(self) -> None:
        """~ is the home directory and other platforms find nothing."""
        m = Machine(self)
        target = m.home / "Applications" / "Godot.app"
        target.mkdir(parents=True)
        candidates = ("/nonexistent/Godot.app", "~/Applications/Godot.app")
        mac_only = FirstExisting("x", frozenset({Platform.DARWIN}), candidates)
        self.assertIsNone(mac_only.resolve(m.host))
        both = FirstExisting(
            "x", frozenset({Platform.DARWIN, Platform.LINUX}), candidates
        )
        self.assertEqual(both.resolve(m.host), str(target))

    def test_first_of_takes_the_first_found(self) -> None:
        """The first resolver with a value wins; hints are joined."""
        m = Machine(self)
        first = FirstOf((Executable("missing"), Fixed("a"), Fixed("b")))
        self.assertEqual(first.resolve(m.host), "a")
        self.assertEqual(
            first.hint,
            "no missing in the Nix profiles or on PATH / fixed / fixed",
        )

    def test_cache_directory_per_platform(self) -> None:
        """The JDT index follows each platform's cache directory."""
        jdt = CacheDirectory(".jdt/index")
        mac = Host(Platform.DARWIN, PurePosixPath("/h"), "u")
        self.assertEqual(jdt.resolve(mac), "~/Library/Caches/.jdt/index")
        linux = Host(Platform.LINUX, PurePosixPath("/h"), "u")
        self.assertEqual(jdt.resolve(linux), "~/.cache/.jdt/index")
        moved = Host(
            Platform.LINUX, PurePosixPath("/h"), "u", {"XDG_CACHE_HOME": "/c"}
        )
        self.assertEqual(jdt.resolve(moved), "/c/.jdt/index")
        windows = Host(Platform.WINDOWS, PureWindowsPath("C:/h"), "u")
        self.assertIsNone(jdt.resolve(windows))

    def test_home_relative(self) -> None:
        """Paths below the home directory are spelled with ~."""
        home = PurePosixPath("/h")
        self.assertEqual(home_relative(PurePosixPath("/h/a/b"), home), "~/a/b")
        self.assertEqual(home_relative(home, home), "~")
        self.assertEqual(home_relative(PurePosixPath("/x"), home), "/x")


if __name__ == "__main__":
    unittest.main()
