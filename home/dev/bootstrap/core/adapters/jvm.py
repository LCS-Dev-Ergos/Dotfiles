"""Java through SDKMAN, driven by a fixed Bash program with literal arguments."""

import re
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from .toolchain import IDENTITY, LinkedToolchain

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


class JvmAdapter(LinkedToolchain):
    language = "jvm"
    manager_name = "sdkman"
    runtime_directory = "candidates/java"
    selection_link = "candidates/java/current"
    selection_executable = "bin/java"
    sourced_manager = True
    # JDK patch identities may carry a fourth component (21.0.12.1).
    release_pattern = IDENTITY

    @classmethod
    def validate_declaration(cls, spec):
        super().validate_declaration(spec)
        if not re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9.]+)?-tem", spec["candidate"]
        ):
            raise BootstrapError("Invalid SDKMAN Java candidate")

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
                "/bin/bash",
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

    def binary(self, selection=None):
        return (
            self.root
            / "candidates/java"
            / (selection or self.spec["candidate"])
            / "bin/java"
        )

    def install_arguments(self, row):
        return ["install", "java", self.spec["candidate"]]

    def default_arguments(self):
        return ["default", "java", self.spec["candidate"]]

    def exercise(self, executable, work, call):
        compiler = executable.parent / "javac"
        self.check_runtime(compiler)
        source = work / "Main.java"
        source.write_text(
            "class Main { public static void main(String[] args) "
            '{ System.out.println("bootstrap-ok"); } }\n'
        )
        call([compiler, "-d", work, source])
        return call([executable, "-cp", work, "Main"])
