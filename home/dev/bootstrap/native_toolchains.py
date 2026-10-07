"""Native managers own runtime trees; probes never launch download-capable shims."""

import hashlib
import os
import re
import tempfile
import urllib.request
from pathlib import Path

import tomllib
from support import SYSTEM_SELECTION, external_selection, read_json_object

LANGUAGES = {
    "rust": "rustup",
    "haskell": "ghcup",
    "lean": "elan",
    "ruby": "rbenv",
    "jvm": "sdkman",
    "julia": "juliaup",
}
HOSTS = {
    "aarch64-darwin": "aarch64-apple-darwin",
    "x86_64-linux": "x86_64-unknown-linux-gnu",
}
RUNTIME_DIRECTORIES = {
    "rust": "toolchains",
    "haskell": "ghc",
    "lean": "toolchains",
    "ruby": "versions",
    "jvm": "candidates/java",
    "julia": "juliaup",
}
# Fixed program and positional arguments; never interpolate shell source.
SDK_SCRIPT = """source "$1" || exit
shift
sdkman_auto_answer=false
sdkman_auto_env=false
sdkman_selfupdate_feature=false
sdkman_auto_update=false
sdkman_colour_enable=false
USE=n
sdk "$@" <<< n
"""


def validate(data, error):
    for language, spec in data.get("nativeToolchains", {}).items():
        if language not in LANGUAGES:
            raise error("Unsupported native toolchain")
        release_pattern = r"[0-9]+\.[0-9]+\.[0-9]+" + (
            r"(?:\.[0-9]+)?" if language == "jvm" else ""
        )
        if not re.fullmatch(release_pattern, spec["version"]):
            raise error("Native toolchains require exact releases")
        if language == "jvm" and not re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9.]+)?-tem", spec["candidate"]
        ):
            raise error("Invalid SDKMAN Java candidate")
        if language == "haskell" and not re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+", spec["cabal"]
        ):
            raise error("Invalid Cabal release")
    for spec in data.get("setup", {}).get("installers", {}).values():
        if not spec["url"].startswith("https://") or not re.fullmatch(
            r"[a-f0-9]{64}", spec["sha256"]
        ):
            raise error("Native installers require HTTPS and an exact SHA256")


class NativeToolchains:
    def __init__(self, recovery, root_path, run, error):
        self.recovery, self.run, self.error = recovery, run, error
        self.specs = recovery.data.get("nativeToolchains", {})
        self.only = [name for name in recovery.only if name in self.specs]
        home = Path.home()
        base = Path(os.environ.get("GHCUP_INSTALL_BASE_PREFIX", str(home)))
        if "haskell" in self.only and not base.is_absolute():
            raise error("GHCUP_INSTALL_BASE_PREFIX must be absolute")
        definitions = {
            "rust": ("RUSTUP_HOME", home / ".rustup"),
            "cargo": ("CARGO_HOME", home / ".cargo"),
            "haskell": ("GHCUP_INSTALL_BASE_PREFIX", base / ".ghcup"),
            "lean": ("ELAN_HOME", home / ".elan"),
            "ruby": ("RBENV_ROOT", home / ".rbenv"),
            "jvm": ("SDKMAN_DIR", home / ".sdkman"),
            "julia": ("JULIAUP_DEPOT_PATH", home / ".julia"),
            "juliaup": ("JULIAUP_HOME", home / ".juliaup"),
        }
        needed = set(self.only)
        if "rust" in needed:
            needed.add("cargo")
        if "julia" in needed:
            needed.add("juliaup")
        self.roots = {
            name: root_path(
                *definitions[name], from_environment=name != "haskell"
            )
            for name in needed
        }

    def environment(self):
        r = self.roots
        names = {
            "rust": "RUSTUP_HOME",
            "cargo": "CARGO_HOME",
            "haskell": "GHCUP_INSTALL_BASE_PREFIX",
            "lean": "ELAN_HOME",
            "ruby": "RBENV_ROOT",
            "jvm": "SDKMAN_DIR",
            "julia": "JULIAUP_DEPOT_PATH",
            "juliaup": "JULIAUP_HOME",
        }
        return {
            names[key]: str(value.parent if key == "haskell" else value)
            for key, value in r.items()
        }

    def mutable_directories(self):
        """Directories whose ownership must be checked before any apply stage."""
        return [
            *self.roots.values(),
            *(
                self.roots[name] / RUNTIME_DIRECTORIES[name]
                for name in self.only
            ),
        ]

    def manager(self, language):
        root = self.roots[
            {"rust": "cargo", "julia": "juliaup"}.get(language, language)
        ]
        name = LANGUAGES[language]
        candidates = [
            root
            / ("bin/sdkman-init.sh" if language == "jvm" else f"bin/{name}")
        ]
        if language == "ruby":
            candidates.append(
                Path(self.recovery.data["setup"]["managerDirectory"]) / "rbenv"
            )
        for path in candidates:
            if path.is_file() and (
                language == "jvm" or os.access(path, os.X_OK)
            ):
                if path.resolve().is_relative_to(Path("/nix/store")):
                    raise self.error(
                        f"Native {name} resolves into the Nix store: {path}"
                    )
                return path
        raise self.error(f"Native {name} is unavailable at {candidates[0]}")

    @staticmethod
    def lean_directory(selection):
        return selection.replace("/", "--").replace(":", "---")

    def julia_config(self):
        path = self.roots["julia"] / "juliaup/juliaup.json"
        if os.path.lexists(path) and not path.is_file():
            raise self.error("Inspect the existing Julia selector file")
        data = read_json_object(path) if path.is_file() else {}
        for field in ("InstalledVersions", "InstalledChannels"):
            entries = data.get(field, {})
            if not isinstance(entries, dict) or any(
                not isinstance(entry, dict) for entry in entries.values()
            ):
                raise self.error(f"Invalid Julia selector mapping: {field}")
        for entry in data.get("InstalledVersions", {}).values():
            if not any(
                isinstance(entry.get(key), str)
                for key in ("Path", "BinaryPath")
            ):
                raise self.error("Julia runtime has no declared path")
            if any(
                key in entry and not isinstance(entry[key], str)
                for key in ("Path", "BinaryPath")
            ):
                raise self.error("Invalid Julia runtime path")
        return data

    def julia_binary(self, identity=None, channel=None):
        data = self.julia_config()
        if channel:
            identity = (
                data.get("InstalledChannels", {})
                .get(channel, {})
                .get("Version")
            )
            if not identity:
                raise self.error(
                    f"Julia channel has no installed release: {channel}"
                )
        for release, entry in data.get("InstalledVersions", {}).items():
            if release == identity or release.split("+", 1)[0] == identity:
                relative = (
                    entry["BinaryPath"]
                    if "BinaryPath" in entry
                    else str(Path(entry["Path"]) / "bin/julia")
                )
                path = self.roots["julia"] / "juliaup" / relative
                if "BinaryPath" not in entry and not path.is_file():
                    prefix = self.roots["julia"] / "juliaup" / entry["Path"]
                    bundles = list(
                        prefix.glob(
                            "Julia-*.app/Contents/Resources/julia/bin/julia"
                        )
                    )
                    if len(bundles) == 1:
                        path = bundles[0]
                if not path.resolve().is_relative_to(self.roots["julia"]):
                    raise self.error("Julia runtime escapes its native root")
                return path
        return (
            self.roots["julia"]
            / "juliaup"
            / f"missing-{identity}"
            / "bin/julia"
        )

    def binary(self, language, selection=None, component=None):
        spec, root = self.specs[language], self.roots[language]
        release = selection or spec["version"]
        if language == "rust":
            if selection is None:
                release += "-" + HOSTS[self.recovery.data["platform"]]
            return root / "toolchains" / release / "bin/rustc"
        if language == "haskell":
            return (
                root / "bin" / ("cabal-" + spec["cabal"])
                if component == "cabal"
                else root / "ghc" / release / "bin/ghc"
            )
        if language == "lean":
            return (
                root
                / "toolchains"
                / self.lean_directory(
                    selection or "leanprover/lean4:v" + release
                )
                / "bin/lean"
            )
        if language == "ruby":
            return root / "versions" / release / "bin/ruby"
        if language == "jvm":
            return (
                root
                / "candidates/java"
                / (selection or spec["candidate"])
                / "bin/java"
            )
        return self.julia_binary(identity=release)

    def selections(self):
        selected = {}
        for language in self.only:
            root, value = self.roots[language], None
            if language in ("rust", "lean"):
                settings = root / "settings.toml"
                if os.path.lexists(settings) and not settings.is_file():
                    raise self.error(
                        f"Inspect the existing {language} selector file"
                    )
                if settings.is_file():
                    value = tomllib.loads(settings.read_text()).get(
                        "default_toolchain"
                    )
            elif language == "ruby":
                marker = root / "version"
                if marker.is_file():
                    value = marker.read_text().strip()
            elif language in ("haskell", "jvm"):
                marker = root / (
                    "bin/ghc"
                    if language == "haskell"
                    else "candidates/java/current"
                )
                if os.path.lexists(marker):
                    value = str(marker.resolve())
            else:
                value = self.julia_config().get("Default")
            selected[language] = value
            if value is not None and not isinstance(value, str):
                raise self.error(f"Invalid {language} global selection")
        return selected

    def observed(self):
        installed = {
            language: sorted(
                p.name
                for p in (
                    self.roots[language] / RUNTIME_DIRECTORIES[language]
                ).iterdir()
                if p.is_dir()
                and not (language == "jvm" and p.name == "current")
            )
            if (self.roots[language] / RUNTIME_DIRECTORIES[language]).is_dir()
            else []
            for language in self.only
        }
        if "julia" in self.only:
            installed["julia"] = sorted(
                self.julia_config().get("InstalledVersions", {})
            )
        return {
            "globalSelections": self.selections(),
            "installed": installed,
        }

    def plan(self):
        rows = []
        for language in self.only:
            for component in (
                ["ghc", "cabal"] if language == "haskell" else [None]
            ):
                path = self.binary(language, component=component)
                row = {
                    "language": language,
                    "version": self.specs[language][
                        "cabal" if component == "cabal" else "version"
                    ],
                    "path": str(path),
                    "owner": LANGUAGES[language],
                }
                if component:
                    row["component"] = component
                if self.recovery.data["backend"] != "native":
                    row.update(
                        state="blocked",
                        reason="No qualified nixpkgs adapter for this native toolchain",
                    )
                elif path.is_file():
                    row["state"] = "present"
                elif language != "julia" and os.path.lexists(
                    path if component == "cabal" else path.parent.parent
                ):
                    row.update(
                        state="conflict",
                        reason="Existing incomplete runtime; manual inspection required",
                    )
                else:
                    try:
                        self.manager(language)
                        row["state"] = "missing"
                    except self.error as error:
                        row.update(state="blocked", reason=str(error))
                rows.append(row)
        return rows

    def invoke(self, language, *arguments, timeout=7200):
        manager = self.manager(language)
        args = [str(manager), *arguments]
        if language == "jvm":
            args = [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-c",
                SDK_SCRIPT,
                "dev-bootstrap-sdkman",
                str(manager),
                *arguments,
            ]
        environment = (
            self.recovery.data.get("setup", {}).get("buildEnvironment", {})
            | self.environment()
        )
        if language == "jvm" and Path("/.sdkmanrc").exists():
            raise self.error(
                "SDKMAN neutral working directory contains a project selection"
            )
        return self.run(
            args,
            env=environment,
            source_build=True,
            cwd="/" if language == "jvm" else str(self.recovery.state),
            timeout=timeout,
        )

    def acquire(self):
        """Only apply reaches the network; hash every bounded installer first."""
        for language in self.only:
            try:
                self.manager(language)
                continue
            except self.error:
                pass
            if language == "ruby":
                self.manager(language)
            install_root = self.roots[
                {"rust": "cargo", "julia": "juliaup"}.get(language, language)
            ]
            if install_root.exists() and any(install_root.iterdir()):
                raise self.error(
                    f"Inspect incomplete native manager root before acquisition: {install_root}"
                )
            if (
                language == "julia"
                and self.julia_config().get("Default") is not None
            ):
                raise self.error(
                    "Inspect existing Julia selection before reinstalling its manager"
                )
            recipe = self.recovery.data["setup"]["installers"][language]
            with urllib.request.urlopen(recipe["url"], timeout=60) as response:
                payload = response.read(1024 * 1024 + 1)
            if (
                len(payload) > 1024 * 1024
                or hashlib.sha256(payload).hexdigest() != recipe["sha256"]
            ):
                raise self.error(
                    f"Native {language} installer checksum/size mismatch; refresh its declaration"
                )
            with tempfile.TemporaryDirectory(
                prefix="native-manager-", dir=self.recovery.state
            ) as directory:
                script = Path(directory) / "installer"
                script.write_bytes(payload)
                environment = (
                    self.recovery.data["setup"].get("buildEnvironment", {})
                    | self.environment()
                )
                bindings = {
                    **self.environment(),
                    "version": self.specs[language]["version"],
                }
                environment.update(recipe.get("environment", {}))
                arguments = [
                    part.format_map(bindings) for part in recipe["arguments"]
                ]
                self.run(
                    [recipe["shell"], str(script), *arguments],
                    env=environment,
                    source_build=True,
                    cwd=directory,
                    timeout=1800,
                )
            self.manager(language)

    def readiness(self, language):
        if language == "jvm":
            if not (self.roots[language] / "src/sdkman-install.sh").is_file():
                raise self.error("Incomplete SDKMAN installation")
            if not re.search(
                r"[0-9]+\.[0-9]+", self.invoke(language, "version", timeout=30)
            ):
                raise self.error("Unrecognized SDKMAN version")
        else:
            output = self.invoke(language, "--version", timeout=30)
            if not re.search(r"[0-9]+\.[0-9]+", output):
                raise self.error(
                    f"Unrecognized native {language} manager: {output}"
                )

    def install(self, row):
        language, release = row["language"], row["version"]
        commands = {
            "rust": [
                "toolchain",
                "install",
                release,
                "--profile",
                "default",
                "--no-self-update",
            ],
            "haskell": [
                "install",
                row.get("component", "ghc"),
                release,
                "--no-set",
            ],
            "lean": ["toolchain", "install", "leanprover/lean4:v" + release],
            "ruby": ["install", "--skip-existing", release],
            "jvm": [
                "install",
                "java",
                self.specs[language].get("candidate", ""),
            ],
            "julia": ["add", release],
        }
        self.invoke(language, *commands[language])
        row["path"] = str(
            self.binary(language, component=row.get("component"))
        )

    def defaults(self):
        for language, selection in self.selections().items():
            if selection is not None:
                continue
            release = self.specs[language]["version"]
            commands = {
                "rust": ["default", release],
                "haskell": ["set", "ghc", release],
                "lean": ["default", "leanprover/lean4:v" + release],
                "ruby": ["global", release],
                "jvm": [
                    "default",
                    "java",
                    self.specs[language].get("candidate", ""),
                ],
                "julia": ["default", release],
            }
            if language == "ruby" and os.path.lexists(
                self.roots[language] / "version"
            ):
                raise self.error("Inspect the existing Ruby global selection")
            self.invoke(language, *commands[language])
        if "haskell" in self.only and not os.path.lexists(
            self.roots["haskell"] / "bin/cabal"
        ):
            self.invoke(
                "haskell", "set", "cabal", self.specs["haskell"]["cabal"]
            )
        if (
            "ruby" in self.only
            and not (self.roots["ruby"] / "shims/ruby").is_file()
        ):
            self.invoke("ruby", "rehash")

    def health(self):
        rows = []
        for language, selection in self.selections().items():
            row = {
                "language": language,
                "version": self.specs[language]["version"],
                "path": "",
            }
            try:
                self.manager(language)
                if not selection:
                    raise self.error(f"No global {language} selection")
                if language == "ruby" and selection == SYSTEM_SELECTION:
                    rows.append(
                        external_selection(
                            row | {"owner": LANGUAGES[language]}
                        )
                    )
                    continue
                if language in ("haskell", "jvm"):
                    path = (
                        Path(selection) / "bin/java"
                        if language == "jvm"
                        else Path(selection)
                    )
                elif language == "julia":
                    path = self.julia_binary(channel=selection)
                else:
                    path = self.binary(language, selection)
                self.check_binary(language, path)
                row.update(
                    state="present", path=str(path), owner=LANGUAGES[language]
                )
            except self.error as error:
                row.update(state="blocked", reason=str(error))
            rows.append(row)
        if "haskell" in self.only:
            path = self.roots["haskell"] / "bin/cabal"
            row = {
                "language": "haskell",
                "component": "cabal",
                "version": self.specs["haskell"]["cabal"],
                "path": str(path),
                "owner": "ghcup",
            }
            try:
                self.check_binary("haskell", path)
                row["state"] = "present"
            except self.error as error:
                row.update(state="blocked", reason=str(error))
            rows.append(row)
        return rows

    def check_binary(self, language, path):
        if (
            not path.is_file()
            or not os.access(path, os.X_OK)
            or not path.resolve().is_relative_to(self.roots[language])
        ):
            raise self.error(
                f"Native runtime is unavailable or escapes its root: {path}"
            )
        if path.resolve() == self.manager(language).resolve():
            raise self.error(
                f"Runtime resolves to a download-capable manager: {path}"
            )

    def verify(self, row, exact=True):
        language, path = row["language"], Path(row["path"])
        self.check_binary(language, path)
        flags = (
            ["--numeric-version"] if language == "haskell" else ["--version"]
        )
        if language == "julia":
            flags = [
                "--startup-file=no",
                "--history-file=no",
                "-e",
                "print(VERSION)",
            ]
        output = self.run(
            [str(path), *flags],
            env=self.environment(),
            source_build=True,
            cwd="/",
        )
        match = re.search(r"[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?", output)
        if not match:
            raise self.error(
                f"Unrecognized {language} runtime identity: {output}"
            )
        actual = match.group()
        # Health accepts any selected release, older ones included; only exact
        # baseline verification compares identities.
        if exact and actual != row["version"]:
            raise self.error(
                f"{language} identity mismatch: expected {row['version']}, got {actual}"
            )
        if row.get("component") != "cabal":
            self.canary(language, path)
        return actual

    def canary(self, language, executable):
        """Small local compiler/interpreter probes, with no package resolution."""
        environment = (
            self.recovery.data.get("setup", {}).get("buildEnvironment", {})
            | self.environment()
        )
        with tempfile.TemporaryDirectory(prefix="native-canary-") as directory:
            work = Path(directory)

            def call(args):
                return self.run(
                    [str(arg) for arg in args],
                    env=environment,
                    source_build=True,
                    cwd=directory,
                    timeout=120,
                )

            if language == "rust":
                source = work / "main.rs"
                source.write_text('fn main() { println!("bootstrap-ok"); }\n')
                call([executable, source, "-o", work / "canary"])
                output = call([work / "canary"])
            elif language == "haskell":
                output = call(
                    [
                        executable,
                        "-ignore-dot-ghci",
                        "-e",
                        'putStrLn "bootstrap-ok"',
                    ]
                )
            elif language == "lean":
                source = work / "Main.lean"
                source.write_text(
                    'def main : IO Unit := IO.println "bootstrap-ok"\n'
                )
                output = call([executable, "--run", source])
            elif language == "ruby":
                output = call(
                    [
                        executable,
                        "--disable-gems",
                        "-e",
                        'require "openssl"; require "zlib"; abort unless 1+1==2; puts "bootstrap-ok"',
                    ]
                )
            elif language == "jvm":
                compiler = executable.parent / "javac"
                self.check_binary(language, compiler)
                source = work / "Main.java"
                source.write_text(
                    'class Main { public static void main(String[] args) { System.out.println("bootstrap-ok"); } }\n'
                )
                call([compiler, "-d", work, source])
                output = call([executable, "-cp", work, "Main"])
            else:
                output = call(
                    [
                        executable,
                        "--startup-file=no",
                        "--history-file=no",
                        "-e",
                        '@assert 1+1==2; print("bootstrap-ok")',
                    ]
                )
            if output != "bootstrap-ok":
                raise self.error(f"{language} runtime canary failed: {output}")
