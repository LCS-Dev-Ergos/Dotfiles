"""The .NET SDK through Microsoft's dotnet-install script.

.NET has no version manager: dotnet-install puts each SDK side by side in
DOTNET_ROOT, and the `dotnet` muxer there runs the newest one unless a
project's global.json pins another. The bootstrap installs the declared SDK
and writes a global.json only into its own scratch directories, so projects
keep precedence and there is no global selection to initialize.
"""

import json
import os
import tempfile
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from .toolchain import ToolchainAdapter

# Every CLI call: no telemetry, banners, first-run certificate or workload
# notices, and no MSBuild or compiler server outliving the call.
CLI_ENVIRONMENT = {
    "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
    "DOTNET_NOLOGO": "1",
    "DOTNET_GENERATE_ASPNET_CERTIFICATE": "false",
    "DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE": "1",
    "DOTNET_ADD_GLOBAL_TOOLS_TO_PATH": "false",
    "MSBUILDDISABLENODEREUSE": "1",
}
# Directories that only an installation creates; the CLI's own user state
# (global tools, first-use sentinels) shares the default root with them.
LAYOUT = ("host", "packs", "sdk", "shared")
PROJECT = """<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net{major}.0</TargetFramework>
  </PropertyGroup>
</Project>
"""
# No package source: a restore that needs a download fails instead.
OFFLINE = "<configuration><packageSources><clear /></packageSources></configuration>\n"


class DotnetAdapter(ToolchainAdapter):
    language = "dotnet"
    manager_name = "dotnet"
    runtime_directory = "sdk"

    def resolve_roots(self):
        return {
            "DOTNET_ROOT": self.locate("DOTNET_ROOT", Path.home() / ".dotnet")
        }

    def manager_candidates(self):
        return [self.root / "dotnet"]

    def occupied(self):
        return any(os.path.lexists(self.root / name) for name in LAYOUT)

    def cli(self, *arguments, work):
        """Run the muxer with a scratch home, never the real ~/.dotnet state."""
        return process.run(
            [str(self.manager()), *map(str, arguments)],
            env=self.recipe.get("buildEnvironment", {})
            | self.environment()
            | CLI_ENVIRONMENT
            | {
                "HOME": str(work),
                "DOTNET_CLI_HOME": str(work),
                "NUGET_PACKAGES": str(work / "packages"),
            },
            source_build=True,
            cwd=str(work),
            timeout=600,
        )

    def readiness(self):
        # Unlike --version, listing needs no SDK, so a runtime-only root
        # passes and gets the declared SDK installed beside it.
        with tempfile.TemporaryDirectory(prefix="native-dotnet-") as work:
            self.cli("--list-sdks", work=Path(work))

    # Declared baseline -------------------------------------------------------

    def binary(self, selection=None):
        return (
            self.root
            / "sdk"
            / (selection or self.spec["version"])
            / "dotnet.dll"
        )

    def prefix(self, row):
        return Path(row["path"]).parent

    def install(self, row):
        # The script installs one exact SDK per run; it skips the muxer and
        # other unversioned files when they exist, as a newer SDK's may.
        self.run_installer()
        row["path"] = str(self.binary(row["version"]))

    # Verification ------------------------------------------------------------

    def check_runtime(self, path):
        muxer = self.manager_candidates()[0]
        for candidate in (path, muxer):
            if (
                not candidate.is_file()
                or not candidate.resolve().is_relative_to(self.root)
            ):
                raise BootstrapError(
                    f"Native runtime is unavailable or escapes its root: {candidate}"
                )
        if not os.access(muxer, os.X_OK):
            raise BootstrapError(f"The .NET muxer is not executable: {muxer}")

    check_selected = check_runtime

    def pin(self, work, path):
        """Select an installed SDK the way a project does, with global.json."""
        if path.name == "dotnet.dll":
            (work / "global.json").write_text(
                json.dumps(
                    {
                        "sdk": {
                            "version": path.parent.name,
                            "rollForward": "disable",
                        }
                    }
                )
            )

    def identity(self, row, path):
        with tempfile.TemporaryDirectory(prefix="native-dotnet-") as work:
            self.pin(Path(work), path)
            return self.parse_identity(self.cli("--version", work=Path(work)))

    def canary(self, row, path, *, complete):
        """Build and run a console program offline, on the SDK under test."""
        with tempfile.TemporaryDirectory(prefix="native-canary-") as directory:
            work = Path(directory)
            self.pin(work, path)
            release = self.parse_identity(self.cli("--version", work=work))
            major = release.split(".")[0]
            (work / "canary.csproj").write_text(PROJECT.format(major=major))
            (work / "Program.cs").write_text(
                'System.Console.WriteLine("bootstrap-ok");\n'
            )
            (work / "nuget.config").write_text(OFFLINE)
            self.cli(
                "build",
                "-nologo",
                "-v",
                "quiet",
                "-p:UseSharedCompilation=false",
                "-o",
                work / "out",
                work=work,
            )
            output = self.cli(work / "out/canary.dll", work=work)
        if output != "bootstrap-ok":
            raise BootstrapError(f"dotnet runtime canary failed: {output}")

    # Global selection --------------------------------------------------------

    def read_selection(self):
        """The muxer picks the newest SDK; nothing records a selection."""
        return None

    def selected_runtime(self):
        return self.manager_candidates()[0]

    def initialize_default(self):
        """There is no global selection to initialize."""
