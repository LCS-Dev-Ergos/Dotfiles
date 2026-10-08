"""SDKMAN candidates, driven by a fixed Bash program with literal arguments.

One SDKMAN root serves several adapters: Java, then the build tools that run
on it. Each candidate installs, selects and verifies on its own, so `--only`
and a frontend can choose tools individually; the tools require `jvm`, whose
adapter acquires SDKMAN itself.
"""

import re
import tempfile
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from .toolchain import LinkedToolchain

# Fixed program and positional arguments; never interpolate shell source.
# It runs under the package's Bash (sdkmanShell): SDKMAN needs Bash 4, and
# macOS ships 3.2.
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


class SdkmanAdapter(LinkedToolchain):
    manager_name = "sdkman"
    sourced_manager = True
    # The SDKMAN candidate name, as in `sdk install <candidate>`.
    candidate = ""

    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        if cls.candidate:
            cls.runtime_directory = f"candidates/{cls.candidate}"
            cls.selection_link = f"candidates/{cls.candidate}/current"

    def resolve_roots(self):
        return {
            "SDKMAN_DIR": self.locate("SDKMAN_DIR", Path.home() / ".sdkman")
        }

    def manager_candidates(self):
        return [self.root / "bin/sdkman-init.sh"]

    def invoke(self, *arguments, timeout=7200):
        # A project selection in the working directory would redirect sdk.
        if Path("/.sdkmanrc").exists():
            raise BootstrapError(
                "SDKMAN neutral working directory contains a project selection"
            )
        return process.run(
            [
                self.recipe["sdkmanShell"],
                "--noprofile",
                "--norc",
                "-c",
                SDK_SCRIPT,
                "dev-bootstrap-sdkman",
                str(self.manager()),
                *arguments,
            ],
            env=self.recipe.get("buildEnvironment", {}) | self.environment(),
            source_build=True,
            cwd="/",
            timeout=timeout,
        )

    def readiness(self):
        if not (self.root / "src/sdkman-install.sh").is_file():
            raise BootstrapError("Incomplete SDKMAN installation")
        if not re.search(
            r"[0-9]+\.[0-9]+", self.invoke("version", timeout=30)
        ):
            raise BootstrapError("Unrecognized SDKMAN version")

    def installed(self):
        return [name for name in super().installed() if name != "current"]

    def identifier(self):
        """The candidate version SDKMAN names, which may differ from identity."""
        return self.spec["version"]

    def binary(self, selection=None):
        return (
            self.root
            / self.runtime_directory
            / (selection or self.identifier())
            / self.selection_executable
        )

    def install_arguments(self, row):
        return ["install", self.candidate, self.identifier()]

    def default_arguments(self):
        return ["default", self.candidate, self.identifier()]


class SdkmanTool(SdkmanAdapter):
    """A JVM build tool: it runs on the JDK that the `jvm` adapter installs."""

    requires = ("jvm",)

    def java_home(self):
        """The declared JDK when present, otherwise the selected one."""
        jvm = self.context.adapter("jvm")
        for prefix in (
            jvm.binary().parent.parent,
            jvm.root / jvm.selection_link,
        ):
            if (prefix / "bin/java").is_file():
                home = prefix.resolve()
                if home.is_relative_to(jvm.root.resolve()):
                    return home
        raise BootstrapError(
            f"{self.language} needs an SDKMAN JDK; apply jvm first"
        )

    def runtime_environment(self):
        # Launchers prefer JAVA_HOME; on macOS /usr/bin/java is only a stub.
        return super().runtime_environment() | {
            "JAVA_HOME": str(self.java_home())
        }


class KotlinAdapter(SdkmanTool):
    language = "kotlin"
    candidate = "kotlin"
    selection_executable = "bin/kotlin"
    identity_arguments = ("-version",)

    def exercise(self, executable, work, call):
        compiler = executable.parent / "kotlinc"
        self.check_runtime(compiler)
        source = work / "Main.kt"
        source.write_text('fun main() {\n    println("bootstrap-ok")\n}\n')
        call([compiler, source, "-d", work / "classes"])
        return call([executable, "-cp", work / "classes", "MainKt"])


class MavenAdapter(SdkmanTool):
    language = "maven"
    candidate = "maven"
    selection_executable = "bin/mvn"

    def runtime_environment(self):
        # ~/.mavenrc and /etc/mavenrc may redirect JAVA_HOME or options.
        return super().runtime_environment() | {"MAVEN_SKIP_RC": "1"}

    def exercise(self, executable, work, call):
        # Without network or plugins, Maven's core must start on the JDK
        # it was given.
        output = call([executable, "--batch-mode", "--version"])
        expected = f"runtime: {self.java_home()}"
        return "bootstrap-ok" if expected in output else output


class GradleAdapter(SdkmanTool):
    language = "gradle"
    candidate = "gradle"
    selection_executable = "bin/gradle"

    def identity(self, row, path):
        # Gradle initializes its user home even for --version. A scratch one
        # keeps verification from writing into the real ~/.gradle.
        with tempfile.TemporaryDirectory(prefix="native-gradle-") as scratch:
            return self.parse_identity(
                process.run(
                    [str(path), "--version", "--no-daemon"],
                    env=self.runtime_environment()
                    | {"GRADLE_USER_HOME": scratch},
                    source_build=True,
                    cwd=scratch,
                    timeout=120,
                )
            )

    def exercise(self, executable, work, call):
        (work / "settings.gradle").write_text("rootProject.name = 'canary'\n")
        (work / "build.gradle").write_text(
            "tasks.register('canary') {\n    doLast { println 'bootstrap-ok' }\n}\n"
        )
        return call(
            [
                executable,
                "--no-daemon",
                "--offline",
                "--quiet",
                "--gradle-user-home",
                work / "gradle-home",
                "canary",
            ]
        )
