"""Filesystem state transitions; no native installs, providers or downloads."""

import copy
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from engine import Bootstrap
from support import BootstrapError
from native_toolchains import LANGUAGES, SDK_SCRIPT, validate

SPECS = {
    "rust": {"version": "1.98.1"},
    "haskell": {"version": "9.14.1", "cabal": "3.16.1.0"},
    "lean": {"version": "4.32.0"},
    "ruby": {"version": "4.0.6"},
    "jvm": {"version": "21.0.12.1", "candidate": "21.0.12+1.1-tem"},
    "julia": {"version": "1.12.6"},
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
            "setup": {
                "managerDirectory": str(self.root / "bin"),
                "buildEnvironment": {"PATH": "/usr/bin:/bin"},
            },
            "policy": {},
        }
        self.recovery = Bootstrap(self.data, list(SPECS))
        self.native = self.recovery.native
        self.recovery.state.mkdir(parents=True)
        self.calls = []

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
        return path

    def test_runtime_only_apply_rejects_root_before_creating_state(self):
        with patch("engine.os.geteuid", return_value=0):
            with self.assertRaisesRegex(BootstrapError, "never as root"):
                self.recovery.apply([])
        self.assertFalse((self.recovery.state / "apply.lock").exists())

    def test_apply_rejects_shared_roots_and_redirected_runtime_directories(
        self,
    ):
        outside = self.root / "outside"
        outside.mkdir()
        for name, root in self.native.roots.items():
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
        roots = set(self.native.roots.values())
        for directory in self.native.mutable_directories():
            if directory in roots:
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
        directory = self.native.roots["julia"] / "juliaup"
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
                    self.native.julia_binary(identity="1.12.6")
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
            self.native.julia_binary(identity="1.12.6"),
            directory / "runtime/bin/julia",
        )

    def managers(self):
        for language, name in LANGUAGES.items():
            root = self.native.roots[
                {"rust": "cargo", "julia": "juliaup"}.get(language, language)
            ]
            self.executable(
                root
                / (
                    "bin/sdkman-init.sh"
                    if language == "jvm"
                    else "bin/" + name
                )
            )

    def install_fixture(self, row):
        self.calls.append((row["language"], row.get("component")))
        language = row["language"]
        if language == "julia":
            root = self.native.roots[language] / "juliaup"
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
        row["path"] = str(
            self.native.binary(language, component=row.get("component"))
        )
        self.executable(Path(row["path"]))

    def test_empty_plan_is_read_only_and_reports_all_components(self):
        with (
            patch.object(
                self.native,
                "run",
                side_effect=AssertionError("process launched"),
            ),
            patch(
                "urllib.request.urlopen", side_effect=AssertionError("network")
            ),
        ):
            before = sorted(self.root.rglob("*"))
            rows = self.recovery.plan()
            self.assertEqual(len(rows), 7)
            self.assertTrue(all(row["state"] == "blocked" for row in rows))
            self.assertEqual(before, sorted(self.root.rglob("*")))

    def test_install_missing_only_preserves_additional_versions(self):
        self.managers()
        extra = self.executable(
            self.native.roots["ruby"] / "versions/4.1.0/bin/ruby"
        )
        with (
            patch.object(
                self.native, "install", side_effect=self.install_fixture
            ),
            patch.object(self.native, "verify", return_value="ok"),
        ):
            self.recovery.apply(self.recovery.plan())
            self.assertEqual(len(self.calls), 7)
            self.recovery.apply(self.recovery.plan())
            self.assertEqual(len(self.calls), 7)
            self.assertTrue(extra.is_file())
            self.assertEqual(
                self.native.observed()["installed"]["julia"],
                ["1.12.6+0.aarch64.apple.darwin14"],
            )

    def test_default_preservation_for_each_manager(self):
        self.managers()
        roots = self.native.roots
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
        current = roots["jvm"] / "candidates/java/current"
        current.parent.mkdir(parents=True)
        current.symlink_to("25.0.4-tem")
        config = roots["julia"] / "juliaup/juliaup.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"Default":"release"}')
        self.executable(roots["ruby"] / "shims/ruby")
        before = self.native.selections()
        with patch.object(
            self.native,
            "invoke",
            side_effect=AssertionError("default overwritten"),
        ):
            self.native.defaults()
        self.assertEqual(before, self.native.selections())

    def test_health_accepts_older_selections_and_reports_system_ruby(self):
        self.managers()
        roots = self.native.roots
        older = {
            "rust": ("1.90.0", "toolchains/1.90.0-aarch64-apple-darwin"),
            "lean": ("4.20.0", "toolchains/leanprover--lean4---v4.20.0"),
            "haskell": ("9.12.2", "ghc/9.12.2"),
            "jvm": ("17.0.12", "candidates/java/17.0.12-tem"),
            "julia": ("1.10.9", "juliaup/julia-1.10.9"),
        }
        commands = {
            "rust": "rustc",
            "lean": "lean",
            "haskell": "ghc",
            "jvm": "java",
            "julia": "julia",
        }
        for language, (_, prefix) in older.items():
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
        (roots["jvm"] / "candidates/java/current").symlink_to("17.0.12-tem")
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
        (roots["ruby"] / "version").write_text("system\n")
        rows = {
            (row["language"], row.get("component")): row
            for row in self.native.health()
        }
        ruby = rows.pop(("ruby", None))
        self.assertEqual((ruby["state"], ruby["path"]), ("external", ""))
        for (language, component), row in rows.items():
            release = "3.12.1.0" if component else older[language][0]
            with (
                self.subTest(language=language, component=component),
                patch.object(self.native, "run", return_value=release),
                patch.object(self.native, "canary"),
            ):
                self.assertEqual(row["state"], "present")
                self.assertEqual(self.native.verify(row, exact=False), release)
                with self.assertRaisesRegex(
                    BootstrapError, "identity mismatch"
                ):
                    self.native.verify(row)

    def test_initial_defaults_use_literal_manager_commands(self):
        with patch.object(self.native, "invoke") as invoke:
            self.native.defaults()
        calls = [call.args for call in invoke.call_args_list]
        for language in LANGUAGES:
            with self.subTest(language=language):
                self.assertTrue(any(call[0] == language for call in calls))
        for expected in (
            ("jvm", "default", "java", "21.0.12+1.1-tem"),
            ("haskell", "set", "cabal", "3.16.1.0"),
        ):
            with self.subTest(command=expected):
                self.assertIn(expected, calls)

    def test_install_contracts_do_not_reset_default(self):
        with patch.object(self.native, "invoke") as invoke:
            for row in self.native.plan():
                self.native.install(row)
        calls = [call.args for call in invoke.call_args_list]
        for expected in (
            ("haskell", "install", "ghc", "9.14.1", "--no-set"),
            ("haskell", "install", "cabal", "3.16.1.0", "--no-set"),
            ("lean", "toolchain", "install", "leanprover/lean4:v4.32.0"),
        ):
            with self.subTest(command=expected):
                self.assertIn(expected, calls)
        self.assertTrue(all("default" not in call[1:3] for call in calls))

    def test_direct_verification_rejects_proxy_and_version_mismatch(self):
        self.managers()
        for row in self.native.plan():
            self.install_fixture(row)
            with self.subTest(
                language=row["language"], component=row.get("component")
            ):
                with (
                    patch.object(
                        self.native, "run", return_value=row["version"]
                    ) as runner,
                    patch.object(self.native, "canary"),
                ):
                    self.assertEqual(self.native.verify(row), row["version"])
                    self.assertEqual(runner.call_args.args[0][0], row["path"])
                with (
                    patch.object(self.native, "run", return_value="0.0.1"),
                    self.assertRaisesRegex(
                        BootstrapError, "identity mismatch"
                    ),
                ):
                    self.native.verify(row)
        path = self.native.binary("lean")
        path.unlink()
        path.symlink_to(self.native.manager("lean"))
        with self.assertRaisesRegex(BootstrapError, "download-capable"):
            self.native.verify(
                {"language": "lean", "path": str(path), "version": "4.32.0"}
            )

    def test_installer_hash_failure_never_executes(self):
        self.native.only = ["lean"]
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
            patch.object(self.native, "run") as runner,
        ):
            with self.assertRaisesRegex(BootstrapError, "checksum/size"):
                self.native.acquire()
            runner.assert_not_called()

    def test_julia_existing_selection_blocks_manager_reinstallation(self):
        self.native.only = ["julia"]
        config = self.native.roots["julia"] / "juliaup/juliaup.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"Default":"release"}')
        with (
            patch(
                "urllib.request.urlopen", side_effect=AssertionError("network")
            ),
            self.assertRaisesRegex(BootstrapError, "existing Julia selection"),
        ):
            self.native.acquire()

    def test_unrelated_roots_do_not_break_scoped_commands(self):
        for language in LANGUAGES:
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
                self.assertEqual(recovery.native.roots, {})

    def test_sdkman_uses_fixed_bash_program_and_neutral_directory(self):
        self.managers()
        with patch.object(self.native, "run", return_value="") as runner:
            self.native.invoke("jvm", "install", "java", "21.0.12+1.1-tem")
        args = runner.call_args.args[0]
        self.assertEqual(
            args[:5], ["/bin/bash", "--noprofile", "--norc", "-c", SDK_SCRIPT]
        )
        self.assertEqual(args[-3:], ["install", "java", "21.0.12+1.1-tem"])
        self.assertEqual(runner.call_args.kwargs["cwd"], "/")
        self.assertIn("USE=n", SDK_SCRIPT)
        self.assertIn('sdk "$@" <<< n', SDK_SCRIPT)

    def test_verified_installer_runs_once_and_receives_literal_roots(self):
        payload = b"verified installer fixture"
        for language in ("rust", "haskell", "lean", "jvm", "julia"):
            with self.subTest(language=language):
                self.native.only = [language]
                root_key = {"rust": "cargo", "julia": "juliaup"}.get(
                    language, language
                )
                root = self.native.roots[root_key]
                self.data["setup"]["installers"] = {
                    language: {
                        "url": "https://example.invalid/installer",
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "shell": "/bin/sh",
                        "arguments": ["--path", str(root), "{version}"],
                    }
                }

                def install(args, *, root=root, language=language, **kwargs):
                    self.assertEqual(
                        args[-3:],
                        ["--path", str(root), SPECS[language]["version"]],
                    )
                    self.assertTrue(kwargs["source_build"])
                    name = (
                        "sdkman-init.sh"
                        if language == "jvm"
                        else LANGUAGES[language]
                    )
                    self.executable(root / "bin" / name)

                with (
                    patch(
                        "urllib.request.urlopen",
                        return_value=io.BytesIO(payload),
                    ) as fetch,
                    patch.object(
                        self.native, "run", side_effect=install
                    ) as runner,
                ):
                    self.native.acquire()
                    self.native.acquire()
                    self.assertEqual(fetch.call_count, 1)
                    self.assertEqual(runner.call_count, 1)

    def test_rust_paths_follow_declared_platform(self):
        for platform, host in (
            ("aarch64-darwin", "aarch64-apple-darwin"),
            ("x86_64-linux", "x86_64-unknown-linux-gnu"),
        ):
            with self.subTest(platform=platform):
                self.data["platform"] = platform
                path = self.native.binary("rust")
                self.assertEqual(path.parent.parent.name, "1.98.1-" + host)

    def test_sdkman_candidate_and_jdk_patch_identity_are_distinct(self):
        validate(self.data, BootstrapError)
        self.managers()
        row = next(
            row for row in self.native.plan() if row["language"] == "jvm"
        )
        self.install_fixture(row)
        self.assertIn("21.0.12+1.1-tem", row["path"])
        with (
            patch.object(
                self.native,
                "run",
                return_value="openjdk 21.0.12.1 2026-07-21 LTS",
            ),
            patch.object(self.native, "canary"),
        ):
            self.assertEqual(self.native.verify(row), "21.0.12.1")
            with self.assertRaisesRegex(BootstrapError, "identity mismatch"):
                self.native.verify(dict(row, version="21.0.12"))

    def test_dangling_selectors_do_not_authorize_default_replacement(self):
        for language in ("rust", "lean"):
            with self.subTest(language=language):
                self.native.only = [language]
                root = self.native.roots[language]
                root.mkdir(parents=True)
                (root / "settings.toml").symlink_to("missing-settings")
                with (
                    patch.object(self.native, "invoke") as invoke,
                    self.assertRaisesRegex(BootstrapError, "selector file"),
                ):
                    self.native.defaults()
                invoke.assert_not_called()


if __name__ == "__main__":
    unittest.main()
