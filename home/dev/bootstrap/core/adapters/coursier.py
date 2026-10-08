"""Scala through Coursier, whose official `cs` launcher installs releases.

Coursier keeps one launcher per application in its bin directory, and that
launcher is the global selection: `cs install scala:<version>` there replaces
it. The seed therefore lives in the archive cache, where Coursier extracts the
prebuilt Scala distribution that the `scala` launcher runs. Installing into a
discarded staging directory fills that cache without touching any launcher;
the `scala` and `scalac` launchers are created only when absent.
"""

import os
import re
import shutil
import tempfile
from pathlib import Path

from ..errors import BootstrapError
from ..paths import root_path
from .sdkman import JdkTool
from .toolchain import ToolchainAdapter

TRIPLES = {
    "aarch64-darwin": "aarch64-apple-darwin",
    "x86_64-linux": "x86_64-pc-linux",
}
# The `scala` app's prebuilt archive as Coursier lays it out in the archive
# cache: the URL's scheme, host and path, then the archive's top directory.
RELEASES = "https/github.com/scala/scala3/releases/download"
DISTRIBUTION = (
    "{version}/scala3-{version}-{triple}.tar.gz/scala3-{version}-{triple}"
)
LAUNCHERS = ("scala", "scalac")
# A prebuilt launcher is a shell preamble that runs the extracted
# distribution, followed by the app descriptor Coursier appends as a zip.
EXEC = re.compile(rb'^exec "(/[^"\n]+)" "\$@"$', re.MULTILINE)


class ScalaAdapter(JdkTool, ToolchainAdapter):
    language = "scala"
    manager_name = "coursier"
    identity_arguments = ("-version",)

    def resolve_roots(self):
        home = Path.home()
        data = root_path("XDG_DATA_HOME", home / ".local/share")
        if self.context.data["platform"] == "aarch64-darwin":
            binaries = home / "Library/Application Support/Coursier/bin"
            cache = home / "Library/Caches/Coursier/v1"
        else:
            binaries = data / "coursier/bin"
            cache = root_path("XDG_CACHE_HOME", home / ".cache")
            cache = cache / "coursier/v1"
        # The archive cache follows the shell's choice (75-variables.zsh):
        # launchers run from it, so it stays with application data.
        return {
            "COURSIER_ARCHIVE_CACHE": self.locate(
                "COURSIER_ARCHIVE_CACHE", data / "coursier/arc"
            ),
            "COURSIER_BIN_DIR": self.locate("COURSIER_BIN_DIR", binaries),
            "COURSIER_CACHE": self.locate("COURSIER_CACHE", cache),
        }

    @property
    def home(self):
        return self.roots["COURSIER_BIN_DIR"]

    def manager_candidates(self):
        return [self.home / "cs"]

    def occupied(self):
        # The bin directory also holds other applications' launchers; only
        # an unusable `cs` there needs inspection.
        return os.path.lexists(self.manager_candidates()[0])

    def install_manager(self, recipe, payload, directory):
        """Place the verified native launcher, which runs without setup."""
        payload.chmod(0o755)
        self.home.mkdir(parents=True, exist_ok=True)
        shutil.move(payload, self.manager_candidates()[0])

    def readiness(self):
        output = self.invoke("version", timeout=60)
        if not re.search(r"[0-9]+\.[0-9]+", output):
            raise BootstrapError(f"Unrecognized Coursier launcher: {output}")

    # Declared baseline -------------------------------------------------------

    def distributions(self):
        return self.root / RELEASES

    def binary(self, selection=None):
        version = selection or self.spec["version"]
        triple = TRIPLES[self.context.data["platform"]]
        return (
            self.distributions()
            / DISTRIBUTION.format(version=version, triple=triple)
            / "bin/scalac"
        )

    def install(self, row):
        with tempfile.TemporaryDirectory(
            prefix="native-coursier-", dir=self.context.state
        ) as staging:
            self.invoke(
                "install", "--install-dir", staging, f"scala:{row['version']}"
            )
        row["path"] = str(self.binary(row["version"]))

    def installed(self):
        releases = self.distributions()
        if not releases.is_dir():
            return []
        return sorted(path.name for path in releases.iterdir())

    # Verification ------------------------------------------------------------

    def exercise(self, executable, work, call):
        classes = work / "classes"
        classes.mkdir()
        source = work / "Main.scala"
        source.write_text(
            '@main def canary(): Unit = println("bootstrap-ok")\n'
        )
        call([executable, "-d", classes, source])
        # The distribution's manifest-only jar lists its library on its
        # class path; the seed's layout is known, an evolved one may differ.
        library = executable.parent.parent / "lib/scala.jar"
        if not library.is_file():
            return (
                "bootstrap-ok" if (classes / "canary.class").is_file() else ""
            )
        java = self.java_home() / "bin/java"
        return call([java, "-cp", f"{classes}{os.pathsep}{library}", "canary"])

    # Global selection --------------------------------------------------------

    def read_selection(self):
        """The distribution the `scala` launcher runs, or the launcher itself."""
        launcher = self.home / "scala"
        if not os.path.lexists(launcher):
            return None
        if not launcher.is_file():
            raise BootstrapError("Inspect the existing Scala launcher")
        with launcher.open("rb") as file:
            match = EXEC.search(file.read(4096))
        return match.group(1).decode() if match else str(launcher)

    def runtime_for(self, selection):
        target = Path(selection)
        if target == self.home / "scala" or target.name != "scala":
            raise BootstrapError(
                "The scala launcher does not run a prebuilt Scala "
                "distribution; health checks only distributions"
            )
        return target.parent / "scalac"

    def initialize_default(self):
        for name in LAUNCHERS:
            if not os.path.lexists(self.home / name):
                self.invoke(
                    "install",
                    "--install-dir",
                    str(self.home),
                    f"{name}:{self.spec['version']}",
                )
