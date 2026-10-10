"""Prune against fixture manager roots; managers act on the filesystem only."""

import contextlib
import copy
import fcntl
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core import cli, process
from core.engine import Bootstrap
from core.errors import BootstrapError
from core.manifest import validate_retired
from core.prune import Prune
from tests.declaration import declared_manifest

HOST = "aarch64-apple-darwin"
# Fixture declarations, independent of the real baseline's releases.
TOOLCHAINS = {
    "rust": {"version": "1.90.0"},
    "haskell": {"version": "9.14.1", "cabal": "3.16.1.0", "hls": "2.14.0.0"},
    "lean": {"version": "4.30.0"},
    "ruby": {"version": "4.0.2"},
    "jvm": {"version": "21.0.12.1", "candidate": "21.0.12+1.1-tem"},
    "kotlin": {"version": "2.4.2"},
    "scala": {"version": "3.9.0"},
    "julia": {"version": "1.12.2"},
    "dotnet": {"version": "10.0.402"},
}


class PruneTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="bootstrap-prune-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Evaluated (and cached) while the caller's PATH still finds nix.
        data = copy.deepcopy(declared_manifest())
        environment = patch.dict(
            os.environ,
            {
                "HOME": str(self.home),
                "XDG_CACHE_HOME": str(self.root / "cache"),
                "XDG_DATA_HOME": str(self.root / "data"),
                "XDG_STATE_HOME": str(self.root / "state"),
                "PATH": f"{self.bin}:/usr/bin:/bin",
                "PYTHONDONTWRITEBYTECODE": "1",
            },
            clear=True,
        )
        environment.start()
        self.addCleanup(environment.stop)
        data.update(backend="native", platform="aarch64-darwin")
        data["node"]["versions"] = ["24.2.0", "26.2.0"]
        data["python"]["version"] = "3.14.2"
        data["ocaml"]["versions"] = ["5.4.1", "5.5.1"]
        data["nativeToolchains"] = copy.deepcopy(TOOLCHAINS)
        data["defaults"] = {
            "node": "26.2.0",
            "python": "3.14.2",
            "ocaml": "5.5.1",
            **{name: spec["version"] for name, spec in TOOLCHAINS.items()},
        }
        data["retired"] = {}
        data["setup"] = {
            "managerDirectory": str(self.bin),
            "managers": {"node": "fnm", "python": "pyenv", "ocaml": "opam"},
            "buildEnvironment": {},
            "sdkmanShell": "/fixture/bash",
        }
        self.data = data
        self.events = []
        # Commands the fixture managers fail, by their first two arguments.
        self.failing = set()
        patcher = patch.object(process, "run", self.run_process)
        patcher.start()
        self.addCleanup(patcher.stop)

    # Fixtures ---------------------------------------------------------------

    def select(self, *languages, retired):
        self.data["retired"] = retired
        self.context = Bootstrap(self.data, list(languages))
        for adapter in self.context.adapters.values():
            self.executable(adapter.manager_candidates()[0])
            if hasattr(adapter, "invoke"):
                patcher = patch.object(
                    adapter,
                    "invoke",
                    side_effect=lambda *args, adapter=adapter, **_: (
                        self.invoke(adapter, *args)
                    ),
                )
                patcher.start()
                self.addCleanup(patcher.stop)
        return self.context

    def adapter(self, language):
        return self.context.adapter(language)

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o755)
        return path

    def node(self, release, *packages):
        installation = (
            self.adapter("node").root
            / "node-versions"
            / f"v{release}"
            / "installation"
        )
        self.executable(installation / "bin/node")
        for name, version in (("npm", "11.0.0"), *packages):
            manifest = (
                installation / "lib/node_modules" / name / "package.json"
            )
            manifest.parent.mkdir(parents=True, exist_ok=True)
            manifest.write_text(json.dumps({"name": name, "version": version}))
        return installation

    def node_default(self, release):
        alias = self.adapter("node").root / "aliases/default"
        alias.parent.mkdir(parents=True, exist_ok=True)
        if os.path.lexists(alias):
            alias.unlink()
        alias.symlink_to(
            self.adapter("node").root
            / "node-versions"
            / f"v{release}"
            / "installation"
        )

    def python(self, release, *distributions):
        prefix = self.adapter("python").root / "versions" / release
        minor = ".".join(release.split(".")[:2])
        self.executable(prefix / f"bin/python{minor}")
        for name in ("python", "python3"):
            (prefix / "bin" / name).symlink_to(f"python{minor}")
        site = prefix / f"lib/python{minor}/site-packages"
        for name, version in (("pip", "26.0"), *distributions):
            (site / f"{name}-{version}.dist-info").mkdir(parents=True)
        return prefix

    def venv(self, path, prefix, release):
        (path / "bin").mkdir(parents=True)
        minor = ".".join(release.split(".")[:2])
        (path / "bin/python").symlink_to(prefix / f"bin/python{minor}")
        (path / "bin/python3").symlink_to("python")
        (path / "pyvenv.cfg").write_text(
            f"home = {prefix}/bin\nimplementation = CPython\n"
            f"version_info = {release}\ninclude-system-site-packages = false\n"
        )
        return path

    def ruby(self, release, *gems, default=()):
        prefix = self.adapter("ruby").root / "versions" / release
        self.executable(prefix / "bin/ruby")
        specifications = prefix / "lib/ruby/gems/4.0.0/specifications"
        (specifications / "default").mkdir(parents=True)
        for name in gems:
            (specifications / f"{name}.gemspec").write_text("")
        for name in default:
            (specifications / "default" / f"{name}.gemspec").write_text("")
        return prefix

    def rust(self, release, *components):
        toolchain = (
            self.adapter("rust").root / "toolchains" / f"{release}-{HOST}"
        )
        self.executable(toolchain / "bin/rustc")
        record = toolchain / "lib/rustlib/components"
        record.parent.mkdir(parents=True)
        record.write_text(
            "\n".join(
                [
                    f"rustc-{HOST}",
                    f"cargo-{HOST}",
                    f"rust-std-{HOST}",
                    *components,
                ]
            )
            + "\n"
        )
        return toolchain

    def rust_settings(self, default, overrides=()):
        lines = [f'default_toolchain = "{default}-{HOST}"', "", "[overrides]"]
        lines += [f'"{directory}" = "{tc}"' for directory, tc in overrides]
        (self.adapter("rust").root / "settings.toml").write_text(
            "\n".join(lines) + "\n"
        )

    def julia(self, default, versions, channels):
        root = self.adapter("julia").root / "juliaup"
        installed = {}
        for release in versions:
            identity = f"{release}+0.aarch64.apple.darwin14"
            path = f"./julia-{identity}"
            self.executable(root / path / "bin/julia")
            installed[identity] = {"Path": path}
        config = {
            "Default": default,
            "InstalledVersions": installed,
            "InstalledChannels": {
                name: {"Version": f"{release}+0.aarch64.apple.darwin14"}
                for name, release in channels.items()
            },
        }
        (root / "juliaup.json").write_text(json.dumps(config))

    # Fixture managers -------------------------------------------------------

    def run_process(self, arguments, **kwargs):
        args = [str(argument) for argument in arguments]
        self.events.append(tuple(args))
        name = Path(args[0]).name
        if tuple(args[1:3]) in self.failing or name in self.failing:
            raise BootstrapError(f"{name} exited 1: fixture failure")
        if name == "fnm":
            root = Path(args[args.index("--fnm-dir") + 1])
            operation, release = args[3], args[4]
            prefix = root / "node-versions" / f"v{release}"
            if operation == "default":
                self.node_default(release)
            elif operation == "uninstall":
                shutil.rmtree(prefix)
                for alias in (root / "aliases").glob("*"):
                    if alias.resolve().is_relative_to(prefix):
                        alias.unlink()
            return ""
        if name == "pyenv":
            root = Path(kwargs["env"]["PYENV_ROOT"])
            if args[1] == "global":
                (root / "version").write_text(args[2] + "\n")
            elif args[1] == "uninstall":
                self.assertEqual(args[2], "--force")
                shutil.rmtree(root / "versions" / args[3])
            elif args[1] == "rehash":
                self.executable(root / "shims/python")
            return ""
        if name == "opam":
            root = self.adapter("ocaml").root
            if args[1:3] == ["switch", "remove"]:
                shutil.rmtree(root / args[3])
            elif args[1:3] == ["switch", "set"]:
                (root / "config").write_text(f'switch: "{args[3]}"\n')
            return ""
        if name in ("npm", "gem"):
            return ""
        if name.startswith("python") and "-c" in args:
            # A virtual environment reports the release it now runs.
            return Path(args[0]).resolve().parents[1].name
        if name.startswith("python") and "pip" in args:
            return ""
        raise AssertionError(f"Unmocked subprocess: {args!r}")

    def invoke(self, adapter, *args):
        language = adapter.language
        self.events.append((language, *args))
        if (language, *args[:1]) in self.failing:
            raise BootstrapError(f"{language} exited 1: fixture failure")
        root = adapter.root
        if language == "rust" and args[:2] == ("toolchain", "uninstall"):
            shutil.rmtree(root / "toolchains" / args[2])
        elif language == "rust" and args[0] == "default":
            self.rust_settings(args[1])
        elif language == "ruby" and args[0] == "uninstall":
            shutil.rmtree(root / "versions" / args[2])
        elif language == "ruby" and args[0] == "global":
            (root / "version").write_text(args[1] + "\n")
        elif language == "haskell" and args[0] == "rm":
            component, release = args[1:]
            if component == "cabal":
                (root / "bin" / f"cabal-{release}").unlink()
            else:
                shutil.rmtree(root / component / release)
        elif language == "haskell" and args[0] == "set":
            link = root / "bin" / {"cabal": "cabal", "ghc": "ghc"}[args[1]]
            link.unlink()
            link.symlink_to(f"cabal-{args[2]}")
        elif args[0] == "uninstall" and language in ("jvm", "kotlin"):
            shutil.rmtree(root / adapter.runtime_directory / args[2])
        elif args[0] == "default" and language in ("jvm", "kotlin"):
            current = root / adapter.runtime_directory / "current"
            current.unlink()
            current.symlink_to(args[2])
        elif language == "julia" and args[0] == "default":
            path = root / "juliaup/juliaup.json"
            config = json.loads(path.read_text())
            path.write_text(json.dumps(config | {"Default": args[1]}))
        elif language == "julia" and args[0] == "remove":
            config = json.loads((root / "juliaup/juliaup.json").read_text())
            identity = config["InstalledChannels"].pop(args[1])["Version"]
            entry = config["InstalledVersions"].pop(identity)
            shutil.rmtree(root / "juliaup" / entry["Path"])
            (root / "juliaup/juliaup.json").write_text(json.dumps(config))
        elif language == "scala" and args[0] == "install":
            for spec in args[3:]:
                launcher, release = spec.split(":")
                self.launcher(launcher, release)
        return ""

    def launcher(self, name, release):
        scala = self.adapter("scala")
        distribution = scala.binary(release).parent.parent
        target = scala.home / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            f'#!/bin/sh\nexec "{distribution}/bin/{name}" "$@"\n'
        )
        target.chmod(0o755)

    def plan(self):
        return [r.report() for r in Prune(self.context).plan()]

    def apply(self):
        return [r.report() for r in Prune(self.context).apply()]

    # Tests ------------------------------------------------------------------

    def test_only_installed_retired_releases_are_planned_without_changes(self):
        self.select(
            "node", retired={"node": {"versions": ["26.1.0", "22.0.0"]}}
        )
        for release in ("20.0.0", "26.1.0", "26.2.0"):
            self.node(release)
        self.node_default("26.2.0")
        before = sorted(self.root.rglob("*"))
        rows = self.plan()
        self.assertEqual(
            [(r["version"], r["state"], r["successor"]) for r in rows],
            [("26.1.0", "retire", "26.2.0")],
        )
        self.assertEqual(rows[0]["steps"], ["remove it"])
        self.assertEqual(self.events, [])
        self.assertEqual(before, sorted(self.root.rglob("*")))

    def test_the_selection_moves_to_the_successor_before_removal(self):
        self.select("node", retired={"node": {"versions": ["24.1.0"]}})
        self.node("24.1.0")
        self.node("24.2.0")
        self.node_default("24.1.0")
        (row,) = self.apply()
        self.assertEqual(row["state"], "removed")
        self.assertEqual(row["successor"], "24.2.0")
        operations = [event[3] for event in self.events]
        self.assertEqual(operations, ["default", "uninstall"])
        alias = self.adapter("node").root / "aliases/default"
        self.assertEqual(alias.resolve().parent.name, "v24.2.0")
        self.assertFalse((alias.parents[1] / "node-versions/v24.1.0").exists())

    def test_a_missing_successor_blocks_and_keeps_the_release(self):
        self.select("node", retired={"node": {"versions": ["26.1.0"]}})
        prefix = self.node("26.1.0").parent
        self.node_default("26.1.0")
        (row,) = self.apply()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("26.2.0 is not installed; apply first", row["reason"])
        self.assertTrue(prefix.is_dir())
        self.assertEqual(self.events, [])

    def test_node_globals_move_and_user_aliases_block(self):
        self.select("node", retired={"node": {"versions": ["26.1.0"]}})
        self.node("26.1.0", ("typescript", "5.9.0"), ("@scope/tool", "1.0.0"))
        self.node("26.2.0", ("typescript", "5.8.0"))
        self.node_default("26.2.0")
        (row,) = self.plan()
        self.assertEqual(
            row["steps"],
            ["install global packages into 26.2.0: @scope/tool", "remove it"],
        )
        self.apply()
        npm = next(event for event in self.events if event[0].endswith("npm"))
        self.assertEqual(npm[-1], "@scope/tool@1.0.0")
        self.assertIn("--global", npm)
        # A name of the user's own pointing at a retired release keeps it.
        self.node("26.1.0")
        (self.adapter("node").root / "aliases/lts").symlink_to(
            self.adapter("node").root / "node-versions/v26.1.0/installation"
        )
        (row,) = self.apply()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("fnm alias lts", row["reason"])

    def test_virtual_environments_follow_a_patch_release(self):
        self.select("python", retired={"python": {"version": ["3.14.1"]}})
        old = self.python("3.14.1", ("cocotb", "2.0"))
        new = self.python("3.14.2")
        (self.adapter("python").root / "version").write_text("3.14.1\n")
        data = self.root / "data"
        tool = self.venv(data / "uv/tools/tool", old, "3.14.1")
        mason = self.venv(
            data / "nvim/mason/packages/lint/venv", old, "3.14.1"
        )
        (row,) = self.plan()
        self.assertEqual(
            row["steps"],
            [
                "repoint 2 virtual environments to 3.14.2",
                "install into 3.14.2: cocotb",
                "select 3.14.2 globally",
                "remove it",
            ],
        )
        (row,) = self.apply()
        self.assertEqual(row["state"], "removed", row.get("reason"))
        for environment in (tool, mason):
            self.assertEqual(
                (environment / "bin/python").readlink(),
                new / "bin/python3.14",
            )
            settings = (environment / "pyvenv.cfg").read_text()
            self.assertIn(f"home = {new}/bin\n", settings)
            self.assertIn("version_info = 3.14.2\n", settings)
        pip = next(event for event in self.events if "pip" in event)
        self.assertEqual(pip[-1], "cocotb==2.0")
        self.assertEqual(
            (self.adapter("python").root / "version").read_text(), "3.14.2\n"
        )
        self.assertFalse(old.exists())

    def test_python_dependents_that_cannot_follow_block(self):
        self.select("python", retired={"python": {"version": ["3.13.5"]}})
        old = self.python("3.13.5")
        self.python("3.14.2")
        self.venv(self.root / "data/uv/tools/tool", old, "3.13.5")
        (old / "envs/project").mkdir(parents=True)
        (row,) = self.apply()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("another minor release", row["reason"])
        self.assertIn("pyenv-virtualenv environments", row["reason"])
        self.assertTrue(old.is_dir())

    def test_a_copied_interpreter_blocks(self):
        self.select("python", retired={"python": {"version": ["3.14.1"]}})
        old = self.python("3.14.1")
        self.python("3.14.2")
        environment = self.venv(self.root / "home/.venv", old, "3.14.1")
        (environment / "bin/python").unlink()
        self.executable(environment / "bin/python")
        (row,) = self.apply()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("copied interpreter", row["reason"])
        self.assertTrue(old.is_dir())

    def test_a_failed_step_keeps_that_release_and_others_proceed(self):
        self.select(
            "ruby",
            "rust",
            retired={
                "nativeToolchains": {
                    "ruby": {"version": ["4.0.1"]},
                    "rust": {"version": ["1.89.0"]},
                }
            },
        )
        old = self.ruby("4.0.1", "cocoapods-1.17.0", "ffi-1.17.4-arm64-darwin")
        self.ruby("4.0.2", default=("ffi-1.17.3",))
        self.rust("1.89.0", "rust-src")
        self.rust("1.90.0")
        self.rust_settings("1.90.0")
        self.failing.add("gem")
        rows = {row["language"]: row for row in self.apply()}
        self.assertEqual(rows["ruby"]["state"], "failed")
        self.assertIn("fixture failure", rows["ruby"]["reason"])
        self.assertIn("cocoapods", rows["ruby"]["steps"][0])
        self.assertNotIn("ffi", rows["ruby"]["steps"][0])
        self.assertTrue(old.is_dir())
        self.assertEqual(rows["rust"]["state"], "removed")
        self.assertIn(
            (
                "rust",
                "component",
                "add",
                "--toolchain",
                f"1.90.0-{HOST}",
                "rust-src",
            ),
            self.events,
        )

    def test_rust_directory_overrides_block(self):
        self.select(
            "rust",
            retired={"nativeToolchains": {"rust": {"version": ["1.89.0"]}}},
        )
        self.rust("1.89.0")
        self.rust("1.90.0")
        self.rust_settings("1.90.0", [("/work/crate", f"1.89.0-{HOST}")])
        (row,) = self.apply()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("/work/crate", row["reason"])
        # Overrides that cannot be read may name it as well.
        (self.adapter("rust").root / "settings.toml").write_text(
            "[overrides\n"
        )
        (row,) = self.apply()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("Cannot read", row["reason"])

    def test_julia_exact_channels_go_and_tracking_channels_block(self):
        self.select(
            "julia",
            retired={
                "nativeToolchains": {
                    "julia": {"version": ["1.12.0", "1.12.1"]}
                }
            },
        )
        self.julia(
            "1.12.0",
            ["1.12.0", "1.12.1", "1.12.2"],
            {"1.12.0": "1.12.0", "release": "1.12.1", "1.12.2": "1.12.2"},
        )
        rows = {row["version"]: row for row in self.apply()}
        self.assertEqual(rows["1.12.0"]["state"], "removed")
        self.assertIn(("julia", "default", "1.12.2"), self.events)
        self.assertIn(("julia", "remove", "1.12.0"), self.events)
        self.assertEqual(rows["1.12.1"]["state"], "blocked")
        self.assertIn("channel release follows it", rows["1.12.1"]["reason"])

    def test_haskell_components_reselect_and_remove_separately(self):
        self.select(
            "haskell",
            retired={"nativeToolchains": {"haskell": {"cabal": ["3.14.2.0"]}}},
        )
        root = self.adapter("haskell").root
        for release in ("3.14.2.0", "3.16.1.0"):
            self.executable(root / "bin" / f"cabal-{release}")
        (root / "bin/cabal").symlink_to("cabal-3.14.2.0")
        (row,) = self.apply()
        self.assertEqual(
            (row["component"], row["state"]), ("cabal", "removed")
        )
        self.assertEqual(
            [event for event in self.events if event[0] == "haskell"],
            [
                ("haskell", "set", "cabal", "3.16.1.0"),
                ("haskell", "rm", "cabal", "3.14.2.0"),
            ],
        )

    def test_sdkman_java_is_retired_by_candidate_identifier(self):
        self.select(
            "jvm",
            retired={
                "nativeToolchains": {"jvm": {"candidate": ["21.0.11+9-tem"]}}
            },
        )
        java = self.adapter("jvm").root / "candidates/java"
        for identifier in ("21.0.11+9-tem", "21.0.12+1.1-tem", "25.0.4-tem"):
            self.executable(java / identifier / "bin/java")
        (java / "current").symlink_to("21.0.11+9-tem")
        (row,) = self.apply()
        self.assertEqual(row["state"], "removed")
        self.assertEqual(
            [event for event in self.events if event[0] == "jvm"],
            [
                ("jvm", "default", "java", "21.0.12+1.1-tem"),
                ("jvm", "uninstall", "java", "21.0.11+9-tem"),
            ],
        )
        self.assertTrue((java / "25.0.4-tem").is_dir())

    def test_directory_releases_check_their_launchers_and_links(self):
        self.select(
            "jvm",
            "scala",
            "dotnet",
            retired={
                "nativeToolchains": {
                    "scala": {"version": ["3.8.0"]},
                    "dotnet": {"version": ["10.0.401", "10.0.400"]},
                }
            },
        )
        scala = self.adapter("scala")
        for release in ("3.8.0", "3.9.0"):
            self.executable(scala.binary(release))
        for name in ("scala", "scalac"):
            self.launcher(name, "3.8.0")
        sdk = self.adapter("dotnet").root / "sdk"
        self.executable(sdk / "10.0.401/dotnet.dll")
        outside = self.root / "elsewhere"
        outside.mkdir()
        (sdk / "10.0.400").symlink_to(outside)
        rows = {row["version"]: row for row in self.apply()}
        self.assertEqual(rows["3.8.0"]["state"], "removed")
        self.assertFalse(scala.binary("3.8.0").exists())
        self.assertIn("3.9.0", (scala.home / "scalac").read_text())
        self.assertEqual(rows["10.0.401"]["state"], "removed")
        self.assertEqual(rows["10.0.400"]["state"], "blocked")
        self.assertTrue(outside.is_dir())

    def test_another_launcher_running_a_distribution_blocks(self):
        self.select(
            "jvm",
            "scala",
            retired={"nativeToolchains": {"scala": {"version": ["3.8.0"]}}},
        )
        for release in ("3.8.0", "3.9.0"):
            self.executable(self.adapter("scala").binary(release))
        self.launcher("scala-runner", "3.8.0")
        (row,) = self.apply()
        self.assertEqual(row["state"], "blocked")
        self.assertIn("launcher scala-runner", row["reason"])

    def test_ocaml_removes_only_unused_seed_switches(self):
        self.select(
            "ocaml", retired={"ocaml": {"versions": ["5.4.0", "5.5.0"]}}
        )
        root = self.adapter("ocaml").root
        for switch, roots in (
            ("lcs-ocaml-5.4.0", '"ocaml-base-compiler.5.4.0" "dune.3.20"'),
            (
                "lcs-ocaml-5.5.0",
                '"ocaml-base-compiler.5.5.0" "ocaml-options-vanilla.1"',
            ),
            ("lcs-ocaml-5.5.1", '"ocaml-base-compiler.5.5.1"'),
        ):
            self.executable(root / switch / "bin/ocamlc")
            state = root / switch / ".opam-switch/switch-state"
            state.parent.mkdir(parents=True)
            state.write_text(f"roots: [{roots}]\n")
        # A switch the user named holds a retired compiler: never planned.
        self.executable(root / "rocq/bin/ocamlc")
        (root / "config").write_text('switch: "lcs-ocaml-5.5.0"\n')
        rows = {row["version"]: row for row in self.apply()}
        self.assertEqual(rows["5.4.0"]["state"], "blocked")
        self.assertIn("dune.3.20", rows["5.4.0"]["reason"])
        self.assertEqual(rows["5.5.0"]["state"], "removed")
        self.assertEqual(
            (root / "config").read_text(), 'switch: "lcs-ocaml-5.5.1"\n'
        )
        self.assertTrue((root / "rocq").is_dir())
        self.assertEqual(len(rows), 2)

    def test_prune_waits_for_the_apply_lock(self):
        self.select("node", retired={"node": {"versions": ["26.1.0"]}})
        prefix = self.node("26.1.0").parent
        self.context.state.mkdir(parents=True, exist_ok=True)
        with (self.context.state / "apply.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.assertRaisesRegex(BootstrapError, "Another recovery"):
                Prune(self.context).apply()
        self.assertTrue(prefix.is_dir())

    def test_command_line_reports_and_exit_status(self):
        manifest = self.root / "manifest.json"
        self.data["retired"] = {"node": {"versions": ["26.1.0"]}}
        manifest.write_text(json.dumps(self.data))
        self.select("node", retired=self.data["retired"])
        self.node("26.1.0")
        self.node("26.2.0")

        def run(*arguments):
            output = io.StringIO()
            argv = ["dev-bootstrap", "--manifest", str(manifest), *arguments]
            with (
                patch.object(sys, "argv", argv),
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                try:
                    code = cli.main()
                except SystemExit as error:
                    code = error.code
            return code, output.getvalue()

        code, output = run("prune", "--only", "node")
        self.assertEqual(code, 0)
        self.assertIn("retire   node", output)
        self.assertIn("prune --yes removes the 1 release(s)", output)
        code, output = run("prune", "--only", "node", "--yes", "--json")
        self.assertEqual(code, 0)
        report = json.loads(output)
        self.assertEqual(report["action"], "prune")
        self.assertEqual(report["retired"][0]["state"], "removed")
        self.assertEqual(run("plan", "--yes")[0], 2)
        self.node("26.1.0")
        self.node_default("26.1.0")
        shutil.rmtree(self.adapter("node").root / "node-versions/v26.2.0")
        self.assertEqual(run("prune", "--only", "node", "--yes")[0], 1)

    def test_unsafe_retired_releases_are_rejected(self):
        validate_retired({"node": {"versions": ["26.1.0"]}})
        for retired in (
            {"node": {"versions": ["../26.1.0"]}},
            {"node": {"versions": "26.1.0"}},
            {"node": {"versions": [26]}},
            [],
        ):
            with (
                self.subTest(retired=retired),
                self.assertRaises(BootstrapError),
            ):
                validate_retired(retired)


if __name__ == "__main__":
    unittest.main()
