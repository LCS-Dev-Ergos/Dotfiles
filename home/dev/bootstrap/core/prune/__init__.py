"""`prune`: remove the installed releases the baseline retired.

Without --yes, prune only plans. With it, each release is handled on its
own under the apply lock: its steps run in order and the release is removed
last, so a failure keeps that release installed and the others proceed.
"""

from ..errors import BootstrapError
from .runtimes import NodeRetirer, OcamlRetirer, PythonRetirer
from .toolchains import (
    DotnetRetirer,
    HaskellRetirer,
    JuliaRetirer,
    LeanRetirer,
    RubyRetirer,
    RustRetirer,
    ScalaRetirer,
    SdkmanRetirer,
)

# Conda has a single base environment and nothing to retire.
RETIRERS = {
    "node": NodeRetirer,
    "python": PythonRetirer,
    "ocaml": OcamlRetirer,
    "rust": RustRetirer,
    "haskell": HaskellRetirer,
    "lean": LeanRetirer,
    "ruby": RubyRetirer,
    "jvm": SdkmanRetirer,
    "kotlin": SdkmanRetirer,
    "maven": SdkmanRetirer,
    "gradle": SdkmanRetirer,
    "scala": ScalaRetirer,
    "julia": JuliaRetirer,
    "dotnet": DotnetRetirer,
}


class Prune:
    def __init__(self, context):
        self.context = context

    def retirers(self):
        return [
            RETIRERS[language](adapter)
            for language, adapter in self.context.adapters.items()
            if language in RETIRERS
        ]

    def plan(self):
        return [
            retirement
            for retirer in self.retirers()
            for retirement in retirer.plan()
        ]

    def apply(self):
        """Plan again under the lock, then remove every unblocked release."""
        with self.context.locked():
            retirements = self.plan()
            for retirement in retirements:
                if retirement.state != "retire":
                    continue
                try:
                    retirement.retirer.execute(retirement)
                except (BootstrapError, OSError) as error:
                    retirement.state = "failed"
                    retirement.reason = str(error)
                else:
                    retirement.state = "removed"
        return retirements
