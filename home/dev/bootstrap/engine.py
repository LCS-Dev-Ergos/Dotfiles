"""Inspect runtime state and coordinate explicit, serialized bootstrap work."""

import fcntl
import os
import re
import stat
import tempfile
from contextlib import contextmanager
from pathlib import Path
from native_toolchains import LANGUAGES, NativeToolchains
from support import (
    BootstrapError,
    run,
    root_path,
    writable_directory,
    checksum_support,
    native_command,
)
from manifest import version
from seed import SeedRuntimes
from ocaml import OcamlBootstrap
from retention import retain_opam_source

MANAGERS = {"node": "fnm", "python": "pyenv", "ocaml": "opam", **LANGUAGES}
# The declared baseline must provide every extension module python-build
# compiles from the retained sources, including 3.14's Zstandard support.
PYTHON_BUILD_CANARY = (
    "import ssl, sqlite3, bz2, lzma, ctypes, readline, tkinter, venv; "
    "import zlib, compression.zstd as zstd; "
    "assert zstd.decompress(zstd.compress(b'bootstrap')) == b'bootstrap'; "
    "db = sqlite3.connect(':memory:'); "
    "assert db.execute('select 2').fetchone() == (2,)"
)
# A selected Python, of any release, needs what package installation uses.
PYTHON_HEALTH_CANARY = "import ssl, venv, zlib"


class Bootstrap:
    """Coordinate native ecosystem adapters behind one explicit interface."""

    def __init__(self, manifest, only):
        self.data = manifest
        self.only = only or [
            "node",
            "python",
            "ocaml",
            *manifest.get("nativeToolchains", {}),
        ]
        if any(
            language in LANGUAGES
            and language not in manifest.get("nativeToolchains", {})
            for language in self.only
        ):
            raise BootstrapError(
                "Selected native toolchain is absent from the baseline"
            )
        home = Path.home()
        self.fnm = root_path(
            "FNM_DIR",
            Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share")
            / "fnm",
        )
        self.pyenv = root_path("PYENV_ROOT", home / ".pyenv")
        self.opam = root_path("OPAMROOT", home / ".opam")
        self.cache = (
            root_path("XDG_CACHE_HOME", home / ".cache") / "devrestore"
        )
        self.state = (
            root_path("XDG_STATE_HOME", home / ".local/state") / "devrestore"
        )
        self.native = NativeToolchains(self, root_path, run, BootstrapError)

        self.seed = SeedRuntimes(self)
        self.ocaml = OcamlBootstrap(self)

    def manager(self, language):
        """Resolve the native executable once by the production shell's rules.

        A pyenv checkout owns its command before the host package profile.
        FNM's local link exposes the canonical command; readiness detects
        conflicting links. Manifests without setup retain PATH discovery.
        """
        name = MANAGERS[language]
        if language in LANGUAGES:
            return self.native.manager(language)
        recipe = self.data.get("setup")
        if not recipe:
            return Path(native_command(name))
        canonical = (
            Path(recipe["managerDirectory"]) / recipe["managers"][language]
        )
        candidates = {
            "python": (self.pyenv / "bin/pyenv", canonical),
            "node": (canonical, self.fnm / "fnm"),
            "ocaml": (canonical,),
        }[language]
        for candidate in candidates:
            if candidate.is_file() and os.access(candidate, os.X_OK):
                if candidate.resolve().is_relative_to(Path("/nix/store")):
                    raise BootstrapError(
                        f"Native {name} resolves into the Nix store: {candidate}"
                    )
                return candidate
        raise BootstrapError(f"Native {name} is unavailable at {canonical}")

    def entries(self):
        entries = []
        for release in self.data["node"]:
            entries.append(
                (
                    "node",
                    release["version"],
                    self.fnm
                    / "node-versions"
                    / f"v{release['version']}"
                    / "installation/bin/node",
                )
            )
        release = self.data["python"]["version"]
        entries.append(
            (
                "python",
                release,
                self.pyenv / "versions" / release / "bin/python",
            )
        )
        for release in self.data["ocaml"]["versions"]:
            entries.append(
                (
                    "ocaml",
                    release,
                    self.opam / f"lcs-ocaml-{release}" / "bin/ocamlc",
                )
            )
        return [entry for entry in entries if entry[0] in self.only]

    def plan(self):
        """Inspect paths only. Present means installed, not yet validated."""
        rows = []
        for language, release, executable in self.entries():
            row = {
                "language": language,
                "version": release,
                "path": str(executable),
            }
            if (
                self.data["backend"] == "native"
                and Path("/etc/NIXOS").exists()
            ):
                row.update(
                    state="blocked",
                    reason="NixOS requires the explicit nixpkgs backend",
                )
            elif self.data["backend"] == "nixpkgs":
                runtime = self.data.get("nixRuntimes", {}).get(
                    f"{language}-{release}", {}
                )
                if (
                    runtime.get("version") == release
                    and Path(runtime.get("path", "")).is_file()
                ):
                    row.update(
                        state="present",
                        path=runtime["path"],
                        owner="nixpkgs",
                        isolated=runtime.get("isolated", True),
                    )
                else:
                    row.update(
                        state="blocked",
                        reason="No exact qualified nixpkgs runtime in this baseline",
                    )
            elif executable.is_file():
                row.update(
                    state="present",
                    owner=MANAGERS[language],
                )
                if (
                    language == "ocaml"
                    and self.ocaml.read_pending(row) is not None
                ):
                    row["reason"] = (
                        "Repository handover pending; apply resumes owned work"
                    )
            elif os.path.lexists(
                executable.parents[2 if language == "node" else 1]
            ):
                row.update(
                    state="conflict",
                    reason="Existing incomplete runtime; manual inspection required",
                )
            else:
                try:
                    for command in self.data["policy"]["prerequisites"][
                        language
                    ]:
                        if command == MANAGERS[language]:
                            self.manager(language)
                        else:
                            native_command(command)
                    row.update(state="missing")
                except BootstrapError as error:
                    row.update(state="blocked", reason=str(error))
            rows.append(row)
        return rows + self.native.plan()

    def observed_state(self):
        """Report global selectors and additional versions without evaluating them."""
        node_alias = self.fnm / "aliases/default"
        defaults = {
            "node": os.readlink(node_alias)
            if node_alias.is_symlink()
            else None,
            "python": None,
            "ocaml": None,
        }
        if (self.pyenv / "version").is_file():
            defaults["python"] = (
                (self.pyenv / "version").read_text()[:4096].strip()
            )
        if (self.opam / "config").is_file():
            match = re.search(
                r'^switch:\s*"([^"\n]+)"',
                (self.opam / "config").read_text()[:65536],
                re.MULTILINE,
            )
            defaults["ocaml"] = match.group(1) if match else None
        roots = {
            "node": self.fnm / "node-versions",
            "python": self.pyenv / "versions",
            "ocaml": self.opam,
        }
        installed = {
            language: sorted(
                path.name
                for path in root.iterdir()
                if path.is_dir()
                and not path.name.startswith(".")
                and (language != "ocaml" or (path / ".opam-switch").is_dir())
            )
            if root.is_dir()
            else []
            for language, root in roots.items()
        }
        native = self.native.observed()
        return {
            "globalSelections": defaults | native["globalSelections"],
            "installed": installed | native["installed"],
        }

    def verify_runtime(self, row, *, complete=True):
        """Exercise the exact executable, including interpreter/build canaries.

        complete=False checks a selection the bootstrap did not build: it must
        run, not provide the declared baseline's full extension set.
        """
        executable = row["path"]
        language, release = row["language"], row["version"]
        if language in LANGUAGES:
            return self.native.verify(row)
        if language == "node":
            actual = run([executable, "--version"])
            if actual != f"v{release}":
                raise BootstrapError(f"Node identity mismatch: {actual}")
            run([executable, "-e", "if (1 + 1 !== 2) process.exit(1)"])
        elif language == "python":
            # Native interpreters support -I. A Nix Python environment needs
            # its wrapper's controlled PYTHONPATH; run() clears the caller's
            # PYTHONPATH and -P/-s exclude cwd and user-site packages.
            flags = ["-I"] if row.get("isolated", True) else ["-P", "-s"]
            actual = run(
                [
                    executable,
                    *flags,
                    "-B",
                    "-c",
                    "import platform; print(platform.python_version())",
                ]
            )
            if actual != release:
                raise BootstrapError(f"Python identity mismatch: {actual}")
            run(
                [
                    executable,
                    *flags,
                    "-B",
                    "-c",
                    PYTHON_BUILD_CANARY if complete else PYTHON_HEALTH_CANARY,
                ]
            )
        else:
            actual = run([executable, "-version"])
            if actual != release:
                raise BootstrapError(f"OCaml identity mismatch: {actual}")
            with tempfile.TemporaryDirectory(
                prefix="devrestore-ocaml-"
            ) as temporary:
                work = Path(temporary)
                source = work / "hello.ml"
                source.write_text('print_endline "recovery-ok";;\n')
                run([executable, "-o", str(work / "hello"), str(source)])
                actual = run(
                    [
                        str(Path(executable).parent / "ocamlrun"),
                        str(work / "hello"),
                    ]
                )
                if actual != "recovery-ok":
                    raise BootstrapError("OCaml compile/run canary failed")

    def verify_healthy_runtime(self, row):
        """Qualify a selected runtime by execution, with no version floor.

        Native managers own downgrades as well as upgrades. Health asks
        whether the selection works, not whether it reaches the baseline.
        """
        language = row["language"]
        if language in LANGUAGES:
            return self.native.verify(row, exact=False)
        flags = {
            "node": "--version",
            "python": "--version",
            "ocaml": "-version",
        }
        output = run([row["path"], flags[language]])
        match = re.search(r"[0-9]+\.[0-9]+\.[0-9]+", output)
        if not match:
            raise BootstrapError(
                f"Unrecognized {language} runtime identity: {output}"
            )
        actual = version(match.group())
        self.verify_runtime(dict(row, version=actual), complete=False)
        return actual

    def arguments(self, operation, **bindings):
        """Bind runtime paths to literal argv generated by Nix, never shell text."""
        return [
            token.format_map(bindings)
            for token in self.data["policy"]["commands"][operation]
        ]

    @contextmanager
    def locked(self):
        """Serialize runtime, prerequisite and initial-selection mutations."""
        if os.geteuid() == 0:
            raise BootstrapError(
                "Run bootstrap as the owning account, never as root"
            )
        # Validate existing destinations before native installers or package
        # managers can write. Do not pre-create installer-owned directories.
        roots = {"node": self.fnm, "python": self.pyenv, "ocaml": self.opam}
        containers = {"node": "node-versions", "python": "versions"}
        for language in self.only:
            if language in roots:
                writable_directory(roots[language], create=False)
                if language in containers:
                    writable_directory(
                        roots[language] / containers[language], create=False
                    )
        for path in self.native.mutable_directories():
            writable_directory(path, create=False)
        writable_directory(self.cache, create=False)
        writable_directory(self.state)
        descriptor = os.open(
            self.state / "apply.lock",
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(descriptor, "a") as lock:
            info = os.fstat(lock.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or info.st_mode & 0o022
            ):
                raise BootstrapError(
                    "Recovery lock must be a private regular file"
                )
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise BootstrapError(
                    "Another recovery process is running"
                ) from error
            yield

    def apply(self, rows, *, lock_held=False, evolved=False):
        """Preflight every selected runtime; serialize only explicit mutations."""
        if not lock_held:
            with self.locked():
                return self.apply(rows, lock_held=True, evolved=evolved)
        if "ocaml" in self.only:
            retain_opam_source(self)
        if any(row["state"] in ("blocked", "conflict") for row in rows):
            raise BootstrapError(
                "Recovery is blocked; inspect the plan before installing"
            )
        for row in rows:
            if row["state"] == "present":
                if evolved and not (
                    row["language"] == "ocaml" and self.ocaml.read_pending(row)
                ):
                    self.verify_healthy_runtime(row)
                else:
                    self.verify_runtime(row)
        missing = [row for row in rows if row["state"] == "missing"]
        pending = [
            row
            for row in rows
            if row["language"] == "ocaml"
            and self.ocaml.read_pending(row) is not None
        ]
        if not missing and not pending:
            return
        if any(row["language"] == "python" for row in missing):
            checksum_support()
            expected = (
                f"python-build {self.data['python']['pythonBuildVersion']}"
            )
            if run([self.data["python"]["builder"], "--version"]) != expected:
                raise BootstrapError(
                    f"Python recovery requires immutable {expected}"
                )
        # Reinspect after acquiring the lock; ordinary manager invocations
        # do not participate, so each adapter also guards its target.
        fresh = self.plan()
        if any(row["state"] in ("blocked", "conflict") for row in fresh):
            raise BootstrapError("State changed since planning")
        for row in fresh:
            if row["state"] == "missing" or (
                row["language"] == "ocaml"
                and self.ocaml.read_pending(row) is not None
            ):
                installers = {
                    "node": self.seed.install_node,
                    "python": self.seed.install_python,
                    "ocaml": self.ocaml.install,
                }
                installers.get(row["language"], self.native.install)(row)
                self.verify_runtime(row)
