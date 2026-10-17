"""Reading the editions: versions, folders, manifests and the host."""

import json
import unittest
from pathlib import Path

from core.errors import SyncError
from core.host import Edition, Host, Platform
from core.inventory import Kind, inspect, scan, servers
from core.manifest import (
    location_payload,
    read_manifest,
    read_manifests,
    read_obsolete,
    read_profiles,
)
from core.versions import engine_allows, parse_version
from tests.support import INSIDERS, STABLE, Machine


class VersionTests(unittest.TestCase):
    """Versions are ordered by semantic version precedence."""

    def order(self, *texts: str) -> list[str]:
        """``texts`` sorted by precedence."""
        versions = [parse_version(text) for text in texts]
        return [str(version) for version in sorted(v for v in versions if v)]

    def test_numbers_compare_as_numbers(self) -> None:
        """2.10 follows 2.9, and a missing number counts as zero."""
        self.assertEqual(self.order("2.10.0", "2.9.1"), ["2.9.1", "2.10.0"])
        self.assertEqual(parse_version("1.0"), parse_version("1.0.0"))

    def test_prereleases_come_first(self) -> None:
        """A pre-release precedes its release; numbers precede words."""
        self.assertEqual(
            self.order("1.0.0", "1.0.0-beta", "1.0.0-1", "1.0.0-beta.2"),
            ["1.0.0-1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0"],
        )

    def test_build_metadata_is_ignored(self) -> None:
        """``+build`` does not change the precedence."""
        self.assertEqual(parse_version("1.2.3+abc"), parse_version("1.2.3"))

    def test_engines_allow_their_versions(self) -> None:
        """``^``, ``>=``, ``x`` and ``*`` as VS Code reads them."""
        server = parse_version("1.100.2")
        assert server is not None
        for requirement, expected in (
            (None, True),
            ("*", True),
            ("^1.100.0", True),
            (">=1.100.2", True),
            ("1.100.x", True),
            ("^1.100.3", False),
            ("^1.101.0", False),
            ("^1.100.0-20251020", False),
            ("^1.99.0-20251020", True),
            ("latest", False),
            (100, False),
        ):
            with self.subTest(requirement=requirement):
                self.assertIs(engine_allows(requirement, server), expected)

    def test_other_text_is_no_version(self) -> None:
        """Anything else parses to None."""
        for text in ("", "latest", "v1.0", "1..2", None):
            with self.subTest(text=text):
                self.assertIsNone(parse_version(text))


class InventoryTests(unittest.TestCase):
    """Folders are read without following links."""

    def test_extensions_are_recognized_by_their_package(self) -> None:
        """Name and package.json must agree, platform suffix included."""
        machine = Machine(self)
        plain = machine.extension(STABLE, "pub.tool", "1.0.0")
        native = machine.extension(STABLE, "pub.tool", "1.0.0", "darwin-arm64")
        renamed = machine.root(STABLE) / "pub.tool-9.9.9"
        (machine.root(STABLE) / plain).rename(renamed)
        folders = scan(machine.root(STABLE))
        self.assertIsNone(folders["pub.tool-9.9.9"].package)
        package = folders[native].package
        assert package is not None
        self.assertEqual(package.extension_id, "pub.tool")
        self.assertEqual(package.platform, "darwin-arm64")

    def test_hidden_names_and_files_are_skipped(self) -> None:
        """``.obsolete``, temporary folders and files are no extensions."""
        machine = Machine(self)
        root = machine.root(STABLE)
        (root / ".obsolete").write_text("{}")
        (root / ".tmp-folder").mkdir()
        (root / "extensions.json").write_text("[]")
        self.assertEqual(scan(root), {})

    def test_links_are_read_as_written(self) -> None:
        """A relative link is resolved against its directory, lexically."""
        machine = Machine(self)
        root = machine.root(INSIDERS)
        (root / "a").symlink_to("../elsewhere/b")
        (root / "c").symlink_to(machine.root(STABLE) / "c")
        relative = inspect(root, "a")
        self.assertIs(relative.kind, Kind.LINK)
        self.assertEqual(relative.target, root.parent / "elsewhere" / "b")
        self.assertFalse(relative.target_exists())
        self.assertTrue(inspect(root, "c").links_into(machine.root(STABLE)))
        self.assertIs(inspect(root, "missing").kind, Kind.MISSING)


class ManifestTests(unittest.TestCase):
    """Manifests, profiles and deletion lists."""

    def test_references_and_skipped_entries(self) -> None:
        """Usable entries become references; the others are counted."""
        machine = Machine(self)
        path = machine.root(STABLE) / "extensions.json"
        entries = [
            machine.entry(STABLE, "pub.tool-1.0.0"),
            {"identifier": {"id": "Pub.Other"}, "location": {"path": "/x/y"}},
            {"identifier": {"id": "pub.bad"}, "relativeLocation": "../x"},
            "not an object",
        ]
        path.write_text(json.dumps(entries))
        manifest = read_manifest(path, "Default")
        assert manifest is not None
        self.assertEqual(
            [(r.extension_id, r.folder) for r in manifest.references],
            [("pub.tool", "pub.tool-1.0.0"), ("pub.other", "y")],
        )
        self.assertEqual(manifest.skipped, 2)
        self.assertEqual(len(manifest.entries), 4)

    def test_identifiers_must_be_publisher_and_name(self) -> None:
        """Anything else could pass for an option on a command line."""
        machine = Machine(self)
        path = machine.root(STABLE) / "extensions.json"
        entries = [
            {"identifier": {"id": ident}, "relativeLocation": "x-1.0.0"}
            for ident in ("--extensions-dir=x.y", "pub.tool;rm", "pub", "a.b")
        ]
        path.write_text(json.dumps(entries))
        manifest = read_manifest(path, "Default")
        assert manifest is not None
        self.assertEqual(
            [r.extension_id for r in manifest.references], ["a.b"]
        )
        self.assertEqual(manifest.skipped, 3)

    def test_unparsable_files_are_refused(self) -> None:
        """A manifest that is not a JSON array stops the run."""
        machine = Machine(self)
        path = machine.root(STABLE) / "extensions.json"
        for text in ("{", "{}", '"x"'):
            with self.subTest(text=text):
                path.write_text(text)
                with self.assertRaises(SyncError):
                    read_manifest(path, "Default")

    def test_profiles_come_from_storage(self) -> None:
        """Locations that are not plain relative paths are ignored."""
        machine = Machine(self)
        storage = machine.host.user_dir(STABLE) / "globalStorage"
        storage.mkdir()
        profiles = [
            {"name": "Work", "location": "abc"},
            {"name": "Agents", "location": "builtin/agents"},
            {"name": "Escape", "location": "../../x"},
            {"name": "Absolute", "location": "/etc"},
        ]
        (storage / "storage.json").write_text(
            json.dumps({"userDataProfiles": profiles})
        )
        found = read_profiles(machine.host.user_dir(STABLE))
        self.assertEqual([p.name for p in found], ["Work", "Agents"])

    def test_manifests_of_an_edition(self) -> None:
        """The default manifest first, then each profile's that exists."""
        machine = Machine(self)
        machine.manifest(INSIDERS, [])
        machine.manifest(INSIDERS, [], profile="Work")
        machine.manifest(INSIDERS, [], profile="Play")
        (
            machine.host.user_dir(INSIDERS)
            / "profiles"
            / "play"
            / "extensions.json"
        ).unlink()
        scopes = [m.scope for m in read_manifests(machine.host, INSIDERS)]
        self.assertEqual(scopes, ["Default", "Work"])

    def test_obsolete_lists_folders_to_delete(self) -> None:
        """Dropping names rewrites the file; dropping nothing does not."""
        machine = Machine(self)
        machine.obsolete(STABLE, "a", "b")
        obsolete = read_obsolete(machine.root(STABLE))
        self.assertEqual(obsolete.names, {"a", "b"})
        self.assertIsNone(obsolete.without({"c"}))
        self.assertEqual(obsolete.without({"a"}), b'{"b":true}')
        self.assertIsNone(read_obsolete(machine.root(INSIDERS)).raw)

    def test_location_payload_keeps_unknown_fields(self) -> None:
        """Every known path field follows; the rest is kept."""
        previous = {"$mid": 1, "path": "/a", "fsPath": "/a", "other": 1}
        location = location_payload(previous, Path("/b/c"))
        self.assertEqual(
            location,
            {
                "$mid": 1,
                "path": "/b/c",
                "fsPath": "/b/c",
                "other": 1,
                "scheme": "file",
            },
        )
        external = location_payload({"external": "x"}, Path("/b c"))
        self.assertEqual(external["external"], "file:///b%20c")


class HostTests(unittest.TestCase):
    """Where each edition keeps its files."""

    def test_locations(self) -> None:
        """macOS and Linux conventions, XDG variables honored on Linux."""
        home = Path("/home/u")
        linux = Host(Platform.LINUX, home, {"XDG_CONFIG_HOME": "/cfg"})
        darwin = Host(Platform.DARWIN, home, {"XDG_CONFIG_HOME": "/cfg"})
        self.assertEqual(
            linux.user_dir(Edition.INSIDERS),
            Path("/cfg/Code - Insiders/User"),
        )
        self.assertEqual(
            darwin.user_dir(Edition.STABLE),
            home / "Library/Application Support/Code/User",
        )
        self.assertEqual(
            linux.extensions_dir(Edition.INSIDERS),
            home / ".vscode-insiders/extensions",
        )
        self.assertEqual(darwin.state_dir(), home / ".local/state/vscode-sync")

    def test_servers_keep_their_data_below_their_root(self) -> None:
        """Extensions, profiles and builds of both server layouts."""
        machine = Machine(self)
        home = machine.home
        host = machine.host
        self.assertEqual(
            host.extensions_dir(Edition.SERVER),
            home / ".vscode-server/extensions",
        )
        self.assertEqual(
            host.user_dir(Edition.SERVER_INSIDERS),
            home / ".vscode-server-insiders/data/User",
        )
        new = machine.server(Edition.SERVER, "1.100.0")
        legacy = home / ".vscode-server/bin/abc"
        (legacy / "bin").mkdir(parents=True)
        (legacy / "product.json").write_text('{"version": "1.101.0"}')
        (legacy / "bin" / "code-server").write_text("")
        machine.server(Edition.SERVER_INSIDERS, "1.200.0")
        found = servers(host.server_builds(Edition.SERVER))
        self.assertEqual(
            [(str(s.version), s.command) for s in found],
            [
                ("1.101.0", legacy / "bin" / "code-server"),
                ("1.100.0", new),
            ],
        )

    def test_relative_variables_are_ignored(self) -> None:
        """A relative XDG directory would depend on the working directory."""
        host = Host(Platform.LINUX, Path("/h"), {"XDG_STATE_HOME": "rel"})
        self.assertEqual(host.state_home(), Path("/h/.local/state"))

    def test_home_must_be_absolute(self) -> None:
        """A relative home is refused."""
        with self.assertRaises(ValueError):
            Host(Platform.LINUX, Path("home"))


if __name__ == "__main__":
    unittest.main()
