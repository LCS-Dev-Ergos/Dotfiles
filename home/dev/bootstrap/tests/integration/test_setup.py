"""Behavioral setup cases; native managers are mocked, child env probes are real."""

import contextlib
import copy
import fcntl
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from core import cli, process
from core.adapters.node import FNM_SYSTEM_TARGET
from core.adapters.ocaml import OcamlAdapter
from core.adapters.python import PythonAdapter
from core.engine import Bootstrap
from core.errors import BootstrapError
from core.paths import writable_directory
from core.setup import BootstrapSetup
from tests.declaration import declared_manifest
from tests.unit.test_process import gone

implementation = Path(__file__).resolve().parents[2]
# Resolved before setUp narrows PATH: a Linux build sandbox has no sleep in
# /usr/bin or /bin.
SLEEP = shutil.which("sleep")


class SetupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="bootstrap-setup-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir(mode=0o700)
        self.events = []
        self.versions = {}
        self.failure = None
        # (language, version) whose fixture install is interrupted.
        self.interrupt = None
        self.shadow = False
        self.probe = None
        self.installed = set()
        self.provided = set()
        # Formulae the fixture Homebrew installs but cannot link, and ones
        # it fails to install.
        self.unlinked = set()
        self.uninstallable = set()
        self.data = copy.deepcopy(declared_manifest())
        self.data.update(backend="native", platform="aarch64-darwin")
        # Releases the fixture pyenv's python-build reports it can build.
        self.definitions = ["3.13.5", self.data["python"]["version"]]
        self.data["setup"] = {
            "packageManager": str(self.bin / "brew"),
            "managerDirectory": str(self.bin),
            "query": ["list", "--formula"],
            "install": ["install", "--formula"],
            "privilege": [],
            "environment": {"HOMEBREW_NO_INSTALL_UPGRADE": "1"},
            "managers": {"node": "fnm", "python": "pyenv", "ocaml": "opam"},
            "buildPackages": {"python": ["sqlite"], "ocaml": []},
            "sdkProbe": [],
            "shell": str(self.bin / "zsh"),
            "shellProbe": "fixture-probe",
            "shellConfig": "fixture-config",
        }
        self.executable(self.bin / "brew")
        self.executable(self.bin / "zsh")
        # Discovery must use a fixture utility, including Linux build sandboxes
        # without /usr/bin. Its checksum output is supplied by mock_run.
        self.executable(self.bin / "sha256sum")
        self.environment = patch.dict(
            os.environ,
            {
                "HOME": str(self.root / "home"),
                "XDG_CACHE_HOME": str(self.root / "cache"),
                "XDG_DATA_HOME": str(self.root / "data"),
                "XDG_STATE_HOME": str(self.root / "state"),
                "PYENV_ROOT": str(self.root / "pyenv"),
                "FNM_DIR": str(self.root / "fnm"),
                "OPAMROOT": str(self.root / "opam"),
                "PYTHONDONTWRITEBYTECODE": "1",
                "PATH": str(self.bin) + ":/usr/bin:/bin",
            },
            clear=True,
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.fnm = self.root / "fnm"
        self.pyenv = self.root / "pyenv"
        self.opam = self.root / "opam"
        self.actual_run = process.run
        mock = patch.object(process, "run", self.mock_run)
        mock.start()
        self.addCleanup(mock.stop)
        self.scope(["node", "python", "ocaml"])

    def scope(self, languages):
        """Select adapters; their installers become filesystem fixtures."""
        self.recovery = Bootstrap(self.data, languages)
        self.setup = BootstrapSetup(self.recovery)
        for adapter in self.recovery.adapters.values():
            mock = patch.object(adapter, "install", self.install_runtime)
            mock.start()
            self.addCleanup(mock.stop)

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 0\n")
        path.chmod(0o700)

    def install_runtime(self, row):
        self.events.append(("runtime", row["language"], row["version"]))
        path = Path(row["path"])
        if (row["language"], row["version"]) == self.interrupt:
            # A manager stopped mid-install leaves its prefix incomplete.
            (path.parent.parent / "partial").mkdir(parents=True)
            raise KeyboardInterrupt
        self.executable(path)
        self.versions[str(path)] = row["version"]
        if row["language"] == "ocaml":
            (path.parent.parent / ".opam-switch").mkdir()
            config = self.opam / "config"
            if not config.exists():
                config.write_text("")

    def mock_run(self, arguments, **kwargs):
        args = list(map(str, arguments))
        self.events.append(tuple(args))
        if self.failure and self.failure(args):
            raise BootstrapError("fixture stage failure")
        name = Path(args[0]).name
        if args[1:] == ["--version"] and name in ("fnm", "pyenv", "opam"):
            return {
                "fnm": "fnm 1.39.0",
                "pyenv": "pyenv 2.8.8",
                "opam": "2.6.0",
            }[name]
        if name == "pyenv" and args[1:] == ["install", "--list"]:
            self.assertEqual(kwargs["env"]["PYENV_ROOT"], str(self.pyenv))
            return "\n".join(
                ["Available versions:", *(f"  {v}" for v in self.definitions)]
            )
        if name == "pyenv" and args[1] == "install":
            return ""
        if args[1:] == ["list", "--formula"] or args[1:] == ["-Qq"]:
            return "\n".join(sorted(self.installed))
        if args[1] == "-T":
            self.assertEqual(kwargs["success_codes"], (0, 127))
            return "\n".join(
                sorted(set(args[2:]) - self.installed - self.provided)
            )
        if "install" in args or "-S" in args:
            self.assertNotIn("-Sy", args)
            self.assertNotIn("-Syu", args)
            start = args.index("--formula") + 1 if "--formula" in args else 4
            self.installed.update(set(args[start:]) - self.uninstallable)
            for manager in self.data["setup"]["managers"].values():
                if manager in self.installed:
                    self.executable(self.bin / manager)
            if self.unlinked & set(args[start:]):
                raise BootstrapError(
                    "brew exited 1: Error: The `brew link` step did not "
                    "complete successfully"
                )
            return ""
        if name == "sudo" and args[1:] == ["-n", "/usr/bin/true"]:
            return ""
        if name == "fnm" and "default" in args:
            alias = self.fnm / "aliases/default"
            alias.parent.mkdir(parents=True, exist_ok=True)
            target = (
                self.fnm / "node-versions" / ("v" + args[-1]) / "installation"
            )
            alias.symlink_to(target)
            return ""
        if name == "pyenv" and args[1] == "global":
            (self.pyenv / "version").write_text(args[2] + "\n")
            return ""
        if name == "pyenv" and args[1] == "rehash":
            self.assertEqual(kwargs["env"]["PYENV_ROOT"], str(self.pyenv))
            self.executable(self.pyenv / "shims/python")
            return ""
        if name == "opam" and args[1:3] == ["switch", "remove"]:
            # An unregistered switch: opam refuses, the directory remains.
            raise BootstrapError("opam exited 5: No switch found")
        if name == "opam" and args[1:3] == ["switch", "set"]:
            (self.opam / "config").write_text('switch: "' + args[3] + '"\n')
            return ""
        if name == "opam" and args[1] == "init":
            self.assertIn("--reinit", args)
            self.assertIn("--no-setup", args)
            self.assertIn("--enable-shell-hook", args)
            self.executable(self.opam / "opam-init/env_hook.zsh")
            return ""
        if name == "zsh":
            self.assertEqual(args[1], "-fi")
            self.assertEqual(
                kwargs["env"]["PATH"].split(os.pathsep)[0],
                self.data["setup"]["managerDirectory"],
            )
            self.assertNotEqual(kwargs["env"]["HOME"], str(self.root / "home"))
            self.assertEqual(kwargs["env"]["LCS_NATIVE_FNM_READY"], "1")
            self.probe = kwargs["env"]["DEV_BOOTSTRAP_ONLY"].split()
            if self.shadow:
                return "node\t/unexpected/node\tv26.10.0"
            # Independent fixture observations, not production health() output.
            paths = {
                "node": self.fnm / "aliases/default/bin/node",
                "python": self.pyenv
                / "versions"
                / (self.pyenv / "version").read_text().strip()
                / "bin/python",
                "ocaml": self.opam
                / self.recovery.observed_state()["globalSelections"]["ocaml"]
                / "bin/ocamlc",
            }
            # Like the production probe, report only the requested languages.
            return "\n".join(
                f"{language}\t{paths[language].resolve()}\tversion"
                for language in self.probe
            )
        identity = self.versions.get(args[0])
        if identity:
            if args[1] in ("--version", "-version"):
                return "v" + identity if name == "node" else identity
            if "platform.python_version()" in " ".join(args):
                return identity
            return ""
        if name == "ocamlrun":
            return "recovery-ok"
        if name in ("sha256sum", "shasum", "openssl"):
            return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        raise AssertionError("Unmocked subprocess: " + repr(args))

    def selection_files(self):
        return (
            os.readlink(self.fnm / "aliases/default"),
            (self.pyenv / "version").read_text(),
            (self.opam / "config").read_text(),
        )

    def cli(self, *arguments, scoped=True):
        """Run the CLI in-process so the process boundary stays mocked.

        A scoped call selects the fixture's languages with --only; an
        unscoped one leaves the choice to the saved selection or --all.
        """
        code, output, _ = self.cli_output(*arguments, "--json", scoped=scoped)
        return code, json.loads(output)

    def cli_output(self, *arguments, scoped=False):
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps(self.data))
        argv = [
            "dev-bootstrap",
            "--manifest",
            str(manifest),
            *arguments,
            *(
                f"--only={language}"
                for language in (self.recovery.only if scoped else ())
            ),
        ]
        output, errors = io.StringIO(), io.StringIO()
        umask = os.umask(0o077)
        try:
            with (
                patch.object(sys, "argv", argv),
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(errors),
            ):
                code = cli.main()
        finally:
            os.umask(umask)
        return code, output.getvalue(), errors.getvalue()

    def mutations(self):
        # Listing python-build definitions reads state; it installs nothing.
        return [
            event
            for event in self.events
            if "--list" not in event
            and (
                event[0] == "runtime"
                or "install" in event
                or "-S" in event
                or "default" in event
                or "global" in event
                or event[1:3] == ("switch", "set")
            )
        ]

    def test_empty_roots_and_second_apply(self):
        self.setup.apply()
        selected = self.recovery.observed_state()["globalSelections"]
        self.assertTrue(all(selected.values()))
        self.assertEqual(selected["python"], self.data["defaults"]["python"])
        self.assertEqual(
            selected["ocaml"], "lcs-ocaml-" + self.data["defaults"]["ocaml"]
        )
        self.events.clear()
        self.setup.apply()
        self.assertEqual(self.mutations(), [])

    def test_reports_follow_schema_one(self):
        # Interfaces.md documents these fields; a change bumps the schema.
        # The fixture installs first: the CLI's own adapters are real.
        self.setup.apply()
        common = {
            "schema",
            "action",
            "platform",
            "backend",
            "defaults",
            "catalog",
            "observed",
            "runtimes",
            "setup",
            "selection",
        }
        for arguments, extra in (
            (("plan",), set()),
            (("apply",), {"selections"}),
            (("verify",), set()),
            (("verify", "--health"), {"verification"}),
        ):
            with self.subTest(arguments=arguments):
                _, result = self.cli(*arguments)
                self.assertEqual(set(result), common | extra)
                self.assertEqual(result["schema"], 1)
                self.assertEqual(
                    set(result["observed"]), {"globalSelections", "installed"}
                )
                for row in result["runtimes"]:
                    self.assertLessEqual(
                        {"language", "version", "path", "owner", "state"},
                        set(row),
                    )
                    self.assertIn(
                        row["state"],
                        (
                            "missing",
                            "present",
                            "ok",
                            "conflict",
                            "blocked",
                            "external",
                        ),
                    )

    def test_saved_selection_applies_until_replaced_or_ignored(self):
        saved = self.root / "home/.config/dev-bootstrap/selection.json"
        fixture = {"node", "python", "ocaml"}
        # The fixture installs first: the CLI's own adapters are real.
        self.setup.apply()
        code, result = self.cli("plan", "--save-selection")
        self.assertEqual((code, result["selection"]), (0, {"source": "only"}))
        self.assertEqual(
            json.loads(saved.read_text()),
            {"schema": 1, "ecosystems": ["node", "python", "ocaml"]},
        )
        self.assertEqual(saved.stat().st_mode & 0o077, 0)
        # Every action without --only uses it, apply included; without it
        # they would select every default ecosystem.
        for action in ("plan", "apply", "verify"):
            with self.subTest(action=action):
                _, result = self.cli(action, scoped=False)
                self.assertEqual(
                    result["selection"],
                    {"source": "file", "path": str(saved)},
                )
                self.assertEqual(
                    {row["language"] for row in result["runtimes"]}, fixture
                )
        _, _, errors = self.cli_output("plan")
        self.assertIn(f"selection saved in {saved}", errors)
        # --only replaces it for one run, --all ignores it.
        self.scope(["python"])
        _, result = self.cli("plan")
        self.assertEqual(result["selection"], {"source": "only"})
        self.assertEqual(
            {row["language"] for row in result["runtimes"]}, {"python"}
        )
        _, result = self.cli("plan", "--all", scoped=False)
        self.assertEqual(result["selection"], {"source": "all"})
        self.assertLess(
            fixture, {row["language"] for row in result["runtimes"]}
        )
        self.assertTrue(saved.is_file())
        # --all --save-selection forgets it.
        self.cli("plan", "--all", "--save-selection", scoped=False)
        self.assertFalse(saved.exists())
        _, result = self.cli("plan", scoped=False)
        self.assertEqual(result["selection"], {"source": "default"})

    def test_unusable_saved_selection_names_the_file(self):
        saved = self.root / "home/.config/dev-bootstrap/selection.json"
        saved.parent.mkdir(parents=True)
        for content, message in (
            ({"schema": 1, "ecosystems": ["node", "cobol"]}, "cobol"),
            ({"schema": 2, "ecosystems": ["node"]}, "schema 1"),
            ({"schema": 1, "ecosystems": []}, "non-empty"),
            ({"schema": 1, "ecosystems": ["kotlin"]}, "requires jvm"),
        ):
            with self.subTest(content=content):
                saved.write_text(json.dumps(content))
                code, text, errors = self.cli_output("plan")
                self.assertEqual((code, text), (2, ""))
                self.assertIn(message, errors)
                self.assertIn(str(saved), errors)
        # --all never reads it.
        code, _ = self.cli("plan", "--all", scoped=False)
        self.assertEqual(code, 0)

    def test_declared_selection_is_read_but_never_replaced(self):
        declared = self.root / "declared.json"
        declared.write_text(json.dumps({"schema": 1, "ecosystems": ["ocaml"]}))
        saved = self.root / "home/.config/dev-bootstrap/selection.json"
        saved.parent.mkdir(parents=True)
        saved.symlink_to(declared)
        _, result = self.cli("plan", scoped=False)
        self.assertEqual(
            {row["language"] for row in result["runtimes"]}, {"ocaml"}
        )
        for arguments in (("--only", "node"), ("--all",)):
            with self.subTest(arguments=arguments):
                code, _, errors = self.cli_output(
                    "plan", *arguments, "--save-selection"
                )
                self.assertEqual(code, 2)
                self.assertIn("where it is declared", errors)
                self.assertTrue(saved.is_symlink())

    def test_save_selection_needs_a_choice_to_save(self):
        with (
            self.assertRaises(SystemExit) as raised,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.cli_output("plan", "--save-selection")
        self.assertEqual(raised.exception.code, 2)
        with (
            self.assertRaises(SystemExit),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.cli_output("plan", "--all", "--only", "node")

    def test_broken_compiled_runtimes_report_a_rebuild(self):
        self.setup.apply()
        canaries = []

        # A host library upgrade breaks the selected Python's extension
        # modules and the selected switch's bytecode runtime.
        def broken(args):
            if "import ssl" in " ".join(args):
                canaries.append(args[-1])
                return True
            return Path(args[0]).name == "ocamlrun"

        self.failure = broken
        code, result = self.cli("verify", "--health")
        self.assertEqual(code, 1)
        rows = {row["language"]: row for row in result["runtimes"]}
        python = self.data["defaults"]["python"]
        switch = "lcs-ocaml-" + self.data["defaults"]["ocaml"]
        for language, remedy in (
            ("python", f"pyenv install --force {python}"),
            ("ocaml", f"opam switch reinstall {switch}"),
        ):
            with self.subTest(language=language):
                self.assertEqual(rows[language]["state"], "conflict")
                self.assertEqual(rows[language]["remediation"], remedy)
        self.assertEqual(rows["node"]["state"], "ok")
        self.assertNotIn("remediation", rows["node"])
        # Health loads every extension module that links a host library.
        imported = set(canaries[0].removeprefix("import ").split(", "))
        self.assertLessEqual(
            {"ssl", "sqlite3", "ctypes", "readline", "lzma", "bz2", "zlib"},
            imported,
        )
        local = {"path": str(self.root / "project/_opam/bin/ocamlc")}
        self.assertEqual(
            self.recovery.adapter("ocaml").remediation(local),
            ["opam", "switch", "reinstall", str(self.root / "project")],
        )

    def test_interrupted_installation_is_discarded_and_retried(self):
        release = self.data["ocaml"]["versions"][0]
        seed = self.opam / f"lcs-ocaml-{release}"
        self.interrupt = ("ocaml", release)
        with self.assertRaises(KeyboardInterrupt):
            self.setup.apply()
        self.assertTrue((seed / "partial").is_dir())
        row = next(
            r
            for r in self.recovery.plan()
            if (r["language"], r["version"]) == ("ocaml", release)
        )
        self.assertEqual((row["state"], row["interrupted"]), ("missing", True))
        self.interrupt = None
        self.events.clear()
        self.setup.apply()
        self.assertIn(("runtime", "ocaml", release), self.events)
        self.assertFalse((seed / "partial").exists())
        self.assertEqual(self.recovery.interrupted(), frozenset())
        # A record without its prefix is dropped before it can vouch for a
        # directory someone else creates there later.
        self.recovery.journal(self.opam / "vanished", started=True)
        self.setup.apply()
        self.assertEqual(self.recovery.interrupted(), frozenset())
        # A prefix the journal does not name stays the user's to inspect.
        (seed / "bin/ocamlc").unlink()
        state = next(
            r["state"]
            for r in self.recovery.plan()
            if (r["language"], r["version"]) == ("ocaml", release)
        )
        self.assertEqual(state, "conflict")
        with self.assertRaisesRegex(BootstrapError, "incomplete runtimes"):
            self.setup.apply()
        self.assertTrue(seed.is_dir())

    def test_earlier_release_state_moves_once(self):
        # Releases before the rename kept the journal, lock and cache under
        # "devrestore": a plan reads them there, the first apply moves them.
        release = self.data["ocaml"]["versions"][0]
        self.interrupt = ("ocaml", release)
        with self.assertRaises(KeyboardInterrupt):
            self.setup.apply()
        state, cache = self.root / "state", self.root / "cache"
        (state / "dev-bootstrap").rename(state / "devrestore")
        (cache / "devrestore").mkdir(mode=0o700, parents=True)
        (cache / "devrestore/kept").write_text("cached\n")
        row = next(
            r
            for r in self.recovery.plan()
            if (r["language"], r["version"]) == ("ocaml", release)
        )
        self.assertEqual((row["state"], row["interrupted"]), ("missing", True))
        self.assertFalse((state / "dev-bootstrap").exists())
        self.interrupt = None
        self.events.clear()
        self.setup.apply()
        self.assertIn(("runtime", "ocaml", release), self.events)
        self.assertFalse((state / "devrestore").exists())
        self.assertTrue((state / "dev-bootstrap/apply.lock").is_file())
        self.assertEqual(self.recovery.interrupted(), frozenset())
        self.assertTrue((cache / "dev-bootstrap/kept").is_file())
        # Only an earlier release recreates the old name; we leave it be.
        (state / "devrestore").mkdir(mode=0o700)
        self.setup.apply()
        self.assertEqual(list((state / "devrestore").iterdir()), [])

    def test_lock_held_by_an_earlier_release_still_excludes(self):
        legacy = self.root / "state/devrestore"
        legacy.mkdir(mode=0o700, parents=True)
        descriptor = os.open(
            legacy / "apply.lock", os.O_CREAT | os.O_RDWR, 0o600
        )
        with os.fdopen(descriptor, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(BootstrapError, "Another recovery"):
                with self.recovery.locked():
                    pass
        self.assertFalse(legacy.exists())
        with self.recovery.locked():
            pass

    def test_redirected_earlier_release_state_is_refused(self):
        target = self.root / "elsewhere"
        target.mkdir(mode=0o700)
        (self.root / "state").mkdir()
        (self.root / "state/devrestore").symlink_to(target)
        with self.assertRaisesRegex(BootstrapError, "symlink"):
            with self.recovery.locked():
                pass
        self.assertFalse((self.root / "state/dev-bootstrap").exists())

    def test_switch_with_the_declared_compiler_is_adopted(self):
        first, second = self.data["ocaml"]["versions"]
        # `work` resolved its invariant to the second compiler; `loose` has
        # the first one installed but no compiler in its invariant.
        for name, version, invariant in (
            ("work", second, f'compiler: ["ocaml-base-compiler.{second}"]\n'),
            ("loose", first, ""),
        ):
            switch = self.opam / name
            (switch / ".opam-switch").mkdir(parents=True)
            (switch / ".opam-switch/switch-state").write_text(
                invariant + f'installed: ["ocaml-base-compiler.{version}"]\n'
            )
            self.executable(switch / "bin/ocamlc")
            self.versions[str(switch / "bin/ocamlc")] = version
        (self.opam / "config").write_text('switch: "loose"\n')
        rows = {
            row["version"]: row
            for row in self.recovery.plan()
            if row["language"] == "ocaml"
        }
        self.assertEqual(
            rows[second]["path"], str(self.opam / "work/bin/ocamlc")
        )
        self.assertEqual(rows[second]["state"], "present")
        seed = self.opam / f"lcs-ocaml-{first}/bin/ocamlc"
        self.assertEqual(rows[first]["path"], str(seed))
        self.events.clear()
        self.setup.apply()
        self.assertEqual(
            [
                event
                for event in self.events
                if event[:2] == ("runtime", "ocaml")
            ],
            [("runtime", "ocaml", first)],
        )
        self.assertEqual(
            (self.opam / "config").read_text(), 'switch: "loose"\n'
        )
        self.assertEqual(self.recovery.verify(rows[second]), second)

    def test_evolved_runtime_and_defaults_are_preserved(self):
        self.setup.apply()
        python = self.pyenv / "versions/next/bin/python"
        self.executable(python)
        self.versions[str(python)] = "3.15.1"
        (self.pyenv / "version").write_text("next\n")
        baseline = next(
            r for r in self.recovery.plan() if r["language"] == "python"
        )
        self.versions[baseline["path"]] = "3.14.8"
        project = self.root / "project/.python-version"
        project.parent.mkdir()
        project.write_text("project-specific\n")
        self.events.clear()
        self.setup.apply()
        self.assertEqual(self.mutations(), [])
        self.assertEqual((self.pyenv / "version").read_text(), "next\n")
        self.assertEqual(project.read_text(), "project-specific\n")
        self.assertTrue(python.exists())
        healthy = next(
            r for r in self.setup.health() if r["language"] == "python"
        )
        self.assertEqual(self.recovery.verify(healthy, exact=False), "3.15.1")
        with self.assertRaisesRegex(BootstrapError, "identity mismatch"):
            self.recovery.verify(baseline)

    def test_older_selections_are_verified_without_a_floor(self):
        self.setup.apply()
        older = {"node": "22.11.0", "python": "3.13.5", "ocaml": "4.14.2"}
        node = self.fnm / f"node-versions/v{older['node']}/installation"
        python = self.pyenv / "versions" / older["python"]
        switch = self.opam / "older-switch"
        for language, prefix, executable in (
            ("node", node, "bin/node"),
            ("python", python, "bin/python"),
            ("ocaml", switch, "bin/ocamlc"),
        ):
            self.executable(prefix / executable)
            self.versions[str(prefix / executable)] = older[language]
        alias = self.fnm / "aliases/default"
        alias.unlink()
        alias.symlink_to(node)
        (self.pyenv / "version").write_text(older["python"] + "\n")
        (self.opam / "config").write_text('switch: "older-switch"\n')
        before = self.selection_files()
        self.events.clear()
        selections = self.setup.apply()
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.selection_files(), before)
        self.assertEqual(self.probe, ["node", "python", "ocaml"])
        for row in selections:
            with self.subTest(language=row["language"]):
                self.assertEqual(row["state"], "ok")
                self.assertEqual(row["actualVersion"], older[row["language"]])

    def test_system_selections_are_external_and_do_not_block_apply(self):
        self.setup.apply()
        alias = self.fnm / "aliases/default"
        alias.unlink()
        alias.symlink_to(FNM_SYSTEM_TARGET)
        (self.pyenv / "version").write_text("system\n")
        before = self.selection_files()
        self.events.clear()
        selections = self.setup.apply()
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.selection_files(), before)
        states = {row["language"]: row["state"] for row in selections}
        self.assertEqual(
            states, {"node": "external", "python": "external", "ocaml": "ok"}
        )
        # Delegated runtimes have no expected executable in the fresh shell.
        self.assertEqual(self.probe, ["ocaml"])
        code, report = self.cli("verify", "--health")
        self.assertEqual(code, 0)
        self.assertEqual(
            {row["language"]: row["state"] for row in report["runtimes"]},
            states,
        )

    def test_unavailable_selection_is_reported_without_failing_apply(self):
        self.setup.apply()
        (self.pyenv / "version").write_text("removed\n")
        code, report = self.cli("apply")
        self.assertEqual(code, 0)
        python = next(
            row for row in report["selections"] if row["language"] == "python"
        )
        self.assertEqual(python["state"], "blocked")
        self.assertIn("unavailable", python["reason"])
        self.assertEqual(self.probe, ["node", "ocaml"])
        self.assertEqual((self.pyenv / "version").read_text(), "removed\n")
        code, _ = self.cli("verify", "--health")
        self.assertEqual(code, 1)

    def test_plan_and_health_are_read_only(self):
        before = sorted(str(p) for p in self.root.rglob("*"))
        for operation in (self.setup.plan, self.setup.health):
            with self.subTest(operation=operation.__name__):
                operation()
                self.assertEqual(self.events, [])
                self.assertEqual(
                    before, sorted(str(p) for p in self.root.rglob("*"))
                )

    def test_unparseable_opam_selection_is_preserved(self):
        self.setup.apply()
        config = self.opam / "config"
        config.write_text("switch: malformed-selection\n")
        self.events.clear()
        with self.assertRaisesRegex(
            BootstrapError, "existing opam global selection"
        ):
            self.setup.apply()
        self.assertEqual(config.read_text(), "switch: malformed-selection\n")
        self.assertEqual(self.mutations(), [])

    def test_existing_python_prefix_recovers_missing_shim(self):
        self.setup.apply()
        shim = self.pyenv / "shims/python"
        shim.unlink(missing_ok=True)
        self.events.clear()
        self.setup.apply()
        self.assertTrue(shim.is_file())
        self.assertEqual(self.mutations(), [])
        self.assertEqual(sum("rehash" in e for e in self.events), 1)
        self.events.clear()
        self.setup.apply()
        self.assertFalse(any("rehash" in e for e in self.events))

    def test_missing_foundation_or_sdk_precedes_package_mutation(self):
        self.failure = lambda args: Path(args[0]).name == "xcrun"
        for missing in (
            {"packageManager": str(self.bin / "absent-brew")},
            {"sdkProbe": [str(self.bin / "xcrun")]},
        ):
            with (
                self.subTest(missing=missing),
                patch.dict(self.setup.recipe, missing),
            ):
                with self.assertRaisesRegex(BootstrapError, "prerequisites"):
                    self.setup.apply()
                self.assertEqual(self.mutations(), [])

    def test_unknown_python_definition_fails_before_installation(self):
        self.scope(["python"])
        self.definitions = ["3.13.5"]
        with self.assertRaisesRegex(BootstrapError, "upgrade pyenv"):
            self.setup.apply()
        self.assertNotIn("runtime", [event[0] for event in self.events])
        self.assertFalse((self.pyenv / "versions").exists())

    def test_partial_prefix_blocks_provisioning(self):
        row = self.recovery.adapter("python").baseline()[0]
        Path(row["path"]).parent.mkdir(parents=True)
        with self.assertRaisesRegex(BootstrapError, "incomplete"):
            self.setup.apply()
        self.assertEqual(self.mutations(), [])

    def test_root_executor_is_rejected(self):
        with (
            patch.object(os, "geteuid", return_value=0),
            self.assertRaisesRegex(BootstrapError, "never as root"),
        ):
            self.setup.apply()
        self.assertEqual(self.events, [])

    def test_lock_covers_native_provisioning(self):
        writable_directory(self.recovery.state)
        with (self.recovery.state / "apply.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(BootstrapError, "Another recovery"):
                self.setup.apply()
        self.assertEqual(self.events, [])

    def test_package_failure_can_retry(self):
        self.failure = lambda args: "install" in args
        with self.assertRaisesRegex(BootstrapError, "prerequisites"):
            self.setup.apply()
        self.assertFalse(self.pyenv.exists())
        self.failure = None
        self.setup.apply()
        self.assertTrue(
            all(r["state"] == "present" for r in self.setup.health())
        )

    def test_unlinked_but_installed_formulae_do_not_fail_the_stage(self):
        self.unlinked = {"sqlite"}
        self.setup.prerequisites()
        self.assertIn("sqlite", self.installed)
        installs = [event for event in self.events if "--formula" in event]
        self.assertEqual(
            [event[1] for event in installs], ["list", "install", "list"]
        )
        # A package the failed command did not install still fails it.
        self.installed.clear()
        (self.bin / "pyenv").unlink()
        self.uninstallable = {"pyenv"}
        with self.assertRaisesRegex(BootstrapError, "brew link"):
            self.setup.prerequisites()

    def test_arch_accepts_installed_dependency_providers(self):
        self.scope(["python"])
        self.data["setup"].update(
            packageManager=str(self.bin / "pacman"),
            query=["-Qq"],
            missingQuery=["-T"],
            install=["-S", "--needed", "--noconfirm"],
            privilege=["sudo", "-n"],
            buildPackages={"python": ["zlib"]},
        )
        self.executable(self.bin / "pacman")
        self.executable(self.bin / "pyenv")
        self.installed = {"pyenv", "zlib-ng-compat"}
        self.provided = {"zlib"}
        self.setup.prerequisites()
        self.assertFalse(any("-S" in event for event in self.events))

    def test_dependency_query_rejects_unrequested_packages(self):
        self.scope(["python"])
        self.data["setup"]["missingQuery"] = ["-T"]
        with (
            patch.object(process, "run", return_value="unexpected-package"),
            self.assertRaisesRegex(
                BootstrapError, "Unexpected native dependency"
            ),
        ):
            self.setup.prerequisites()
        self.assertFalse(any("-S" in event for event in self.events))

    def test_dependency_exit_status_is_scoped_to_the_query(self):
        for code, accepted in ((127, (0, 127)), (127, (0,)), (1, (0, 127))):
            result = subprocess.CompletedProcess([], code, "zlib\n", "")
            with (
                self.subTest(code=code, accepted=accepted),
                patch("core.process.complete", return_value=result),
            ):
                if code in accepted:
                    self.assertEqual(
                        self.actual_run(["fixture"], success_codes=accepted),
                        "zlib",
                    )
                else:
                    with self.assertRaisesRegex(
                        BootstrapError, f"exited {code}"
                    ):
                        self.actual_run(["fixture"], success_codes=accepted)

    def test_failure_reports_both_output_tails(self):
        stdout = "x" * 3000 + "Target /opt/homebrew/bin/idle3 already exists"
        result = subprocess.CompletedProcess(
            [], 1, stdout, "Error: The `brew link` step did not complete\n"
        )
        with (
            patch("core.process.complete", return_value=result),
            self.assertRaises(BootstrapError) as raised,
        ):
            self.actual_run(["brew"])
        message = str(raised.exception)
        self.assertIn("exited 1: Error: The `brew link` step", message)
        self.assertIn("\nstdout: ", message)
        self.assertTrue(message.endswith("bin/idle3 already exists"))
        self.assertLess(len(message), 4200)
        quiet = subprocess.CompletedProcess([], 1, "\n", "failed\n")
        with (
            patch("core.process.complete", return_value=quiet),
            self.assertRaises(BootstrapError) as raised,
        ):
            self.actual_run(["fixture"])
        self.assertEqual(str(raised.exception), "fixture exited 1: failed")

    def test_native_build_environment_is_scoped_to_source_compilation(self):
        self.data["setup"]["buildEnvironment"] = {
            "CC": "/fixture/native/cc",
            "PATH": "/fixture/native",
        }
        row = next(
            r for r in self.recovery.plan() if r["language"] == "python"
        )
        self.executable(self.bin / "pyenv")
        self.executable(self.bin / "opam")
        calls = []

        def record(args, **kwargs):
            calls.append((args, kwargs))
            return self.mock_run(args, **kwargs)

        with patch.object(process, "run", record):
            PythonAdapter.install(self.recovery.adapter("python"), row)
        # Execute the real OCaml install path. Only subprocesses and the
        # compiled-runtime canary are substituted; no duplicate opam simulator.
        writable_directory(self.recovery.state)
        writable_directory(self.opam)
        (self.opam / "config").touch()

        def opam_process(args, **kwargs):
            calls.append((args, kwargs))
            return ""

        # An adopted switch that lost its compiler is left alone: the seed is
        # created beside it, and the row then describes the seed.
        release = self.data["ocaml"]["versions"][0]
        adopted = self.opam / "adopted/.opam-switch"
        adopted.mkdir(parents=True)
        (adopted / "switch-state").write_text(
            f'compiler: ["ocaml-base-compiler.{release}"]\n'
        )
        row = next(r for r in self.recovery.plan() if r["language"] == "ocaml")
        self.assertEqual(row["path"], str(self.opam / "adopted/bin/ocamlc"))
        seed = self.opam / f"lcs-ocaml-{release}"
        with (
            patch.object(process, "run", opam_process),
            patch.object(OcamlAdapter, "verify"),
        ):
            OcamlAdapter.install(self.recovery.adapter("ocaml"), row)
        builder = next(
            k
            for a, k in calls
            if Path(a[0]).name == "pyenv" and a[1] == "install"
        )
        ocaml_build = next(
            k for a, k in calls if a[1:3] == ["switch", "create"]
        )
        created = next(a for a, k in calls if a[1:3] == ["switch", "create"])
        self.assertEqual(created[3], seed.name)
        self.assertEqual(row["path"], str(seed / "bin/ocamlc"))
        for language, invocation in (
            ("python", builder),
            ("ocaml", ocaml_build),
        ):
            with self.subTest(language=language):
                self.assertTrue(invocation.get("source_build"))
                self.assertIsInstance(invocation.get("env"), dict)
                for key, value in self.data["setup"][
                    "buildEnvironment"
                ].items():
                    self.assertEqual(invocation["env"][key], value)
        rehash = next(k for a, k in calls if "rehash" in a)
        self.assertNotIn("CC", rehash["env"])
        self.assertNotIn("PATH", rehash["env"])
        self.assertNotEqual(os.environ.get("CC"), "/fixture/native/cc")

    def test_source_build_child_environment(self):
        pollution = dict.fromkeys(
            (
                "CPATH",
                "CFLAGS",
                "CPPFLAGS",
                "LDFLAGS",
                "PKG_CONFIG_PATH",
                "SDKROOT",
                "DEVELOPER_DIR",
                "NIX_CFLAGS_COMPILE",
                "CC",
            ),
            "/project/foreign",
        )
        # A real child observes the effective environment; no subprocess mock.
        command = [
            sys.executable,
            "-I",
            "-c",
            "import json, os; print(json.dumps(dict(os.environ)))",
        ]
        with patch.dict(
            os.environ, pollution | {"HTTPS_PROXY": "http://proxy"}
        ):
            for building in (False, True):
                with self.subTest(source_build=building):
                    observed = json.loads(
                        self.actual_run(
                            command,
                            source_build=building,
                            env={
                                "CC": "/declared/cc",
                                "SDKROOT": "/declared/sdk",
                            },
                        )
                    )
                    for key in pollution.keys() - {"CC", "SDKROOT"}:
                        self.assertEqual(key in observed, not building, key)
                    self.assertEqual(observed["CC"], "/declared/cc")
                    self.assertEqual(observed["SDKROOT"], "/declared/sdk")
                    self.assertEqual(observed["HTTPS_PROXY"], "http://proxy")
                    self.assertEqual(os.environ["CC"], "/project/foreign")

    def test_manager_routes_agree_with_runtime_execution(self):
        self.scope(["python"])
        writable_directory(self.pyenv)
        checkout = self.pyenv / "bin/pyenv"
        canonical = self.bin / "pyenv"
        for installed in ((canonical,), (checkout,), (canonical, checkout)):
            with self.subTest(installed=installed):
                for path in (canonical, checkout):
                    path.unlink(missing_ok=True)
                for path in installed:
                    self.executable(path)
                expected = checkout if checkout in installed else canonical
                (self.pyenv / "version").unlink(missing_ok=True)
                self.events.clear()
                self.setup.readiness()
                self.setup.defaults()
                PythonAdapter.install(
                    self.recovery.adapter("python"), self.recovery.plan()[0]
                )
                invocations = [
                    e for e in self.events if Path(e[0]).name == "pyenv"
                ]
                self.assertEqual({e[0] for e in invocations}, {str(expected)})
                self.assertEqual(
                    {e[1] for e in invocations},
                    {"--version", "global", "install", "rehash"},
                )

    def test_default_failure_preserves_completed_work_on_retry(self):
        self.failure = lambda args: (
            Path(args[0]).name == "pyenv" and "global" in args
        )
        with self.assertRaisesRegex(BootstrapError, "defaults"):
            self.setup.apply()
        node = self.fnm / "aliases/default"
        before = os.readlink(node)
        self.failure = None
        self.events.clear()
        self.setup.apply()
        self.assertEqual(os.readlink(node), before)
        self.assertFalse(any(event[0] == "runtime" for event in self.events))
        self.assertFalse(any("default" in event for event in self.events))

    def test_conflicting_fnm_link_is_not_rewritten(self):
        self.executable(self.bin / "fnm")
        writable_directory(self.fnm)
        link = self.fnm / "fnm"
        link.symlink_to(self.bin / "other-fnm")
        with self.assertRaisesRegex(BootstrapError, "readiness"):
            self.setup.apply()
        self.assertEqual(os.readlink(link), str(self.bin / "other-fnm"))

    def test_shadowed_shell_runtime_fails(self):
        self.shadow = True
        with self.assertRaisesRegex(BootstrapError, "shell"):
            self.setup.apply()
        self.assertTrue((self.pyenv / "version").is_file())

    def test_arch_privilege_is_scoped_to_missing_packages(self):
        self.data["setup"].update(
            query=["-Qq"],
            missingQuery=["-T"],
            install=["-S", "--needed", "--noconfirm"],
            privilege=[str(self.bin / "sudo"), "-n"],
        )
        self.setup.apply()
        installation = next(e for e in self.events if "-S" in e)
        self.assertEqual(installation[:2], (str(self.bin / "sudo"), "-n"))
        self.assertNotIn("-Sy", installation)
        self.assertNotIn("-Syu", installation)

    def test_uncached_privilege_names_the_command_before_mutation(self):
        self.data["setup"].update(
            query=["-Qq"],
            missingQuery=["-T"],
            install=["-S", "--needed", "--noconfirm"],
            privilege=[str(self.bin / "sudo"), "-n"],
        )
        self.failure = lambda args: args[-1] == "/usr/bin/true"
        with self.assertRaisesRegex(BootstrapError, "sudo -v") as raised:
            self.setup.prerequisites()
        self.assertIn("sudo " + str(self.bin / "brew"), str(raised.exception))
        self.assertFalse(any("-S" in event for event in self.events))

    def test_interrupted_apply_releases_the_lock_and_stops_its_child(self):
        # The package manager hangs with a child of its own, as a build does.
        pidfile = self.root / "worker.pid"
        (self.bin / "brew").write_text(
            f'#!/bin/sh\n"{SLEEP}" 60 & echo $! > "{pidfile}"; wait\n'
        )
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps(self.data))
        lock = self.root / "state/dev-bootstrap/apply.lock"
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum.name):
                pidfile.unlink(missing_ok=True)
                command = subprocess.Popen(
                    [
                        sys.executable,
                        str(implementation / "bootstrap.py"),
                        "--manifest",
                        str(manifest),
                        "apply",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                deadline = time.monotonic() + 30
                while not pidfile.is_file() or not pidfile.read_text():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                worker = int(pidfile.read_text())
                command.send_signal(signum)
                _, stderr = command.communicate(timeout=60)
                self.assertEqual(command.returncode, 128 + signum, stderr)
                self.assertIn("interrupted during prerequisites", stderr)
                self.assertNotIn("Traceback", stderr)
                self.assertTrue(gone(worker))
                with lock.open("a") as file:
                    fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_cli_import_preserves_structured_stage_errors(self):
        (self.bin / "brew").unlink()
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps(self.data))
        result = subprocess.run(
            [
                sys.executable,
                str(implementation / "bootstrap.py"),
                "--manifest",
                str(manifest),
                "apply",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("prerequisites:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
