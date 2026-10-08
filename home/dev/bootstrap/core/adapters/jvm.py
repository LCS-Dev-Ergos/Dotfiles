"""Java through SDKMAN; the JDK the SDKMAN build tools run on."""

import re

from ..errors import BootstrapError
from .sdkman import SdkmanAdapter
from .toolchain import IDENTITY


class JvmAdapter(SdkmanAdapter):
    language = "jvm"
    candidate = "java"
    selection_executable = "bin/java"
    # JDK patch identities may carry a fourth component (21.0.12.1).
    release_pattern = IDENTITY

    @classmethod
    def validate_declaration(cls, spec):
        super().validate_declaration(spec)
        if not re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9.]+)?-tem", spec["candidate"]
        ):
            raise BootstrapError("Invalid SDKMAN Java candidate")

    def identifier(self):
        return self.spec["candidate"]

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
