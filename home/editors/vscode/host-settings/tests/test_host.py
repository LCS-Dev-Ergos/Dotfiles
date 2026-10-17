"""Host locations on every platform flavor, independent of the running one."""

import unittest
from pathlib import Path, PurePath, PurePosixPath, PureWindowsPath

from core.errors import SettingsError
from core.host import Edition, Host, Platform

WINDOWS_HOME = PureWindowsPath("C:/Users/u")


def windows(**env: str) -> Host:
    """A Windows host, described without touching any filesystem."""
    return Host(Platform.WINDOWS, WINDOWS_HOME, "u", env)


class LocationTests(unittest.TestCase):
    """Configuration, state and cache locations per platform."""

    def test_default_user_data_dir_per_platform(self) -> None:
        """Each platform puts the user settings in its own place."""
        mac = Host(Platform.DARWIN, PurePosixPath("/h"), "u")
        self.assertEqual(
            mac.user_data_dir(Edition.STABLE),
            PurePosixPath("/h/Library/Application Support/Code/User"),
        )
        linux = Host(
            Platform.LINUX, PurePosixPath("/h"), "u", {"XDG_CONFIG_HOME": "/c"}
        )
        self.assertEqual(
            linux.user_data_dir(Edition.INSIDERS),
            PurePosixPath("/c/Code - Insiders/User"),
        )
        self.assertEqual(
            windows(APPDATA="D:\\Roaming").user_data_dir(Edition.STABLE),
            PureWindowsPath("D:/Roaming/Code/User"),
        )
        self.assertEqual(
            windows().user_data_dir(Edition.STABLE),
            PureWindowsPath("C:/Users/u/AppData/Roaming/Code/User"),
        )

    def test_relative_environment_directories_are_ignored(self) -> None:
        """Relative or empty XDG variables fall back to the defaults."""
        linux = Host(
            Platform.LINUX,
            PurePosixPath("/h"),
            "u",
            {"XDG_CONFIG_HOME": "rel", "XDG_STATE_HOME": ""},
        )
        self.assertEqual(linux.config_home(), PurePosixPath("/h/.config"))
        self.assertEqual(linux.state_home(), PurePosixPath("/h/.local/state"))

    def test_state_and_cache_homes(self) -> None:
        """Windows uses LOCALAPPDATA for state and has no cache home."""
        self.assertEqual(
            windows(LOCALAPPDATA="E:\\Local").state_home(),
            PureWindowsPath("E:/Local"),
        )
        self.assertIsNone(windows().cache_home())
        mac = Host(Platform.DARWIN, PurePosixPath("/h"), "u")
        self.assertEqual(mac.cache_home(), PurePosixPath("/h/Library/Caches"))

    def test_home_must_be_an_absolute_path_of_the_platform_flavor(
        self,
    ) -> None:
        """A home of the wrong flavor, or a relative one, is rejected."""
        with self.assertRaises(ValueError):
            Host(Platform.WINDOWS, PurePosixPath("/h"), "u")
        with self.assertRaises(ValueError):
            Host(Platform.LINUX, PureWindowsPath("C:/h"), "u")
        with self.assertRaises(ValueError):
            Host(Platform.LINUX, PurePosixPath("h"), "u")

    def test_platform_conventions(self) -> None:
        """Executable names and library suffixes follow the platform."""
        self.assertEqual(Platform.WINDOWS.executable("cmake"), "cmake.exe")
        self.assertEqual(Platform.LINUX.executable("cmake"), "cmake")
        self.assertEqual(Platform.DARWIN.shared_library_suffix, ".dylib")
        self.assertIsNone(Platform.WINDOWS.shared_library_suffix)


class SearchTests(unittest.TestCase):
    """The directories tools are searched in."""

    def test_profiles_come_first_and_path_is_deduplicated(self) -> None:
        """Profiles precede PATH; relative and repeated entries are dropped."""
        host = Host(
            Platform.LINUX,
            PurePosixPath("/h"),
            "u",
            {"PATH": "/usr/bin::rel:/h/.nix-profile/bin:/usr/bin"},
        )
        self.assertEqual(
            [str(path) for path in host.search_dirs()],
            [
                "/etc/profiles/per-user/u/bin",
                "/h/.nix-profile/bin",
                "/h/.local/state/nix/profiles/profile/bin",
                "/h/.local/state/home-manager/gcroots/current-home/"
                "home-path/bin",
                "/usr/bin",
            ],
        )

    def test_gcroot_can_come_first(self) -> None:
        """The gcroot is last by default and first on request."""
        host = Host(Platform.LINUX, PurePosixPath("/h"), "u")
        roots = host.profile_roots(gcroot_first=True)
        self.assertEqual(roots[0].name, "home-path")
        self.assertEqual(host.profile_roots()[-1], roots[0])

    def test_an_unknown_user_has_no_per_user_profile(self) -> None:
        """Without a user name there is no per-user profile to search."""
        host = Host(Platform.LINUX, PurePosixPath("/h"), "")
        roots = [str(root) for root in host.profile_roots()]
        self.assertFalse(any("per-user" in root for root in roots))

    def test_windows_path_uses_semicolons(self) -> None:
        """Windows PATH splits on semicolons and adds the usual install dirs."""
        host = windows(PATH="C:\\a;relative;;C:\\b", ProgramFiles="D:\\Apps")
        self.assertEqual(
            host.search_dirs(),
            [
                PureWindowsPath("D:/Apps/LLVM/bin"),
                PureWindowsPath("D:/Apps/CMake/bin"),
                PureWindowsPath("C:/Users/u/scoop/shims"),
                PureWindowsPath("C:/a"),
                PureWindowsPath("C:/b"),
            ],
        )
        self.assertEqual(host.profile_roots(), [])


class ConcreteTests(unittest.TestCase):
    """The step from a location to the filesystem."""

    def test_a_foreign_flavor_is_never_inspected(self) -> None:
        """A host of the other path flavor is never looked at on disk."""
        native = type(PurePath())
        foreign = (
            windows()
            if native is PurePosixPath
            else Host(Platform.LINUX, PurePosixPath("/h"), "u")
        )
        with self.assertRaisesRegex(SettingsError, "cannot be inspected"):
            foreign.concrete(foreign.home)

    def test_the_running_system_is_inspected(self) -> None:
        """The detected host is the running one and can be inspected."""
        host = Host.detect()
        self.assertIs(host.platform, Platform.current())
        self.assertEqual(host.concrete(host.home), Path.home())


if __name__ == "__main__":
    unittest.main()
