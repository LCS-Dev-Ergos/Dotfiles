"""The Android SDK through sdkmanager, from Google's command-line tools.

The SDK root holds one directory per package, each with a source.properties
naming what it is: platform-tools (adb), build-tools/<release> and
platforms/android-<API level>. sdkmanager installs build tools by exact
release, but only the newest platform-tools and a platform's newest
revision, so the platform-tools declaration is a floor.

Every package needs the Android SDK License. An apply names it with
`--accept android-sdk-license`, and the adapter records that acceptance under
licenses/ itself, as the hash of the reviewed text the declaration pins
(native-managers.nix). sdkmanager then asks nothing for these packages, and
every question it still asks is declined: a package that needs other terms
is not installed, and the row fails.

From command-line tools 23.0 on, sdkmanager only hands its arguments to the
`android` CLI, which downloads itself unpinned, records the terms without
asking and collects usage data unless told not to. The bootstrap therefore
keeps its own sdkmanager, the declared release from before that change, in
cmdline-tools/<release>; cmdline-tools/latest, the one on PATH, stays the
account's or Android Studio's.
"""

import os
import re
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from .sdkman import JdkTool
from .toolchain import RELEASE, ToolchainAdapter

LICENSE = "android-sdk-license"
# The package path sdkmanager installs for each component.
PACKAGES = {
    "platform-tools": "platform-tools",
    "build-tools": "build-tools;{}",
    "platform": "platforms;android-{}",
}
# The declaration's key for each component.
KEYS = {
    "platform-tools": "version",
    "build-tools": "buildTools",
    "platform": "platform",
}
# Every license sdkmanager still shows is declined: the one the apply
# accepted is already on file, so a question means other terms.
DECLINE = b"n\n" * 8
PLATFORM = re.compile(r"[1-9][0-9]*(?:\.[0-9]+)?")
RESOURCES = (
    '<resources><string name="canary">bootstrap-ok</string></resources>\n'
)
MANIFEST = (
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android"'
    ' package="dev.bootstrap.canary" />\n'
)


def properties(directory):
    """A package's source.properties as a mapping, or nothing."""
    path = directory / "source.properties"
    if not path.is_file():
        return {}
    fields = {}
    for line in path.read_text(errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            fields[key.strip()] = value.strip()
    return fields


def release(text):
    return tuple(int(part) for part in re.findall(r"[0-9]+", text))


class AndroidAdapter(JdkTool, ToolchainAdapter):
    language = "android"
    title = "Android SDK"
    component_titles = {
        "platform-tools": "Platform-Tools",
        "build-tools": "Build-Tools",
        "platform": "Platform",
    }
    primary_component = "platform-tools"
    cost = "medium"
    manager_name = "sdkmanager"
    # Projects name their build tools and platform; adb is the one on PATH.
    global_selection = False
    # The license makes it opt-in: a run without --only never asks for it.
    default_selected = False
    consents = (LICENSE,)

    @classmethod
    def validate_declaration(cls, spec):
        super().validate_declaration(spec)
        if not re.fullmatch(RELEASE, spec["buildTools"]):
            raise BootstrapError("Invalid Android build tools release")
        if not PLATFORM.fullmatch(spec["platform"]):
            raise BootstrapError("Invalid Android platform level")
        if not re.fullmatch(r"[0-9]+\.[0-9]+", spec["tools"]):
            raise BootstrapError("Invalid Android command-line tools release")

    def resolve_roots(self):
        if self.context.data["platform"] == "aarch64-darwin":
            default = Path.home() / "Library/Android/sdk"
        else:
            default = Path.home() / "Android/Sdk"
        return {"ANDROID_HOME": self.locate("ANDROID_HOME", default)}

    @property
    def tools(self):
        """The command-line tools release the bootstrap's sdkmanager is."""
        return self.root / "cmdline-tools" / self.spec["tools"]

    def manager_candidates(self):
        return [self.tools / "bin/sdkmanager"]

    def occupied(self):
        return os.path.lexists(self.tools)

    @property
    def user_home(self):
        """Where sdkmanager keeps its preferences and repository cache.

        The JVM takes user.home from the account database, not HOME, so
        without this sdkmanager writes the account's ~/.android even when
        HOME points elsewhere. Pinning it to HOME's .android, or to an
        ANDROID_USER_HOME already set, makes a redirected HOME hold it too.
        """
        return self.locate("ANDROID_USER_HOME", Path.home() / ".android")

    def invoke(self, *arguments, timeout=3600, answers=None):
        return process.run(
            [str(self.manager()), f"--sdk_root={self.root}", *arguments],
            env=self.recipe.get("buildEnvironment", {})
            | self.environment()
            | {
                "JAVA_HOME": str(self.java_home()),
                "ANDROID_USER_HOME": str(self.user_home),
            },
            source_build=True,
            cwd=str(self.context.state),
            timeout=timeout,
            answers=answers,
        )

    def install_manager(self, recipe, payload, directory):
        """Unpack the verified archive's cmdline-tools as cmdline-tools/<release>.

        That is where sdkmanager itself puts a versioned cmdline-tools
        package, so it recognizes the copy as installed.
        """
        staging = Path(directory) / "unpacked"
        try:
            with zipfile.ZipFile(payload) as archive:
                for member in archive.infolist():
                    parts = Path(member.filename).parts
                    mode = member.external_attr >> 16
                    if (
                        member.filename.startswith("/")
                        or ".." in parts
                        or not parts
                        or parts[0] != "cmdline-tools"
                        or stat.S_ISLNK(mode)
                    ):
                        raise BootstrapError(
                            f"Unexpected entry in the Android archive: "
                            f"{member.filename}"
                        )
                    target = staging.joinpath(*parts)
                    if member.is_dir():
                        target.mkdir(parents=True, exist_ok=True)
                        continue
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with (
                        archive.open(member) as source,
                        target.open("wb") as file,
                    ):
                        shutil.copyfileobj(source, file)
                    target.chmod(0o755 if mode & 0o111 else 0o644)
        except zipfile.BadZipFile as error:
            raise BootstrapError("The Android archive is not a zip") from error
        tools = staging / "cmdline-tools"
        if not (tools / "bin/sdkmanager").is_file():
            raise BootstrapError("The Android archive has no bin/sdkmanager")
        destination = self.tools
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(tools, destination)

    def readiness(self):
        """The command-line tools are complete; sdkmanager is not run.

        It needs the JDK, which the runtimes stage installs after readiness.
        """
        self.manager()
        revision = properties(self.tools).get("Pkg.Revision", "")
        if revision != self.spec["tools"]:
            raise BootstrapError(
                "Incomplete Android command-line tools: "
                f"{self.tools} reports {revision or 'no release'}"
            )

    # Declared baseline -------------------------------------------------------

    def declared_release(self, component):
        return self.spec[KEYS[component]]

    def package_directory(self, component, version):
        if component == "platform-tools":
            return self.root / "platform-tools"
        if component == "build-tools":
            return self.root / "build-tools" / version
        return self.root / "platforms" / f"android-{version}"

    def package_binary(self, component, version):
        name = {
            "platform-tools": "adb",
            "build-tools": "aapt2",
            "platform": "android.jar",
        }[component]
        return self.package_directory(component, version) / name

    def binary(self, selection=None):
        return self.package_binary("platform-tools", self.spec["version"])

    def baseline(self):
        return [
            self.row(
                self.declared_release(component),
                self.package_binary(
                    component, self.declared_release(component)
                ),
                component=component,
            )
            for component in PACKAGES
        ]

    def prefix(self, row):
        return Path(row["path"]).parent

    def licenses(self):
        directory = self.root / "licenses"
        if not directory.is_dir():
            return {}
        return {
            path.name: path.read_bytes()
            for path in directory.iterdir()
            if path.is_file()
        }

    def accept_license(self):
        """Record the accepted license as sdkmanager does, if not on file.

        sdkmanager keeps one hash per line, the first line empty; it treats
        the license as accepted when any line holds the current text's hash.
        """
        digest = self.recipe.get("licenses", {}).get(LICENSE)
        if not digest:
            raise BootstrapError(
                f"The baseline records no reviewed {LICENSE} to accept"
            )
        path = self.root / "licenses" / LICENSE
        if os.path.lexists(path) and not path.is_file():
            raise BootstrapError(f"Inspect the existing license record {path}")
        recorded = path.read_text() if path.is_file() else ""
        if digest in recorded.split():
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{LICENSE}.dev-bootstrap")
        temporary.write_text(f"{recorded.rstrip()}\n{digest}")
        os.replace(temporary, path)

    def install(self, row):
        component = row["component"]
        package = PACKAGES[component].format(row["version"])
        self.accept_license()
        before = self.licenses()
        try:
            self.invoke("--install", package, answers=DECLINE)
        finally:
            self.keep_licenses(before, package)
        path = self.package_binary(component, row["version"])
        if not path.is_file():
            raise BootstrapError(
                f"sdkmanager did not install {package}: it asked for terms "
                f"other than {LICENSE}, which were declined; see the log"
            )
        row["path"] = str(path)

    def keep_licenses(self, before, package):
        """Revert every license record but the accepted one, then fail.

        Nothing records another license while every question is declined;
        a change here means sdkmanager accepted terms on its own.
        """
        changed = []
        for name, content in self.licenses().items():
            if name != LICENSE and before.get(name) != content:
                path = self.root / "licenses" / name
                if name in before:
                    path.write_bytes(before[name])
                else:
                    path.unlink()
                changed.append(name)
        if changed:
            raise BootstrapError(
                f"Installing {package} recorded {', '.join(sorted(changed))}, "
                "which this apply did not accept; reverted"
            )

    def installed(self):
        found = []
        tools = self.root / "platform-tools"
        if revision := properties(tools).get("Pkg.Revision"):
            found.append(f"platform-tools={revision}")
        for name, directory in (
            ("build-tools", "build-tools"),
            ("platform", "platforms"),
        ):
            container = self.root / directory
            if container.is_dir():
                found += sorted(
                    f"{name}={path.name.removeprefix('android-')}"
                    for path in container.iterdir()
                    if (path / "source.properties").is_file()
                )
        return found

    # Verification ------------------------------------------------------------

    def check_runtime(self, path):
        if not path.is_file() or not path.resolve().is_relative_to(
            self.root.resolve()
        ):
            raise BootstrapError(
                f"Android package is unavailable or escapes its root: {path}"
            )
        if path.suffix != ".jar" and not os.access(path, os.X_OK):
            raise BootstrapError(f"Android tool is not executable: {path}")

    check_selected = check_runtime

    def identity(self, row, path):
        fields = properties(path.parent)
        key = (
            "AndroidVersion.ApiLevel"
            if row.get("component") == "platform"
            else "Pkg.Revision"
        )
        identity = fields.get(key)
        if not identity:
            raise BootstrapError(
                f"Android package records no {key}: {path.parent}"
            )
        return identity

    def verify(self, row, *, exact=True):
        """The declared package; platform-tools at least the declared one."""
        path = Path(row["path"])
        self.check_runtime(path)
        identity = self.identity(row, path)
        component = row.get("component", "platform-tools")
        if exact:
            if component == "platform-tools":
                matches = release(identity) >= release(row["version"])
            else:
                matches = identity == row["version"]
            if not matches:
                raise BootstrapError(
                    f"{self.language} identity mismatch: "
                    f"expected {row['version']}, got {identity}"
                )
        self.canary(row, path, complete=exact)
        return identity

    def newest(self, component):
        """The declared package when present, else the newest installed one."""
        declared = self.package_binary(
            component, self.declared_release(component)
        )
        if declared.is_file():
            return declared
        container = self.package_directory(component, "0").parent
        versions = (
            sorted(
                (
                    path.name.removeprefix("android-")
                    for path in container.iterdir()
                ),
                key=release,
            )
            if container.is_dir()
            else []
        )
        for version in reversed(versions):
            candidate = self.package_binary(component, version)
            if candidate.is_file():
                return candidate
        raise BootstrapError(
            f"The Android canary needs an installed {component} package"
        )

    def has(self, component):
        try:
            self.newest(component)
        except BootstrapError:
            return False
        return True

    def canary(self, row, path, *, complete):
        """adb reports itself; aapt2 links an empty app against the platform."""
        component = row.get("component", "platform-tools")
        with tempfile.TemporaryDirectory(prefix="native-canary-") as directory:
            work = Path(directory)
            # Scratch home: adb creates ~/.android even for `version`.
            environment = self.recipe.get("buildEnvironment", {}) | {
                "HOME": directory,
                "ANDROID_USER_HOME": str(work / ".android"),
            }

            def call(args):
                return process.run(
                    [str(arg) for arg in args],
                    env=environment,
                    source_build=True,
                    cwd=directory,
                    timeout=120,
                )

            if component == "platform-tools":
                output = call([path, "version"])
                ok = "Android Debug Bridge" in output
            elif component == "build-tools" and not self.has("platform"):
                # The first apply installs the build tools before any
                # platform; the platform's canary then links with them.
                # Until then aapt2 compiles a resource, which needs none.
                values = work / "res/values"
                values.mkdir(parents=True)
                (values / "strings.xml").write_text(RESOURCES)
                output = call(
                    [path, "compile", "-o", work, values / "strings.xml"]
                )
                ok = (work / "values_strings.arsc.flat").is_file()
            elif component == "platform" and not self.has("build-tools"):
                with zipfile.ZipFile(path) as archive:
                    output = "android/app/Activity.class"
                    ok = output in archive.namelist()
            else:
                aapt2 = (
                    path
                    if component == "build-tools"
                    else self.newest("build-tools")
                )
                platform = (
                    path
                    if component == "platform"
                    else self.newest("platform")
                )
                self.check_runtime(aapt2)
                self.check_runtime(platform)
                (work / "AndroidManifest.xml").write_text(MANIFEST)
                call(
                    [
                        aapt2,
                        "link",
                        "-o",
                        work / "canary.apk",
                        "-I",
                        platform,
                        "--manifest",
                        work / "AndroidManifest.xml",
                    ]
                )
                output = call([aapt2, "dump", "badging", work / "canary.apk"])
                level = (
                    properties(platform.parent)
                    .get("AndroidVersion.ApiLevel", "")
                    .split(".")[0]
                )
                ok = bool(level) and f"compileSdkVersion='{level}'" in output
        if not ok:
            raise BootstrapError(f"android canary failed: {output}")

    # Global selection --------------------------------------------------------

    def read_selection(self):
        """Projects choose build tools and platforms; nothing is global."""
        return None

    def selected_runtime(self):
        return self.root / "platform-tools/adb"

    def initialize_default(self):
        """There is no global selection to initialize."""
