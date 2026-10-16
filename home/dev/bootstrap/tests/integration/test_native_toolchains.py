"""Filesystem state transitions; no native installs, providers or downloads."""

import copy
import gzip
import hashlib
import io
import json
import os
import tempfile
import unittest
import zipfile
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from core import process
from core.adapters import TOOLCHAINS
from core.adapters.android import DECLINE, AndroidAdapter
from core.adapters.sdkman import SDK_SCRIPT
from core.adapters.toolchain import ToolchainAdapter
from core.engine import Bootstrap
from core.errors import BootstrapError
from core.manifest import validate_toolchains

SPECS = {
    "rust": {"version": "1.98.1"},
    "haskell": {"version": "9.14.1", "cabal": "3.16.1.0", "hls": "2.14.0.0"},
    "lean": {"version": "4.32.0"},
    "ruby": {"version": "4.0.6"},
    "jvm": {"version": "21.0.12.1", "candidate": "21.0.12+1.1-tem"},
    "kotlin": {"version": "2.4.21"},
    "maven": {"version": "3.10.0"},
    "gradle": {"version": "9.8.1"},
    "scala": {"version": "3.9.0"},
    "julia": {"version": "1.12.6"},
    "ada": {"version": "15.1.2", "gprbuild": "26.0.1"},
    "android": {
        "version": "37.0.1",
        "buildTools": "37.0.0",
        "platform": "37.2",
        "tools": "22.0",
    },
    "dotnet": {"version": "10.0.401"},
    "conda": {"version": "26.7.2"},
}
# Every declared row: one per toolchain, plus GHCup's Cabal and HLS, Alire's
# gprbuild, and the Android SDK's build tools and platform.
ROWS = len(SPECS) + 5
ACCEPTED = ("android-sdk-license",)
# The reviewed license's hash, as sdkmanager records it.
LICENSE_HASH = "24333f8a63b6825ea9c5514f83c2829b004d1fee"
# sdkmanager's package paths for the declared SDK, as component and release.
ANDROID_PACKAGES = {
    "platform-tools": ("platform-tools", "37.0.1"),
    "build-tools;37.0.0": ("build-tools", "37.0.0"),
    "platforms;android-37.2": ("platform", "37.2"),
}


class NativeTransitions(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="native-adapters-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.environment = patch.dict(
            os.environ,
            {
                "HOME": str(self.root / "home with spaces"),
                "XDG_CACHE_HOME": str(self.root / "cache"),
                "XDG_STATE_HOME": str(self.root / "state"),
                "PATH": "/usr/bin:/bin",
            },
            clear=True,
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.data = {
            "schema": 1,
            "backend": "native",
            "platform": "aarch64-darwin",
            "nativeToolchains": copy.deepcopy(SPECS),
            "node": [],
            "python": {"version": "3.14.7"},
            "ocaml": {"versions": []},
            "defaults": {
                language: spec["version"] for language, spec in SPECS.items()
            },
            "setup": {
                "managerDirectory": str(self.root / "bin"),
                "buildEnvironment": {"PATH": "/usr/bin:/bin"},
                "sdkmanShell": "/fixture/bash-5",
                "licenses": {"android-sdk-license": LICENSE_HASH},
            },
            "policy": {},
        }
        # The Android SDK's license, accepted as an apply names it.
        self.recovery = Bootstrap(self.data, list(SPECS), accepted=ACCEPTED)
        self.recovery.state.mkdir(parents=True)
        self.calls = []

    def adapter(self, language):
        return self.recovery.adapter(language)

    @property
    def roots(self):
        """Runtime roots by language, plus the separate manager homes."""
        roots = {
            language: adapter.root
            for language, adapter in self.recovery.adapters.items()
        }
        roots.update(
            cargo=self.adapter("rust").home,
            juliaup=self.adapter("julia").home,
        )
        return roots

    def selections(self):
        return self.recovery.observed_state()["globalSelections"]

    def health(self):
        return [
            row
            for adapter in self.recovery.adapters.values()
            for row in adapter.selected()
        ]

    def invocations(self, stack):
        """Record every manager invocation as (language, *arguments).

        sdkmanager also lays out the package it installs, which the adapter
        checks for afterwards.
        """
        calls = []

        def invoke(language, *args, **_):
            calls.append((language, *args))
            if language == "android" and args[:1] == ("--install",):
                self.android_package(*ANDROID_PACKAGES[args[1]])

        for language, adapter in self.recovery.adapters.items():
            stack.enter_context(
                patch.object(
                    adapter,
                    "invoke",
                    side_effect=lambda *args, language=language, **kwargs: (
                        invoke(language, *args, **kwargs)
                    ),
                )
            )
        return calls

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
        return path

    def test_runtime_only_apply_rejects_root_before_creating_state(self):
        with (
            patch("core.engine.os.geteuid", return_value=0),
            self.assertRaisesRegex(BootstrapError, "never as root"),
        ):
            self.recovery.apply([])
        self.assertFalse((self.recovery.state / "apply.lock").exists())

    def test_apply_rejects_shared_roots_and_redirected_runtime_directories(
        self,
    ):
        outside = self.root / "outside"
        outside.mkdir()
        roots = {
            name: root
            for adapter in self.recovery.adapters.values()
            for name, root in adapter.roots.items()
        }
        for name, root in roots.items():
            with self.subTest(root=name):
                root.mkdir(parents=True, exist_ok=True)
                root.chmod(0o770)
                try:
                    with self.assertRaisesRegex(
                        BootstrapError, "shared writes"
                    ):
                        self.recovery.apply([])
                finally:
                    root.chmod(0o700)
        for adapter in self.recovery.adapters.values():
            for directory in adapter.mutable_directories():
                if directory in roots.values():
                    continue
                with self.subTest(container=str(directory)):
                    directory.parent.mkdir(parents=True, exist_ok=True)
                    directory.symlink_to(outside, target_is_directory=True)
                    try:
                        with self.assertRaisesRegex(BootstrapError, "symlink"):
                            self.recovery.apply([])
                    finally:
                        directory.unlink()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.recovery.state / "apply.lock").exists())

    def test_julia_state_errors_and_binary_path_only_entries(self):
        julia = self.adapter("julia")
        directory = julia.root / "juliaup"
        directory.mkdir(parents=True)
        settings = directory / "juliaup.json"
        for payload in (
            "{",
            "[]",
            '{"InstalledVersions": []}',
            '{"InstalledChannels": {"release": null}}',
            '{"InstalledVersions": {"1.12.6": {"Path": null}}}',
        ):
            with self.subTest(payload=payload):
                settings.write_text(payload)
                with self.assertRaises(BootstrapError):
                    julia.binary("1.12.6")
        settings.write_text(
            json.dumps(
                {
                    "InstalledVersions": {
                        "1.12.6": {"BinaryPath": "runtime/bin/julia"}
                    }
                }
            )
        )
        self.assertEqual(
            julia.binary("1.12.6"), directory / "runtime/bin/julia"
        )
        # A release juliaup has not installed has no path yet: its row
        # points at the directory that will hold it.
        self.assertEqual(julia.binary("1.12.7"), directory)

    def managers(self):
        for adapter in self.recovery.adapters.values():
            self.executable(adapter.manager_candidates()[0])

    def install_fixture(self, row):
        self.calls.append((row["language"], row.get("component")))
        language = row["language"]
        if language == "julia":
            root = self.adapter(language).root / "juliaup"
            root.mkdir(parents=True, exist_ok=True)
            (root / "juliaup.json").write_text(
                json.dumps(
                    {
                        "InstalledVersions": {
                            "1.12.6+0.aarch64.apple.darwin14": {
                                "Path": "./julia-test",
                                "BinaryPath": "./julia-test/Julia-1.12.app/Contents/Resources/julia/bin/julia",
                            }
                        },
                        "InstalledChannels": {
                            "1.12.6": {
                                "Version": "1.12.6+0.aarch64.apple.darwin14"
                            }
                        },
                    }
                )
            )
        if language == "ada":
            self.alire_release(row["component"], row["version"])
        if language == "android":
            self.android_package(row["component"], row["version"])
        row["path"] = next(
            declared["path"]
            for declared in self.adapter(language).baseline()
            if declared.get("component") == row.get("component")
        )
        self.executable(Path(row["path"]))

    def alire_release(self, component, release, crate=None):
        """A toolchain release as alr deploys it, with its own metadata."""
        crate = crate or {"gnat": "gnat_native"}.get(component, component)
        prefix = self.adapter("ada").root / f"{crate}_{release}_0123abcd"
        self.executable(prefix / "bin" / component)
        (prefix / "alire.toml").write_text(
            f'name = "{crate}"\nversion = "{release}"\n'
        )
        return prefix / "bin" / component

    def android_package(self, component, version):
        """An Android SDK package as sdkmanager lays it out."""
        android = self.adapter("android")
        path = self.executable(android.package_binary(component, version))
        key = (
            "AndroidVersion.ApiLevel"
            if component == "platform"
            else "Pkg.Revision"
        )
        (path.parent / "source.properties").write_text(
            f"Pkg.UserSrc=false\n{key}={version}\n"
        )
        return path

    def alire_settings(self, **use):
        """Alire's global settings, selecting `use` per component."""
        directory = self.adapter("ada").roots["ALIRE_SETTINGS_DIR"]
        directory.mkdir(parents=True, exist_ok=True)
        lines = ["[toolchain.use]"]
        lines += [
            f'{component} = "{value}"' for component, value in use.items()
        ]
        (directory / "settings.toml").write_text("\n".join(lines) + "\n")

    def test_empty_plan_is_read_only_and_reports_all_components(self):
        with (
            patch.object(
                process,
                "run",
                side_effect=AssertionError("process launched"),
            ),
            patch(
                "urllib.request.urlopen", side_effect=AssertionError("network")
            ),
        ):
            before = sorted(self.root.rglob("*"))
            rows = self.recovery.plan()
            self.assertEqual(len(rows), ROWS)
            self.assertTrue(all(row["state"] == "blocked" for row in rows))
            self.assertEqual(before, sorted(self.root.rglob("*")))

    def test_install_missing_only_preserves_additional_versions(self):
        # Conda's manager lives in the base environment it installs, so a
        # fabricated manager alone describes a broken base (a conflict).
        self.recovery = Bootstrap(
            self.data,
            [language for language in SPECS if language != "conda"],
            accepted=ACCEPTED,
        )
        self.managers()
        extra = self.executable(self.roots["ruby"] / "versions/4.1.0/bin/ruby")
        with ExitStack() as stack:
            # Some managers stage their installation; replace every route.
            for adapter in {type(a) for a in self.recovery.adapters.values()}:
                stack.enter_context(
                    patch.object(
                        adapter, "install", side_effect=self.install_fixture
                    )
                )
            # Android verifies its own way: a floor and package metadata.
            for adapter in (ToolchainAdapter, AndroidAdapter):
                stack.enter_context(
                    patch.object(adapter, "verify", return_value="ok")
                )
            self.recovery.apply(self.recovery.plan())
            self.assertEqual(len(self.calls), ROWS - 1)
            self.recovery.apply(self.recovery.plan())
            self.assertEqual(len(self.calls), ROWS - 1)
            self.assertTrue(extra.is_file())
            self.assertEqual(
                self.recovery.observed_state()["installed"]["julia"],
                ["1.12.6+0.aarch64.apple.darwin14"],
            )

    def test_default_preservation_for_each_manager(self):
        self.managers()
        roots = self.roots
        (roots["rust"] / "settings.toml").parent.mkdir(parents=True)
        (roots["rust"] / "settings.toml").write_text(
            'default_toolchain = "stable-aarch64-apple-darwin"\n'
        )
        (roots["lean"] / "settings.toml").write_text(
            'default_toolchain = "leanprover/lean4:v4.33.1"\n'
        )
        (roots["ruby"] / "version").write_text("4.1.0\n")
        (roots["haskell"] / "bin/ghc").symlink_to("../ghc/9.16.1/bin/ghc")
        (roots["haskell"] / "bin/cabal").symlink_to("cabal-3.18.0.0")
        (roots["haskell"] / "bin/haskell-language-server-wrapper").symlink_to(
            "haskell-language-server-wrapper-2.15.0.0"
        )
        for candidate, release in (
            ("java", "25.0.4-tem"),
            ("kotlin", "2.3.21"),
            ("maven", "3.9.16"),
            ("gradle", "9.7.1"),
        ):
            current = roots["jvm"] / "candidates" / candidate / "current"
            current.parent.mkdir(parents=True)
            current.symlink_to(release)
        config = roots["julia"] / "juliaup/juliaup.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"Default":"release"}')
        self.alire_settings(
            gnat="gnat_native=14.2.1", gprbuild="gprbuild=25.0.1"
        )
        self.executable(roots["ruby"] / "shims/ruby")
        for launcher in ("scala", "scalac"):
            self.executable(self.adapter("scala").home / launcher)
        before = self.selections()
        with ExitStack() as stack:
            calls = self.invocations(stack)
            for adapter in self.recovery.adapters.values():
                adapter.initialize_default()
                adapter.repair_hooks()
        self.assertEqual(calls, [])
        self.assertEqual(before, self.selections())

    def test_health_accepts_older_selections_and_reports_system_ruby(self):
        self.managers()
        roots = self.roots
        older = {
            "rust": ("1.90.0", "toolchains/1.90.0-aarch64-apple-darwin"),
            "lean": ("4.20.0", "toolchains/leanprover--lean4---v4.20.0"),
            "haskell": ("9.12.2", "ghc/9.12.2"),
            "jvm": ("17.0.12", "candidates/java/17.0.12-tem"),
            "kotlin": ("2.3.21", "candidates/kotlin/2.3.21"),
            "maven": ("3.9.16", "candidates/maven/3.9.16"),
            "gradle": ("9.7.1", "candidates/gradle/9.7.1"),
            "scala": (
                "3.8.1",
                "https/github.com/scala/scala3/releases/download/3.8.1/"
                "scala3-3.8.1-aarch64-apple-darwin.tar.gz/"
                "scala3-3.8.1-aarch64-apple-darwin",
            ),
            "julia": ("1.10.9", "juliaup/julia-1.10.9"),
            # Alire's directories carry a hash; alire_release lays them out.
            "ada": ("14.2.1", None),
            # adb is the selection, older than the declared floor.
            "android": ("36.0.0", None),
            # The muxer itself is the selection; it runs the newest SDK.
            "dotnet": ("9.0.318", None),
            # Conda's base environment evolves in place.
            "conda": ("26.3.2", None),
        }
        commands = {
            "rust": "rustc",
            "lean": "lean",
            "haskell": "ghc",
            "jvm": "java",
            "kotlin": "kotlin",
            "maven": "mvn",
            "gradle": "gradle",
            "scala": "scalac",
            "julia": "julia",
        }
        for language, (_, prefix) in older.items():
            if prefix:
                self.executable(
                    roots[language] / prefix / "bin" / commands[language]
                )
        (roots["rust"] / "settings.toml").write_text(
            'default_toolchain = "1.90.0-aarch64-apple-darwin"\n'
        )
        (roots["lean"] / "settings.toml").write_text(
            'default_toolchain = "leanprover/lean4:v4.20.0"\n'
        )
        (roots["haskell"] / "bin/ghc").symlink_to("../ghc/9.12.2/bin/ghc")
        self.executable(roots["haskell"] / "bin/cabal")
        self.executable(
            roots["haskell"] / "bin/haskell-language-server-wrapper"
        )
        for language in ("jvm", "kotlin", "maven", "gradle"):
            prefix = roots[language] / older[language][1]
            (prefix.parent / "current").symlink_to(prefix.name)
        (roots["julia"] / "juliaup/juliaup.json").write_text(
            json.dumps(
                {
                    "Default": "1.10",
                    "InstalledChannels": {"1.10": {"Version": "1.10.9+0"}},
                    "InstalledVersions": {
                        "1.10.9+0": {
                            "Path": "./julia-1.10.9",
                            "BinaryPath": "./julia-1.10.9/bin/julia",
                        }
                    },
                }
            )
        )
        self.android_package("platform-tools", "36.0.0")
        self.alire_release("gnat", "14.2.1")
        self.alire_release("gprbuild", "25.0.1")
        self.alire_settings(
            gnat="gnat_native=14.2.1", gprbuild="gprbuild=25.0.1"
        )
        (roots["ruby"] / "version").write_text("system\n")
        self.executable(roots["conda"] / "bin/python")
        # Coursier's launcher runs the older distribution it was installed for.
        scala = roots["scala"] / older["scala"][1] / "bin/scala"
        (self.adapter("scala").home / "scala").write_bytes(
            f'#!/usr/bin/env sh\nexec "{scala}" "$@"\n'.encode()
            + b"PK\x03\x04 appended app descriptor"
        )
        rows = {
            (row["language"], row.get("component")): row
            for row in self.health()
        }
        ruby = rows.pop(("ruby", None))
        self.assertEqual((ruby["state"], ruby["path"]), ("external", ""))
        # The selected build tools: GHCup's links, Alire's settings.
        tools = {"haskell": "2.15.0.0", "ada": "25.0.1"}
        for (language, component), row in rows.items():
            release = tools[language] if component else older[language][0]
            with (
                self.subTest(language=language, component=component),
                patch.object(process, "run", return_value=release),
                patch.object(type(self.adapter(language)), "canary"),
            ):
                self.assertEqual(row["state"], "present")
                self.assertEqual(
                    self.recovery.verify(row, exact=False), release
                )
                with self.assertRaisesRegex(
                    BootstrapError, "identity mismatch"
                ):
                    self.recovery.verify(row)

    def test_compiled_runtimes_name_their_rebuild_command(self):
        # A failing canary is a conflict; only a runtime compiled against
        # host libraries carries the manager command that rebuilds it.
        self.managers()
        rows = []
        for language, relative, remedy in (
            (
                "ruby",
                "versions/3.4.1/bin/ruby",
                "rbenv install --force 3.4.1",
            ),
            ("rust", "toolchains/1.90.0-aarch64-apple-darwin/bin/rustc", None),
        ):
            path = self.executable(self.adapter(language).root / relative)
            rows.append(
                (
                    self.adapter(language).row("1.0.0", path, state="present"),
                    remedy,
                )
            )
        with patch.object(process, "run", return_value="3.4.1 1.90.0"):
            self.recovery.qualify([row for row, _ in rows], exact=False)
        for row, remedy in rows:
            with self.subTest(language=row["language"]):
                self.assertEqual(row["state"], "conflict")
                self.assertIn("canary failed", row["reason"])
                self.assertEqual(row.get("remediation"), remedy)

    def test_only_a_prefix_inside_its_root_can_be_discarded(self):
        # Miniforge's runtime prefix is its whole root: never journaled.
        conda = self.adapter("conda")
        self.assertIsNone(conda.owned_prefix(conda.baseline()[0]))
        rust = self.adapter("rust")
        row = rust.baseline()[0]
        prefix = rust.owned_prefix(row)
        self.assertEqual(prefix, Path(row["path"]).parents[1])
        prefix.parent.mkdir(parents=True)
        target = self.root / "elsewhere"
        target.mkdir()
        prefix.symlink_to(target)
        with self.assertRaisesRegex(BootstrapError, "not a directory"):
            rust.discard(prefix)
        self.assertTrue(target.is_dir())

    def test_initial_defaults_use_literal_manager_commands(self):
        with ExitStack() as stack:
            calls = self.invocations(stack)
            for adapter in self.recovery.adapters.values():
                adapter.initialize_default()
        # The .NET muxer runs the newest SDK, conda's base environment is
        # the only global one and Android projects name their packages;
        # nothing records a selection.
        unselected = {"dotnet", "conda", "android"}
        for language in TOOLCHAINS:
            with self.subTest(language=language):
                self.assertEqual(
                    any(call[0] == language for call in calls),
                    language not in unselected,
                )
        for expected in (
            ("jvm", "default", "java", "21.0.12+1.1-tem"),
            ("kotlin", "default", "kotlin", "2.4.21"),
            ("maven", "default", "maven", "3.10.0"),
            ("gradle", "default", "gradle", "9.8.1"),
            ("haskell", "set", "cabal", "3.16.1.0"),
            ("haskell", "set", "hls", "2.14.0.0"),
            (
                "ada",
                "toolchain",
                "--select",
                "gnat_native=15.1.2",
                "gprbuild=26.0.1",
            ),
        ):
            with self.subTest(command=expected):
                self.assertIn(expected, calls)
        launchers = str(self.adapter("scala").home)
        for name in ("scala", "scalac"):
            with self.subTest(launcher=name):
                self.assertIn(
                    ("scala", "install", "--install-dir", launchers)
                    + (f"{name}:3.9.0",),
                    calls,
                )

    def test_install_contracts_do_not_reset_default(self):
        with ExitStack() as stack:
            calls = self.invocations(stack)
            # dotnet-install is the installer and runs without a manager.
            installer = stack.enter_context(
                patch.object(self.adapter("dotnet"), "run_installer")
            )
            for row in self.recovery.plan():
                if row["language"] == "conda":
                    # Acquisition installs the base environment.
                    with self.assertRaisesRegex(BootstrapError, "installer"):
                        self.adapter("conda").install(row)
                    continue
                self.adapter(row["language"]).install(row)
        installer.assert_called_once_with()
        for expected in (
            ("haskell", "install", "ghc", "9.14.1", "--no-set"),
            ("haskell", "install", "cabal", "3.16.1.0", "--no-set"),
            ("haskell", "install", "hls", "2.14.0.0", "--no-set"),
            ("lean", "toolchain", "install", "leanprover/lean4:v4.32.0"),
            ("jvm", "install", "java", "21.0.12+1.1-tem"),
            ("kotlin", "install", "kotlin", "2.4.21"),
            ("maven", "install", "maven", "3.10.0"),
            ("gradle", "install", "gradle", "9.8.1"),
            # Inside a throwaway crate, so only that crate records it.
            ("ada", "toolchain", "--select", "--local", "gnat_native=15.1.2"),
            ("ada", "toolchain", "--select", "--local", "gprbuild=26.0.1"),
            ("android", "--install", "platform-tools"),
            ("android", "--install", "build-tools;37.0.0"),
            ("android", "--install", "platforms;android-37.2"),
        ):
            with self.subTest(command=expected):
                self.assertIn(expected, calls)
        self.assertTrue(all("default" not in call[1:3] for call in calls))
        self.assertFalse(
            any(
                call[1:3] == ("toolchain", "--select")
                and "--local" not in call
                for call in calls
            )
        )
        # Coursier fills its archive cache from a discarded staging directory,
        # so the user's launchers, its global selection, stay untouched.
        (scala,) = [call for call in calls if call[0] == "scala"]
        self.assertEqual(
            scala[1:3] + scala[4:], ("install", "--install-dir", "scala:3.9.0")
        )
        staging = Path(scala[3])
        self.assertEqual(staging.parent, self.recovery.state)
        self.assertFalse(staging.exists())
        self.assertFalse(self.adapter("scala").home.exists())

    def test_direct_verification_rejects_proxy_and_version_mismatch(self):
        self.managers()
        for row in self.recovery.plan():
            self.install_fixture(row)
            with self.subTest(
                language=row["language"], component=row.get("component")
            ):
                with (
                    patch.object(
                        process, "run", return_value=row["version"]
                    ) as runner,
                    patch.object(
                        type(self.adapter(row["language"])), "canary"
                    ),
                ):
                    self.assertEqual(self.recovery.verify(row), row["version"])
                    if row["language"] in ("ada", "android"):
                        # The package's own metadata, not the binary.
                        runner.assert_not_called()
                    else:
                        # An installed .NET SDK runs through its muxer.
                        executable = (
                            str(self.adapter("dotnet").manager())
                            if row["language"] == "dotnet"
                            else row["path"]
                        )
                        self.assertEqual(
                            runner.call_args.args[0][0], executable
                        )
                if row["language"] == "ada":
                    metadata = Path(row["path"]).parents[1] / "alire.toml"
                    metadata.write_text('version = "0.0.1"\n')
                if row["language"] == "android":
                    metadata = Path(row["path"]).parent / "source.properties"
                    metadata.write_text(
                        "Pkg.Revision=0.0.1\nAndroidVersion.ApiLevel=0.0.1\n"
                    )
                with (
                    patch.object(process, "run", return_value="0.0.1"),
                    self.assertRaisesRegex(
                        BootstrapError, "identity mismatch"
                    ),
                ):
                    self.recovery.verify(row)
        lean = self.adapter("lean")
        path = lean.binary()
        path.unlink()
        path.symlink_to(lean.manager())
        with self.assertRaisesRegex(BootstrapError, "download-capable"):
            self.recovery.verify(
                {"language": "lean", "path": str(path), "version": "4.32.0"}
            )

    def test_installer_hash_failure_never_executes(self):
        self.data["setup"]["installers"] = {
            "lean": {
                "url": "https://example.invalid/installer",
                "sha256": "0" * 64,
            }
        }
        with (
            patch(
                "urllib.request.urlopen", return_value=io.BytesIO(b"changed")
            ),
            patch.object(process, "run") as runner,
        ):
            with self.assertRaisesRegex(BootstrapError, "checksum/size"):
                self.adapter("lean").acquire()
            runner.assert_not_called()

    def test_release_installers_match_their_exact_size(self):
        payload = b"release asset fixture"
        compressed = gzip.compress(payload)
        lean = self.adapter("lean")
        for label, body, size, accepted, name in (
            ("exact", payload, len(payload), True, "Miniforge3-0-Linux.sh"),
            ("longer", payload + b"!", len(payload), False, "asset"),
            ("shorter", payload[:-1], len(payload), False, "asset"),
            ("gzip", compressed, len(compressed), True, "cs-x86_64.gz"),
            ("endpoint", payload, len(payload), True, ""),
        ):
            recipe = {
                "url": f"https://example.invalid/{name}",
                "sha256": hashlib.sha256(body[:size]).hexdigest(),
                "size": size,
                "shell": "/bin/sh",
                "arguments": [],
            }
            if label == "gzip":
                recipe["format"] = "gzip"
            self.data["setup"]["installers"] = {"lean": recipe}
            received = []

            def install(recipe, path, directory, received=received):
                received.append((Path(path).name, Path(path).read_bytes()))

            with (
                self.subTest(case=label),
                patch("urllib.request.urlopen", return_value=io.BytesIO(body)),
                patch.object(lean, "install_manager", side_effect=install),
            ):
                if accepted:
                    lean.run_installer()
                    # Installers may check their own file name.
                    expected = {"gzip": "cs-x86_64", "endpoint": "installer"}
                    self.assertEqual(
                        received, [(expected.get(label, name), payload)]
                    )
                else:
                    with self.assertRaisesRegex(
                        BootstrapError, "checksum/size"
                    ):
                        lean.run_installer()
                    self.assertEqual(received, [])

    def test_installer_declarations_reject_bad_sizes_and_formats(self):
        valid = {
            "url": "https://example.invalid/asset",
            "sha256": "0" * 64,
            "size": 1,
        }
        validate_toolchains(
            dict(self.data, setup={"installers": {"lean": valid}})
        )
        for field, value in (
            ("size", 0),
            ("size", True),
            ("size", "12"),
            ("format", "zip"),
        ):
            with (
                self.subTest(field=field, value=value),
                self.assertRaises(BootstrapError),
            ):
                validate_toolchains(
                    dict(
                        self.data,
                        setup={
                            "installers": {"lean": {**valid, field: value}}
                        },
                    )
                )

    def test_julia_existing_selection_blocks_manager_reinstallation(self):
        self.data["setup"]["installers"] = {
            "julia": {"url": "https://example.invalid/installer"}
        }
        julia = self.adapter("julia")
        config = julia.root / "juliaup/juliaup.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"Default":"release"}')
        with (
            patch(
                "urllib.request.urlopen", side_effect=AssertionError("network")
            ),
            self.assertRaisesRegex(BootstrapError, "existing Julia selection"),
        ):
            julia.acquire()

    def test_unrelated_roots_do_not_break_scoped_commands(self):
        for language in TOOLCHAINS:
            with (
                self.subTest(language=language),
                patch.dict(
                    os.environ,
                    {
                        "ELAN_HOME": "relative",
                        "GHCUP_INSTALL_BASE_PREFIX": "relative",
                    },
                ),
            ):
                recovery = Bootstrap(self.data, ["node"])
                self.assertEqual(list(recovery.adapters), ["node"])

    def test_sdkman_uses_fixed_bash_program_and_neutral_directory(self):
        self.managers()
        with patch.object(process, "run", return_value="") as runner:
            self.adapter("jvm").invoke("install", "java", "21.0.12+1.1-tem")
        args = runner.call_args.args[0]
        self.assertEqual(
            args[:5],
            ["/fixture/bash-5", "--noprofile", "--norc", "-c", SDK_SCRIPT],
        )
        self.assertEqual(args[-3:], ["install", "java", "21.0.12+1.1-tem"])
        self.assertEqual(runner.call_args.kwargs["cwd"], "/")
        self.assertIn("USE=n", SDK_SCRIPT)
        self.assertIn('sdk "$@" <<< n', SDK_SCRIPT)

    def test_verified_installer_runs_once_and_receives_literal_roots(self):
        payload = b"verified installer fixture"
        for language in (
            "rust",
            "haskell",
            "lean",
            "jvm",
            "julia",
            "dotnet",
            "conda",
        ):
            with self.subTest(language=language):
                adapter = self.adapter(language)
                root = adapter.home
                manager = adapter.manager_candidates()[0]
                self.data["setup"]["installers"] = {
                    language: {
                        "url": "https://example.invalid/installer",
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "shell": "/bin/sh",
                        "arguments": ["--path", str(root), "{version}"],
                    }
                }

                def install(
                    args,
                    *,
                    root=root,
                    language=language,
                    manager=manager,
                    **kwargs,
                ):
                    self.assertEqual(
                        args[-3:],
                        ["--path", str(root), SPECS[language]["version"]],
                    )
                    self.assertTrue(kwargs["source_build"])
                    self.executable(manager)

                with (
                    patch(
                        "urllib.request.urlopen",
                        return_value=io.BytesIO(payload),
                    ) as fetch,
                    patch.object(
                        process, "run", side_effect=install
                    ) as runner,
                ):
                    adapter.acquire()
                    adapter.acquire()
                    self.assertEqual(fetch.call_count, 1)
                    self.assertEqual(runner.call_count, 1)

    def test_rust_paths_follow_declared_platform(self):
        for platform, host in (
            ("aarch64-darwin", "aarch64-apple-darwin"),
            ("x86_64-linux", "x86_64-unknown-linux-gnu"),
        ):
            with self.subTest(platform=platform):
                self.data["platform"] = platform
                path = self.adapter("rust").binary()
                self.assertEqual(path.parent.parent.name, "1.98.1-" + host)

    def test_sdkman_candidate_and_jdk_patch_identity_are_distinct(self):
        validate_toolchains(self.data)
        self.managers()
        row = next(
            row for row in self.recovery.plan() if row["language"] == "jvm"
        )
        self.install_fixture(row)
        self.assertIn("21.0.12+1.1-tem", row["path"])
        with (
            patch.object(
                process,
                "run",
                return_value="openjdk 21.0.12.1 2026-07-21 LTS",
            ),
            patch.object(ToolchainAdapter, "canary"),
        ):
            self.assertEqual(self.recovery.verify(row), "21.0.12.1")
            with self.assertRaisesRegex(BootstrapError, "identity mismatch"):
                self.recovery.verify(dict(row, version="21.0.12"))

    def test_sdkman_tools_run_on_the_declared_jdk(self):
        self.managers()
        java = self.executable(self.adapter("jvm").binary())
        self.executable(java.parent / "javac")
        java_home = java.parent.parent.resolve()
        calls = []

        def run(args, **kwargs):
            args = [str(arg) for arg in args]
            calls.append((args, kwargs))
            name = Path(args[0]).name
            if name == "mvn":
                return f"Apache Maven 3.10.0 (fixture)\nruntime: {java_home}"
            if name == "gradle" and "--version" in args:
                return "Gradle 9.8.1"
            if name == "kotlin" and "-version" in args:
                return "Kotlin version 2.4.21 (JRE 21.0.12.1+1-LTS)"
            return "" if name == "kotlinc" else "bootstrap-ok"

        for language in ("kotlin", "maven", "gradle"):
            adapter = self.adapter(language)
            path = self.executable(adapter.binary())
            if language == "kotlin":
                self.executable(path.parent / "kotlinc")
            row = {
                "language": language,
                "version": SPECS[language]["version"],
                "path": str(path),
            }
            with (
                self.subTest(language=language),
                patch.object(process, "run", side_effect=run),
            ):
                self.assertEqual(self.recovery.verify(row), row["version"])
        for args, kwargs in calls:
            self.assertEqual(kwargs["env"]["JAVA_HOME"], str(java_home))
            self.assertTrue(kwargs["source_build"])
            if Path(args[0]).name == "mvn":
                self.assertEqual(kwargs["env"]["MAVEN_SKIP_RC"], "1")
        programs = [[Path(arg).name for arg in args] for args, _ in calls]
        self.assertIn(["kotlinc", "Main.kt", "-d", "classes"], programs)
        self.assertIn(["kotlin", "-cp", "classes", "MainKt"], programs)
        # Gradle state goes to scratch homes, never to the real ~/.gradle.
        gradle = [(a, kw) for a, kw in calls if Path(a[0]).name == "gradle"]
        self.assertNotEqual(
            Path(gradle[0][1]["env"]["GRADLE_USER_HOME"]).parent, Path.home()
        )
        canary = gradle[1][0]
        for flag in ("--no-daemon", "--offline", "--gradle-user-home"):
            self.assertIn(flag, canary)
        self.assertFalse((Path.home() / ".gradle").exists())
        # Maven must start on the JDK it was given.
        maven = self.adapter("maven")
        row = {
            "language": "maven",
            "version": "3.10.0",
            "path": str(maven.binary()),
        }
        with (
            patch.object(
                process,
                "run",
                return_value="Apache Maven 3.10.0\nruntime: /elsewhere",
            ),
            self.assertRaisesRegex(BootstrapError, "canary failed"),
        ):
            self.recovery.verify(row)
        java.unlink()
        with self.assertRaisesRegex(BootstrapError, "needs an SDKMAN JDK"):
            self.recovery.verify(row)

    def test_coursier_launcher_is_placed_without_running_it(self):
        launcher = b"\x7fELF native cs fixture"
        asset = gzip.compress(launcher)
        scala = self.adapter("scala")
        # Other applications' launchers do not make the directory occupied.
        self.executable(scala.home / "sbt")
        self.data["setup"]["installers"] = {
            "scala": {
                "url": "https://example.invalid/cs.gz",
                "sha256": hashlib.sha256(asset).hexdigest(),
                "size": len(asset),
                "format": "gzip",
            }
        }
        with (
            patch(
                "urllib.request.urlopen", return_value=io.BytesIO(asset)
            ) as fetch,
            patch.object(process, "run") as runner,
        ):
            scala.acquire()
            scala.acquire()
        manager = scala.home / "cs"
        self.assertEqual(manager.read_bytes(), launcher)
        self.assertTrue(os.access(manager, os.X_OK))
        self.assertEqual(fetch.call_count, 1)
        runner.assert_not_called()
        self.assertEqual(scala.manager(), manager)

    def test_coursier_roots_follow_the_platform_defaults(self):
        # Roots are resolved, as the temporary directory may be a link.
        home = Path.home().resolve()
        for platform, binaries, cache in (
            (
                "aarch64-darwin",
                home / "Library/Application Support/Coursier/bin",
                home / "Library/Caches/Coursier/v1",
            ),
            (
                "x86_64-linux",
                home / ".local/share/coursier/bin",
                self.root.resolve() / "cache/coursier/v1",
            ),
        ):
            with self.subTest(platform=platform):
                self.data["platform"] = platform
                roots = (
                    Bootstrap(self.data, ["jvm", "scala"])
                    .adapter("scala")
                    .roots
                )
                self.assertEqual(
                    roots,
                    {
                        "COURSIER_ARCHIVE_CACHE": home
                        / ".local/share/coursier/arc",
                        "COURSIER_BIN_DIR": binaries,
                        "COURSIER_CACHE": cache,
                    },
                )

    def test_scala_selection_is_the_prebuilt_launcher_target(self):
        self.managers()
        scala = self.adapter("scala")
        self.assertIsNone(scala.selection())
        distribution = self.executable(scala.binary("3.9.1")).parent
        launcher = scala.home / "scala"
        launcher.write_bytes(
            f'#!/usr/bin/env sh\nexec "{distribution / "scala"}" "$@"\n'.encode()
            + b"PK\x03\x04 appended app descriptor"
        )
        self.assertEqual(scala.selection(), str(distribution / "scala"))
        (row,) = scala.selected()
        self.assertEqual(
            (row["state"], row["path"]),
            ("present", str(distribution / "scalac")),
        )
        # A JVM bootstrap launcher may download on start; it is reported,
        # never executed.
        launcher.write_bytes(b"#!/usr/bin/env sh\nnargs=$#\nPK\x03\x04")
        (row,) = scala.selected()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("prebuilt Scala distribution", row["reason"])

    def test_scala_canary_compiles_and_runs_on_the_declared_jdk(self):
        self.managers()
        java = self.executable(self.adapter("jvm").binary())
        scala = self.adapter("scala")
        compiler = self.executable(scala.binary())
        library = compiler.parent.parent / "lib/scala.jar"
        library.parent.mkdir()
        library.write_bytes(b"manifest-only jar")
        calls = []

        def run(args, **kwargs):
            args = [str(arg) for arg in args]
            calls.append((args, kwargs))
            if "-version" in args:
                return "Scala compiler version 3.9.0 -- Copyright"
            return "bootstrap-ok" if Path(args[0]) == java else ""

        row = {"language": "scala", "version": "3.9.0", "path": str(compiler)}
        with patch.object(process, "run", side_effect=run):
            self.assertEqual(self.recovery.verify(row), "3.9.0")
        compile_args, run_args = calls[1][0], calls[2][0]
        self.assertEqual(
            [Path(arg).name for arg in compile_args],
            ["scalac", "-d", "classes", "Main.scala"],
        )
        self.assertEqual(run_args[0], str(java))
        self.assertTrue(run_args[2].endswith(os.pathsep + str(library)))
        self.assertEqual(run_args[3], "canary")
        for _, kwargs in calls:
            self.assertEqual(
                kwargs["env"]["JAVA_HOME"], str(java.parent.parent.resolve())
            )

    def test_dotnet_root_shares_the_cli_user_directory(self):
        dotnet = self.adapter("dotnet")
        self.data["setup"]["installers"] = {
            "dotnet": {"url": "https://example.invalid/dotnet-install.sh"}
        }
        # Global tools and first-use sentinels do not block acquisition.
        self.executable(dotnet.root / "tools/csharp-ls")
        (dotnet.root / "10.0.201.dotnetFirstUseSentinel").touch()
        muxer = dotnet.manager_candidates()[0]
        with patch.object(
            dotnet, "run_installer", side_effect=lambda: self.executable(muxer)
        ) as installer:
            dotnet.acquire()
        installer.assert_called_once_with()
        # An installation layout without its muxer needs inspection.
        muxer.unlink()
        (dotnet.root / "sdk").mkdir()
        with (
            patch.object(dotnet, "run_installer") as installer,
            self.assertRaisesRegex(BootstrapError, "Inspect incomplete"),
        ):
            dotnet.acquire()
        installer.assert_not_called()

    def test_dotnet_pins_the_sdk_and_builds_offline(self):
        self.managers()
        dotnet = self.adapter("dotnet")
        muxer = dotnet.manager()
        sdk = self.executable(dotnet.binary())
        calls = []

        def run(args, *, cwd, env, **kwargs):
            work = Path(cwd)
            pin = work / "global.json"
            calls.append(
                {
                    "args": [str(arg) for arg in args],
                    "env": env,
                    "work": work,
                    "pin": json.loads(pin.read_text())
                    if pin.exists()
                    else None,
                    "files": {
                        path.name: path.read_text()
                        for path in work.iterdir()
                        if path.is_file() and path.name != "global.json"
                    },
                }
            )
            if args[-1] == "--version":
                return "10.0.401"
            return "bootstrap-ok" if str(args[-1]).endswith(".dll") else ""

        row = {"language": "dotnet", "version": "10.0.401", "path": str(sdk)}
        with patch.object(process, "run", side_effect=run):
            self.assertEqual(self.recovery.verify(row), "10.0.401")
        self.assertEqual(
            [call["args"][1:] for call in calls][:3],
            [["--version"], ["--version"], calls[2]["args"][1:]],
        )
        build = calls[2]["args"]
        self.assertEqual(build[1], "build")
        self.assertIn("-p:UseSharedCompilation=false", build)
        self.assertEqual(Path(calls[3]["args"][1]).name, "canary.dll")
        for call in calls:
            self.assertEqual(call["args"][0], str(muxer))
            # The SDK under test is selected the way a project selects one.
            self.assertEqual(
                call["pin"],
                {"sdk": {"version": "10.0.401", "rollForward": "disable"}},
            )
            self.assertEqual(call["env"]["DOTNET_CLI_TELEMETRY_OPTOUT"], "1")
            # CLI and NuGet state stay in scratch, not the real home.
            self.assertEqual(call["env"]["HOME"], str(call["work"]))
            self.assertEqual(call["env"]["DOTNET_CLI_HOME"], str(call["work"]))
        files = calls[2]["files"]
        self.assertIn(
            "<TargetFramework>net10.0</TargetFramework>",
            files["canary.csproj"],
        )
        self.assertIn("<clear />", files["nuget.config"])
        # Health runs the muxer as a shell would: the newest SDK, no pin.
        calls.clear()
        (selected,) = dotnet.selected()
        self.assertEqual(
            (selected["state"], selected["path"]), ("present", str(muxer))
        )
        with patch.object(process, "run", side_effect=run):
            self.assertEqual(
                self.recovery.verify(selected, exact=False), "10.0.401"
            )
        self.assertTrue(all(call["pin"] is None for call in calls))
        self.assertIsNone(dotnet.selection())
        with patch.object(dotnet, "invoke") as invoke:
            dotnet.initialize_default()
        invoke.assert_not_called()

    def test_conda_base_reports_through_its_interpreter(self):
        self.managers()
        conda = self.adapter("conda")
        python = self.executable(conda.binary())
        calls = []

        def run(args, **kwargs):
            calls.append([str(arg) for arg in args])
            return "26.7.2" if "__version__" in args[-1] else "bootstrap-ok"

        row = {"language": "conda", "version": "26.7.2", "path": str(python)}
        with patch.object(process, "run", side_effect=run):
            self.assertEqual(self.recovery.verify(row), "26.7.2")
        # The conda CLI, which can reach the network, never runs.
        self.assertTrue(all(call[0] == str(python) for call in calls))
        self.assertTrue(all(call[1] == "-I" for call in calls))
        (selected,) = conda.selected()
        self.assertEqual(
            (selected["state"], selected["path"]), ("present", str(python))
        )
        self.assertIsNone(conda.selection())
        with patch.object(conda, "invoke") as invoke:
            conda.initialize_default()
        invoke.assert_not_called()
        # A prefix without its interpreter needs inspection, not a reinstall.
        python.unlink()
        (row,) = conda.plan()
        self.assertEqual(row["state"], "conflict")

    def test_hls_must_serve_the_declared_ghc(self):
        self.managers()
        haskell = self.adapter("haskell")
        hls = next(
            row for row in haskell.plan() if row.get("component") == "hls"
        )
        self.assertEqual(hls["state"], "missing")
        self.assertTrue(
            hls["path"].endswith(
                "hls/2.14.0.0/bin/haskell-language-server-9.14.1"
            )
        )
        # The release is installed but serves other compilers only.
        self.executable(
            Path(hls["path"]).with_name("haskell-language-server-9.12.2")
        )
        conflict = next(
            row for row in haskell.plan() if row.get("component") == "hls"
        )
        self.assertEqual(conflict["state"], "conflict")
        self.assertIn("no server for GHC 9.14.1", conflict["reason"])
        self.executable(Path(hls["path"]))
        for compiler, supported in (("9.14.1", True), ("9.12.2", False)):

            def run(args, compiler=compiler, **kwargs):
                self.assertEqual(
                    kwargs["env"]["GHC_BIN"], str(haskell.binary())
                )
                if "--numeric-version" in args:
                    return "2.14.0.0"
                return (
                    "haskell-language-server version: 2.14.0.0 "
                    f"(GHC: {compiler}) (PATH: fixture)"
                )

            with (
                self.subTest(compiler=compiler),
                patch.object(process, "run", side_effect=run),
            ):
                if supported:
                    self.assertEqual(self.recovery.verify(hls), "2.14.0.0")
                else:
                    with self.assertRaisesRegex(
                        BootstrapError, "canary failed"
                    ):
                        self.recovery.verify(hls)

    def test_dangling_selectors_do_not_authorize_default_replacement(self):
        for language in ("rust", "lean"):
            with self.subTest(language=language):
                adapter = self.adapter(language)
                adapter.root.mkdir(parents=True)
                (adapter.root / "settings.toml").symlink_to("missing-settings")
                with (
                    patch.object(adapter, "invoke") as invoke,
                    self.assertRaisesRegex(BootstrapError, "selector file"),
                ):
                    adapter.initialize_default()
                invoke.assert_not_called()

    def test_alire_installs_in_a_throwaway_crate_without_selecting(self):
        self.managers()
        ada = self.adapter("ada")
        calls = []

        def run(args, **kwargs):
            calls.append((args, kwargs))
            return ""

        with patch.object(process, "run", side_effect=run):
            for row in ada.baseline():
                ada.install(row)
        manager = str(ada.manager())
        switches = [manager, "-n", "--no-color", "--no-tty"]
        (init, gnat), (_, gprbuild) = calls[:2], calls[2:]
        self.assertEqual(
            init[0],
            [*switches, "init", "--bin", "--no-skel", "bootstrap_seed"],
        )
        work = Path(init[1]["cwd"])
        self.assertEqual(work.parent, self.recovery.state)
        self.assertFalse(work.exists())
        self.assertEqual(
            gnat[0],
            [
                *switches,
                "toolchain",
                "--select",
                "--local",
                "gnat_native=15.1.2",
            ],
        )
        self.assertEqual(gnat[1]["cwd"], str(work / "bootstrap_seed"))
        self.assertEqual(gprbuild[0][-1], "gprbuild=26.0.1")
        environment = gnat[1]["env"]
        self.assertEqual(
            Path(environment["XDG_CONFIG_HOME"]) / "alire",
            ada.roots["ALIRE_SETTINGS_DIR"],
        )
        self.assertNotIn("ALIRE_SETTINGS_DIR", environment)
        self.assertTrue(gnat[1]["source_build"])
        self.assertFalse(
            (ada.roots["ALIRE_SETTINGS_DIR"] / "settings.toml").exists()
        )

    def test_alire_roots_follow_its_settings_and_data_home(self):
        ada = self.adapter("ada")
        # Roots are resolved; the temporary directory may sit behind a link.
        home = Path(os.environ["HOME"]).resolve()
        self.assertEqual(ada.root, home / ".local/share/alire/toolchains")
        self.assertEqual(
            ada.roots["ALIRE_SETTINGS_DIR"], home / ".config/alire"
        )
        moved = self.root.resolve() / "moved"
        with patch.dict(
            os.environ,
            {
                "XDG_DATA_HOME": str(moved / "data"),
                "ALIRE_SETTINGS_DIR": str(moved / "settings"),
            },
        ):
            # An explicit settings directory holds the cache too, as alr's.
            ada = Bootstrap(self.data, ["ada"]).adapter("ada")
            self.assertEqual(ada.root, moved / "settings/cache/toolchains")
            self.assertEqual(
                ada.environment()["ALIRE_SETTINGS_DIR"],
                str(moved / "settings"),
            )
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(moved / "data")}):
            ada = Bootstrap(self.data, ["ada"]).adapter("ada")
            self.assertEqual(ada.root, moved / "data/alire/toolchains")
            self.assertEqual(
                ada.environment(),
                {
                    "XDG_CONFIG_HOME": str(home / ".config"),
                    "XDG_DATA_HOME": str(moved / "data"),
                    "ALR_HOME": str(home / ".ada"),
                },
            )
        with patch.dict(
            os.environ,
            {
                "XDG_DATA_HOME": str(moved / "data"),
                "ALIRE_SETTINGS_DIR": str(moved / "settings"),
            },
        ):
            settings = moved / "settings/settings.toml"
            settings.parent.mkdir(parents=True)
            settings.write_text(f'[cache]\ndir = "{moved / "cache"}"\n')
            ada = Bootstrap(self.data, ["ada"]).adapter("ada")
            self.assertEqual(ada.root, moved / "cache/toolchains")
            settings.write_text(
                f'[toolchain]\ndir = "{moved / "toolchains"}"\n'
            )
            ada = Bootstrap(self.data, ["ada"]).adapter("ada")
            self.assertEqual(ada.root, moved / "toolchains")
            settings.write_text('[toolchain]\ndir = "relative"\n')
            with self.assertRaisesRegex(BootstrapError, "must be absolute"):
                Bootstrap(self.data, ["ada"])
            settings.write_text("[toolchain\n")
            with self.assertRaisesRegex(BootstrapError, "Alire settings"):
                Bootstrap(self.data, ["ada"])

    def test_alire_selections_name_crates_and_external_tools(self):
        self.managers()
        ada = self.adapter("ada")
        gnat = self.alire_release("gnat", "14.2.1")
        self.alire_release("gnat", "15.1.2", crate="gnat_arm_elf")
        self.alire_settings(
            gnat="gnat_native=14.2.1", gprbuild="gprbuild_external=25.0.1"
        )
        self.assertEqual(ada.selection(), "gnat_native=14.2.1")
        gnat_row, gprbuild_row = ada.selected()
        self.assertEqual(
            (gnat_row["state"], gnat_row["path"]), ("present", str(gnat))
        )
        self.assertEqual(gprbuild_row["state"], "external")
        self.assertEqual(
            ada.installed(), ["gnat_arm_elf=15.1.2", "gnat_native=14.2.1"]
        )
        self.alire_settings(gnat="gnat_external=13.2.0")
        gnat_row, gprbuild_row = ada.selected()
        self.assertEqual(gnat_row["state"], "external")
        self.assertIn("No global gprbuild selection", gprbuild_row["reason"])
        self.alire_settings(gnat="gnat_native 14.2.1")
        self.assertEqual(ada.selected()[0]["state"], "blocked")
        self.assertIn(
            "Invalid Alire gnat selection", ada.selected()[0]["reason"]
        )
        # A selection alr has not deployed is no runtime.
        self.alire_settings(
            gnat="gnat_native=16.1.0", gprbuild="gprbuild=26.0.1"
        )
        self.assertEqual(ada.selected()[0]["state"], "blocked")

    def test_alire_canary_builds_as_a_plain_alr_build_would(self):
        self.managers()
        ada = self.adapter("ada")
        gnat = self.alire_release("gnat", "15.1.2")
        gprbuild = self.alire_release("gprbuild", "26.0.1")
        for path, row in (
            (gnat, {"component": "gnat"}),
            (gprbuild, {"component": "gprbuild"}),
        ):
            with self.subTest(path=path.name):
                calls = []

                def run(args, calls=calls, **kwargs):
                    calls.append((args, kwargs))
                    return (
                        "bootstrap-ok"
                        if Path(args[0]).name == "canary"
                        else ""
                    )

                with patch.object(process, "run", side_effect=run):
                    ada.canary(row, path, complete=True)
                build, launch = calls
                environment = build[1]["env"]
                search = environment["PATH"].split(os.pathsep)
                self.assertEqual(search[0], str(path.parent))
                self.assertIn(str(gnat.parent), search)
                self.assertEqual(search[-2:], ["/usr/bin", "/bin"])
                # Only the declared build environment and the toolchain.
                self.assertEqual(set(environment), {"PATH"})
                if row["component"] == "gprbuild":
                    self.assertEqual(build[0][:3], [str(path), "-q", "-P"])
                else:
                    self.assertEqual(
                        build[0][0], str(gnat.parent / "gnatmake")
                    )
                # The link prints its command into the log.
                self.assertEqual(build[0][-2:], ["-largs", "-v"])
                self.assertEqual(Path(launch[0][0]).name, "canary")

    def test_alire_archive_places_only_its_launcher(self):
        def archive(**members):
            data = io.BytesIO()
            with zipfile.ZipFile(data, "w") as file:
                for name, content in members.items():
                    file.writestr(name.replace("__", "/"), content)
            return data.getvalue()

        ada = self.adapter("ada")
        manager = ada.manager_candidates()[0]
        for label, payload, placed in (
            ("missing", archive(LICENSE_txt=b"license"), False),
            ("valid", archive(bin__alr=b"alr", LICENSE_txt=b"license"), True),
        ):
            with self.subTest(archive=label):
                self.data["setup"]["installers"] = {
                    "ada": {
                        "url": "https://example.invalid/alr-bin.zip",
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size": len(payload),
                    }
                }
                with (
                    patch(
                        "urllib.request.urlopen",
                        return_value=io.BytesIO(payload),
                    ),
                    patch.object(process, "run") as runner,
                ):
                    if placed:
                        ada.acquire()
                    else:
                        with self.assertRaisesRegex(BootstrapError, "bin/alr"):
                            ada.acquire()
                runner.assert_not_called()
                self.assertEqual(manager.is_file(), placed)
        self.assertEqual(manager.read_bytes(), b"alr")
        self.assertEqual(manager.stat().st_mode & 0o777, 0o755)
        self.assertEqual(
            sorted(path.name for path in ada.home.rglob("*")), ["alr", "bin"]
        )

    def test_android_records_the_accepted_license_and_declines_the_rest(
        self,
    ):
        self.managers()
        java = self.executable(self.adapter("jvm").binary())
        android = self.adapter("android")
        licenses = android.root / "licenses"
        record = licenses / "android-sdk-license"
        calls = []
        # What the fixture sdkmanager does: install the package unless it
        # needs other terms, and record licenses on its own.
        behavior = {"installs": True, "records": ()}

        def run(args, **kwargs):
            calls.append((args, kwargs))
            # The acceptance is on file before sdkmanager runs.
            self.assertIn(LICENSE_HASH, record.read_text().split())
            for name in behavior["records"]:
                (licenses / name).write_text("hash\n")
            if behavior["installs"]:
                self.android_package(*ANDROID_PACKAGES[args[-1]])
            return ""

        build_tools, platform = android.baseline()[1:3]
        with patch.object(process, "run", side_effect=run):
            android.install(build_tools)
        ((args, kwargs),) = calls
        self.assertEqual(
            args,
            [
                str(android.manager()),
                f"--sdk_root={android.root}",
                "--install",
                "build-tools;37.0.0",
            ],
        )
        self.assertEqual(kwargs["answers"], DECLINE)
        self.assertNotIn(b"y", kwargs["answers"])
        self.assertEqual(
            kwargs["env"]["JAVA_HOME"], str(java.parents[1].resolve())
        )
        # The JVM ignores HOME, so sdkmanager's preferences follow it
        # explicitly.
        self.assertEqual(
            kwargs["env"]["ANDROID_USER_HOME"],
            str((Path.home() / ".android").resolve()),
        )
        # sdkmanager's own layout: an empty first line, one hash per line.
        self.assertEqual(record.read_text(), f"\n{LICENSE_HASH}")
        self.assertEqual(
            build_tools["path"],
            str(android.package_binary("build-tools", "37.0.0")),
        )
        # An older acceptance stays beside the new one, which is added once.
        record.write_text("\nolder")
        with patch.object(process, "run", side_effect=run):
            android.install(build_tools)
            android.install(build_tools)
        self.assertEqual(record.read_text(), f"\nolder\n{LICENSE_HASH}")
        # A package that needs other terms is declined, so never installed.
        behavior["installs"] = False
        with (
            patch.object(process, "run", side_effect=run),
            self.assertRaisesRegex(BootstrapError, "did not install"),
        ):
            android.install(platform)
        self.assertFalse(android.package_binary("platform", "37.2").exists())
        # Licenses sdkmanager recorded on its own are all reverted; one the
        # account had accepted before is restored as it was.
        (licenses / "android-sdk-preview-license").write_text("before\n")
        behavior.update(
            installs=True,
            records=(
                "android-sdk-preview-license",
                "intel-android-extra-license",
            ),
        )
        with (
            patch.object(process, "run", side_effect=run),
            self.assertRaisesRegex(
                BootstrapError,
                "android-sdk-preview-license, intel-android-extra-license",
            ),
        ):
            android.install(platform)
        self.assertEqual(
            sorted(path.name for path in licenses.iterdir()),
            ["android-sdk-license", "android-sdk-preview-license"],
        )
        self.assertEqual(
            (licenses / "android-sdk-preview-license").read_text(), "before\n"
        )
        # Without a reviewed hash in the baseline nothing is accepted or run.
        del self.data["setup"]["licenses"]
        calls.clear()
        with (
            patch.object(process, "run", side_effect=run),
            self.assertRaisesRegex(BootstrapError, "no reviewed"),
        ):
            android.install(build_tools)
        self.assertEqual(calls, [])

    def test_android_readiness_reads_the_tools_without_a_jdk(self):
        android = self.adapter("android")
        self.executable(android.manager_candidates()[0])
        with (
            patch.object(process, "run") as runner,
            self.assertRaisesRegex(BootstrapError, "Incomplete Android"),
        ):
            android.readiness()
        properties = android.tools / "source.properties"
        # Another release in the declared directory is not the declared tools.
        properties.write_text(
            "Pkg.Revision=23.0\nPkg.Path=cmdline-tools;23.0\n"
        )
        with self.assertRaisesRegex(BootstrapError, "reports 23.0"):
            android.readiness()
        properties.write_text(
            "Pkg.Revision=22.0\nPkg.Path=cmdline-tools;22.0\n"
        )
        with patch.object(process, "run") as runner:
            android.readiness()
        runner.assert_not_called()
        # The account's own cmdline-tools/latest is never the bootstrap's.
        self.assertEqual(
            android.manager_candidates(),
            [android.root / "cmdline-tools/22.0/bin/sdkmanager"],
        )

    def test_android_apply_needs_the_license_named(self):
        recovery = Bootstrap(self.data, ["jvm", "android"])
        with self.assertRaisesRegex(
            BootstrapError, "--accept android-sdk-license"
        ):
            recovery.apply([])
        self.assertFalse((recovery.state / "apply.lock").exists())

    def test_android_archive_unpacks_as_the_declared_cmdline_tools(self):
        def archive(*members):
            data = io.BytesIO()
            with zipfile.ZipFile(data, "w") as file:
                for name, mode in members:
                    info = zipfile.ZipInfo(name)
                    info.external_attr = mode << 16
                    file.writestr(info, b"fixture")
            return data.getvalue()

        android = self.adapter("android")
        manager = android.manager_candidates()[0]
        for label, payload, placed in (
            (
                "escaping",
                archive(
                    ("cmdline-tools/bin/sdkmanager", 0o100755),
                    ("cmdline-tools/../../evil", 0o100644),
                ),
                False,
            ),
            ("elsewhere", archive(("tools/bin/sdkmanager", 0o100755)), False),
            (
                "linked",
                archive(("cmdline-tools/bin/sdkmanager", 0o120777)),
                False,
            ),
            (
                "valid",
                archive(
                    ("cmdline-tools/bin/sdkmanager", 0o100755),
                    ("cmdline-tools/lib/sdkmanager.jar", 0o100644),
                ),
                True,
            ),
        ):
            with self.subTest(archive=label):
                self.data["setup"]["installers"] = {
                    "android": {
                        "url": "https://example.invalid/commandlinetools.zip",
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "size": len(payload),
                    }
                }
                with (
                    patch(
                        "urllib.request.urlopen",
                        return_value=io.BytesIO(payload),
                    ),
                    patch.object(process, "run") as runner,
                ):
                    if placed:
                        android.acquire()
                    else:
                        with self.assertRaisesRegex(
                            BootstrapError, "Unexpected entry"
                        ):
                            android.acquire()
                runner.assert_not_called()
                self.assertEqual(manager.is_file(), placed)
        self.assertEqual(manager.stat().st_mode & 0o777, 0o755)
        library = manager.parents[1] / "lib/sdkmanager.jar"
        self.assertEqual(library.stat().st_mode & 0o777, 0o644)
        self.assertFalse((self.root / "evil").exists())

    def test_android_platform_tools_declaration_is_a_floor(self):
        self.managers()
        android = self.adapter("android")
        tools = self.android_package("platform-tools", "37.0.2")
        platform = self.android_package("platform", "37.2")
        rows = {row["component"]: row for row in android.baseline()}
        with patch.object(AndroidAdapter, "canary"):
            self.assertEqual(android.verify(rows["platform-tools"]), "37.0.2")
            self.assertEqual(android.verify(rows["platform"]), "37.2")
            self.android_package("platform-tools", "36.0.0")
            with self.assertRaisesRegex(BootstrapError, "identity mismatch"):
                android.verify(rows["platform-tools"])
            # Health accepts whatever adb the SDK has.
            self.assertEqual(
                android.verify(rows["platform-tools"], exact=False), "36.0.0"
            )
        self.assertEqual(android.selected_runtime(), tools)
        self.assertEqual(android.selection(), None)
        self.assertTrue(platform.is_file())

    def test_damaged_packages_and_settings_are_reported_not_raised(self):
        self.managers()
        android = self.adapter("android")
        jar = self.android_package("platform", "37.2")
        jar.write_text("not a zip")
        row = next(
            row for row in android.baseline() if row["component"] == "platform"
        )
        with self.assertRaisesRegex(BootstrapError, "is damaged"):
            android.verify(row)
        # Qualification turns any failure to read an installation into that
        # row's conflict, so the rest of the report still follows.
        row = dict(row, state="present")
        with patch.object(
            AndroidAdapter, "verify", side_effect=PermissionError("denied")
        ):
            self.recovery.qualify([row], exact=True)
        self.assertEqual((row["state"], row["reason"]), ("conflict", "denied"))
        # alr's settings keep tables where it reads tables and paths where
        # it reads paths; anything else needs a person.
        settings = self.adapter("ada").roots["ALIRE_SETTINGS_DIR"]
        settings.mkdir(parents=True, exist_ok=True)
        for text, message in (
            ('cache = "elsewhere"\n', "setting cache: it is not a table"),
            ("[toolchain]\ndir = 5\n", "toolchain.dir: it is not a path"),
            ('toolchain = "gnat"\n', "setting toolchain: it is not a table"),
        ):
            with self.subTest(settings=text):
                (settings / "settings.toml").write_text(text)
                with self.assertRaisesRegex(BootstrapError, message):
                    Bootstrap(self.data, ["ada"])

    def test_android_canary_links_an_app_against_the_platform(self):
        self.managers()
        android = self.adapter("android")
        adb = self.android_package("platform-tools", "37.0.1")
        aapt2 = self.android_package("build-tools", "37.0.0")
        # Only an older platform is installed; the build tools link against it.
        older = self.android_package("platform", "36")
        calls = []

        def run(args, **kwargs):
            args = [str(arg) for arg in args]
            calls.append((args, kwargs))
            if args[1:] == ["version"]:
                return "Android Debug Bridge version 1.0.41"
            if "badging" in args:
                return "package: name='dev.bootstrap.canary' compileSdkVersion='36'"
            return ""

        rows = {row["component"]: row for row in android.baseline()}
        with patch.object(process, "run", side_effect=run):
            android.canary(rows["platform-tools"], adb, complete=True)
            android.canary(rows["build-tools"], aapt2, complete=True)
        (version, _), (link, link_options), _ = calls
        self.assertEqual(version, [str(adb), "version"])
        scratch = Path(link_options["cwd"])
        self.assertEqual(link_options["env"]["HOME"], str(scratch))
        self.assertEqual(link[:2], [str(aapt2), "link"])
        self.assertIn(str(older), link)
        with (
            patch.object(
                process, "run", return_value="compileSdkVersion='35'"
            ),
            self.assertRaisesRegex(BootstrapError, "canary failed"),
        ):
            android.canary(rows["build-tools"], aapt2, complete=True)
        # Before any platform, as in a first apply, the build tools only
        # report themselves; a platform alone is checked as an archive.
        older.unlink()

        def compile(args, **kwargs):
            # aapt2 writes the compiled resource beside the output option.
            Path(args[3], "values_strings.arsc.flat").write_bytes(b"flat")
            return ""

        with patch.object(process, "run", side_effect=compile) as runner:
            android.canary(rows["build-tools"], aapt2, complete=True)
        self.assertEqual(
            runner.call_args.args[0][:3], [str(aapt2), "compile", "-o"]
        )
        with (
            patch.object(process, "run", return_value=""),
            self.assertRaisesRegex(BootstrapError, "canary failed"),
        ):
            android.canary(rows["build-tools"], aapt2, complete=True)
        aapt2.unlink()
        platform = android.package_binary("platform", "37.2")
        platform.parent.mkdir(parents=True)
        with zipfile.ZipFile(platform, "w") as archive:
            archive.writestr("android/app/Activity.class", b"")
        with patch.object(process, "run") as runner:
            android.canary(rows["platform"], platform, complete=True)
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
