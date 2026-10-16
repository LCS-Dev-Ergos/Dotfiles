"""Ada through Alire: the GNAT compiler and gprbuild, as alr deploys them.

alr keeps each toolchain release in its own directory of the toolchain
folder, named after the crate, the release and the start of the archive's
hash, which alr checks against its index. The global selection lives in
alr's settings file. Installing a release without selecting it needs a
workspace: `alr toolchain --select --local` inside a throwaway crate
downloads into the shared folder and records the choice in that crate only.
"""

import os
import re
import tempfile
import tomllib
import zipfile
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from ..paths import root_path
from .toolchain import RELEASE, ToolchainAdapter

# The crate that provides each component, as alr names it in a selection.
CRATES = {"gnat": "gnat_native", "gprbuild": "gprbuild"}
# A deployed release: <crate>_<release>_<first 8 hex digits of its hash>.
DEPLOYED = re.compile(rf"([a-z0-9_]+?)_({RELEASE})_[0-9a-f]{{8}}")
# A settings value: <crate>=<release>.
CHOICE = re.compile(rf"([a-z0-9_]+)=({RELEASE})")
# Never prompt, colour or redraw: every call runs without a terminal.
SWITCHES = ("-n", "--no-color", "--no-tty")
CANARY = """with Ada.Text_IO;
procedure Canary is
begin
   Ada.Text_IO.Put_Line ("bootstrap-ok");
end Canary;
"""
PROJECT = """project Canary is
   for Main use ("canary.adb");
   for Object_Dir use "obj";
   for Exec_Dir use ".";
end Canary;
"""


def setting(settings, *keys):
    """A value in alr's settings by its dotted key, or None when unset.

    Every level but the last must be a table; anything else is a settings
    file alr itself would not read, which needs a person.
    """
    value = settings
    for depth, key in enumerate(keys):
        if not isinstance(value, dict):
            raise BootstrapError(
                f"Inspect the Alire setting {'.'.join(keys[:depth])}: "
                "it is not a table"
            )
        value = value.get(key)
        if value is None:
            return None
    if len(keys) > 1 and keys[-1] == "dir" and not isinstance(value, str):
        raise BootstrapError(
            f"Inspect the Alire setting {'.'.join(keys)}: it is not a path"
        )
    return value


class AdaAdapter(ToolchainAdapter):
    language = "ada"
    title = "Ada"
    component_titles = {"gnat": "GNAT", "gprbuild": "GPRbuild"}
    primary_component = "gnat"
    cost = "medium"
    manager_name = "alr"
    # GNAT links with the platform's linker, and alr clones its index with
    # the platform's git: both come with the Apple developer tools.
    compiles = True

    @classmethod
    def validate_declaration(cls, spec):
        super().validate_declaration(spec)
        if not re.fullmatch(RELEASE, spec["gprbuild"]):
            raise BootstrapError("Invalid gprbuild release")

    def resolve_roots(self):
        settings = self.locate(
            "ALIRE_SETTINGS_DIR", self.config_home() / "alire"
        )
        configured = self.settings(settings)
        cache = setting(configured, "cache", "dir")
        if not cache:
            # An explicit settings directory takes the cache along with it;
            # otherwise the cache follows the data home.
            if os.environ.get("ALIRE_SETTINGS_DIR"):
                cache = settings / "cache"
            else:
                cache = self.data_home() / "alire"
        toolchains = setting(configured, "toolchain", "dir")
        if not toolchains:
            toolchains = Path(cache) / "toolchains"
        # Named after the setting that moves them; no variable does.
        return {
            "toolchain.dir": self.locate(
                "toolchain.dir", toolchains, from_environment=False
            ),
            "ALIRE_SETTINGS_DIR": settings,
            # Where alr itself lives. Alire names no such directory; the
            # shell puts ALR_HOME/bin on PATH, ~/.ada/bin by default.
            "ALR_HOME": self.locate("ALR_HOME", Path.home() / ".ada"),
        }

    @staticmethod
    def config_home():
        return root_path("XDG_CONFIG_HOME", Path.home() / ".config")

    @staticmethod
    def data_home():
        return root_path("XDG_DATA_HOME", Path.home() / ".local/share")

    @staticmethod
    def settings(directory):
        """alr's global settings, or nothing before its first run."""
        path = directory / "settings.toml"
        if os.path.lexists(path) and not path.is_file():
            raise BootstrapError("Inspect the existing Alire settings file")
        if not path.is_file():
            return {}
        try:
            return tomllib.loads(path.read_text())
        except (OSError, ValueError) as error:
            raise BootstrapError(
                f"Cannot read Alire settings {path}: {error}"
            ) from error

    @property
    def home(self):
        return self.roots["ALR_HOME"]

    def environment(self):
        # alr derives its settings and cache from these the way
        # resolve_roots does; a child would not inherit them otherwise.
        # Naming the settings directory explicitly would move the cache
        # into it, so it is passed only when the account already does.
        environment = {
            "XDG_CONFIG_HOME": str(self.config_home()),
            "XDG_DATA_HOME": str(self.data_home()),
            "ALR_HOME": str(self.home),
        }
        if os.environ.get("ALIRE_SETTINGS_DIR"):
            environment["ALIRE_SETTINGS_DIR"] = str(
                self.roots["ALIRE_SETTINGS_DIR"]
            )
        return environment

    def invoke(self, *arguments, timeout=7200, cwd=None):
        return process.run(
            [str(self.manager()), *SWITCHES, *arguments],
            env=self.build_environment | self.environment(),
            source_build=True,
            cwd=str(cwd or self.context.state),
            timeout=timeout,
        )

    def install_manager(self, recipe, payload, directory):
        """Place the verified archive's alr, which runs without setup."""
        try:
            with zipfile.ZipFile(payload) as archive:
                launcher = archive.read("bin/alr")
        except (KeyError, zipfile.BadZipFile) as error:
            raise BootstrapError(
                "The Alire release archive has no bin/alr"
            ) from error
        target = self.manager_candidates()[0]
        target.parent.mkdir(parents=True, exist_ok=True)
        staged = target.with_name(".alr.partial")
        staged.write_bytes(launcher)
        staged.chmod(0o755)
        os.replace(staged, target)

    # Declared baseline -------------------------------------------------------

    def deployed(self, crate, release):
        """The directory alr deployed a release into, or None."""
        if not self.root.is_dir():
            return None
        matches = sorted(
            path
            for path in self.root.glob(f"{crate}_{release}_*")
            if (found := DEPLOYED.fullmatch(path.name))
            and found.group(1) == crate
        )
        return matches[0] if matches else None

    def release_binary(self, component, release, crate=None):
        crate = crate or CRATES[component]
        prefix = self.deployed(crate, release)
        if prefix is None:
            # Not deployed yet: a path that names the release, never found.
            prefix = self.root / f"{crate}_{release}"
        return prefix / "bin" / component

    def binary(self, selection=None):
        return self.release_binary("gnat", selection or self.spec["version"])

    def declared_release(self, component):
        return self.spec["version" if component == "gnat" else component]

    def baseline(self):
        return [
            self.row(
                self.declared_release(component),
                self.release_binary(
                    component, self.declared_release(component)
                ),
                component=component,
            )
            for component in CRATES
        ]

    def prefix(self, row):
        prefix = Path(row["path"]).parent.parent
        return prefix if DEPLOYED.fullmatch(prefix.name) else None

    def install(self, row):
        component = row["component"]
        with tempfile.TemporaryDirectory(
            prefix="native-alire-", dir=self.context.state
        ) as work:
            self.invoke(
                "init", "--bin", "--no-skel", "bootstrap_seed", cwd=work
            )
            self.invoke(
                "toolchain",
                "--select",
                "--local",
                f"{CRATES[component]}={row['version']}",
                cwd=Path(work) / "bootstrap_seed",
            )
        row["path"] = str(self.release_binary(component, row["version"]))

    def installed(self):
        if not self.root.is_dir():
            return []
        return sorted(
            f"{found.group(1)}={found.group(2)}"
            for path in self.root.iterdir()
            if (found := DEPLOYED.fullmatch(path.name))
        )

    # Verification ------------------------------------------------------------

    def identity(self, row, path):
        """The release alr deployed: GNAT reports its GCC version instead."""
        metadata = path.parent.parent / "alire.toml"
        try:
            release = tomllib.loads(metadata.read_text())
        except (OSError, ValueError) as error:
            raise BootstrapError(
                f"Cannot read the deployed Alire release {metadata}: {error}"
            ) from error
        version = release.get("version")
        if not isinstance(version, str) or not re.fullmatch(RELEASE, version):
            raise BootstrapError(f"Unrecognized Alire release in {metadata}")
        return version

    def compiler(self):
        """The GNAT gprbuild drives: the declared one, else the selected one."""
        declared = self.binary()
        if declared.is_file():
            return declared
        selected = self.selected_runtime()
        if selected is None:
            raise BootstrapError(
                "gprbuild needs an Alire GNAT; apply ada first"
            )
        return selected

    def canary_environment(self, *directories):
        """The build environment with these toolchain directories first.

        Nothing else is added: the canary builds the way a plain `alr build`
        does, so a GNAT that cannot find the SDK or target this macOS fails
        here instead of in a project.
        """
        environment = self.build_environment
        search = os.pathsep.join(
            [*(str(directory) for directory in directories)]
            + [environment.get("PATH", "/usr/bin:/bin")]
        )
        return environment | {"PATH": search}

    def canary(self, row, path, *, complete):
        """Compile and run a small program; gprbuild drives the GNAT above."""
        gprbuild = row.get("component") == "gprbuild"
        compiler = self.compiler() if gprbuild else path
        self.check_runtime(compiler)
        environment = self.canary_environment(
            *dict.fromkeys((path.parent, compiler.parent))
        )
        with tempfile.TemporaryDirectory(prefix="native-canary-") as directory:
            work = Path(directory)
            (work / "canary.adb").write_text(CANARY)

            def call(args):
                return process.run(
                    [str(arg) for arg in args],
                    env=environment,
                    source_build=True,
                    cwd=directory,
                    timeout=300,
                )

            if gprbuild:
                (work / "canary.gpr").write_text(PROJECT)
                call([path, "-q", "-P", work / "canary.gpr"])
            else:
                call([path.parent / "gnatmake", "-q", "canary.adb"])
            output = call([work / "canary"])
        if output != "bootstrap-ok":
            raise BootstrapError(f"ada runtime canary failed: {output}")

    # Global selection --------------------------------------------------------

    def choice(self, component):
        """The crate and release the global settings select, or None."""
        value = setting(
            self.settings(self.roots["ALIRE_SETTINGS_DIR"]),
            "toolchain",
            "use",
            component,
        )
        if value is None:
            return None
        found = CHOICE.fullmatch(value) if isinstance(value, str) else None
        if not found:
            raise BootstrapError(f"Invalid Alire {component} selection")
        return found.group(1), found.group(2)

    def read_selection(self):
        choice = self.choice("gnat")
        return None if choice is None else "=".join(choice)

    def selected_tool(self, component):
        """The selected executable; None when the host provides the tool."""
        choice = self.choice(component)
        if choice is None:
            raise BootstrapError(f"No global {component} selection")
        crate, release = choice
        if crate.endswith("_external"):
            return None
        return self.release_binary(component, release, crate)

    def selected_runtime(self):
        return self.selected_tool("gnat")

    def selected(self):
        rows = super().selected()
        row = {
            "language": self.language,
            "component": "gprbuild",
            "version": self.spec["gprbuild"],
            "path": "",
            "owner": self.manager_name,
        }
        try:
            path = self.selected_tool("gprbuild")
            if path is None:
                row.update(
                    state="external",
                    reason="The global selection uses the host's gprbuild",
                )
            else:
                self.check_runtime(path)
                row.update(state="present", path=str(path))
        except BootstrapError as error:
            row.update(state="blocked", reason=str(error))
        return [*rows, row]

    def initialize_default(self):
        missing = [
            f"{crate}={self.declared_release(component)}"
            for component, crate in CRATES.items()
            if self.choice(component) is None
        ]
        if missing:
            self.invoke("toolchain", "--select", *missing)
