"""Native prerequisites, initial selections and shell qualification.

The adapters own artifact installation. This module joins those operations
behind the explicit bootstrap entry, never shell startup.
"""

import os
import shlex
import tarfile
import tempfile
from pathlib import Path

from . import process
from .errors import BootstrapError
from .paths import NIX_STORE

STAGES = ("prerequisites", "readiness", "runtimes", "defaults", "shell")


class BootstrapSetup:
    """Execute the Nix-declared post-Nix setup stages for native hosts."""

    def __init__(self, context):
        self.context = context
        self.recipe = context.data["setup"]
        self.stage = STAGES[0]

    @property
    def adapters(self):
        return self.context.adapters.values()

    def plan(self):
        """Filesystem-only readiness; package availability is checked at apply."""
        managers = []
        for adapter in self.adapters:
            try:
                managers.append(
                    {
                        "language": adapter.language,
                        "state": "present",
                        "path": str(adapter.manager()),
                    }
                )
            except BootstrapError as error:
                managers.append(
                    {
                        "language": adapter.language,
                        "state": "missing",
                        "reason": str(error),
                    }
                )
        return {
            "stages": list(STAGES),
            "nativeManagers": managers,
            "packageManager": self.recipe["packageManager"],
            "privilegedPackages": bool(self.recipe["privilege"]),
        }

    def prerequisites(self):
        rows = self.context.plan()
        incomplete = {
            row["language"] for row in rows if row["state"] != "present"
        }
        required = set()
        for adapter in self.adapters:
            try:
                adapter.manager()
            except BootstrapError:
                required.update(adapter.manager_packages())
            if adapter.language in incomplete:
                required.update(
                    self.recipe["buildPackages"].get(adapter.language, [])
                )
        building = any(
            adapter.compiles and adapter.language in incomplete
            for adapter in self.adapters
        )
        if building and self.recipe["sdkProbe"]:
            sdk = process.run(
                self.recipe["sdkProbe"],
                env=self.recipe.get("buildEnvironment", {}),
                source_build=True,
            )
            if not Path(sdk).is_dir():
                raise BootstrapError(
                    "Install/select Apple developer tools and accept their license"
                )
        if required:
            self.install_packages(required)
        for adapter in self.adapters:
            adapter.acquire()

    def install_packages(self, required):
        package_manager = Path(self.recipe["packageManager"])
        if (
            not package_manager.is_file()
            or package_manager.resolve().is_relative_to(NIX_STORE)
        ):
            raise BootstrapError(
                f"Post-Nix foundation missing: {package_manager}"
            )
        missing = self.missing_packages(package_manager, required)
        if not missing:
            return
        state = str(self.context.state)
        privilege = self.recipe["privilege"]
        command = [str(package_manager), *self.recipe["install"], *missing]
        if privilege:
            # sudo -n never prompts. Without cached credentials, stop before
            # any change and name the command instead of failing mid-install.
            try:
                process.run([*privilege, "/usr/bin/true"], cwd=state)
            except BootstrapError as error:
                raise BootstrapError(
                    "Missing native packages need administrator rights: run "
                    "`sudo -v` in this terminal and retry, or install them "
                    "with: " + shlex.join([Path(privilege[0]).name, *command])
                ) from error
        try:
            process.run(
                [*privilege, *command],
                env=self.recipe["environment"],
                timeout=1800,
                cwd=state,
            )
        except BootstrapError:
            # Homebrew exits 1 when it installs a formula but cannot link it
            # over a file another formula owns, such as an old openssl@1.1.
            # Build prerequisites are used through their opt prefixes, and
            # readiness still checks every manager executable, so only a
            # package that is still missing fails this stage.
            if self.missing_packages(package_manager, required):
                raise

    def missing_packages(self, package_manager, required):
        environment = self.recipe["environment"]
        state = str(self.context.state)
        if self.recipe.get("missingQuery"):
            # Pacman dependency tests honor installed providers such as
            # CachyOS's zlib-ng-compat. Exit 127 means missing dependencies.
            missing = process.run(
                [
                    str(package_manager),
                    *self.recipe["missingQuery"],
                    *sorted(required),
                ],
                env=environment,
                cwd=state,
                success_codes=(0, 127),
            ).splitlines()
            if not set(missing).issubset(required):
                raise BootstrapError(
                    "Unexpected native dependency query output"
                )
            return missing
        installed = set(
            process.run(
                [str(package_manager), *self.recipe["query"]],
                env=environment,
                cwd=state,
            ).splitlines()
        )
        return sorted(required - installed)

    def readiness(self):
        for adapter in self.adapters:
            adapter.readiness()

    def defaults(self):
        for adapter in self.adapters:
            adapter.initialize_default()

    def hooks(self):
        for adapter in self.adapters:
            adapter.repair_hooks()

    def health(self):
        """Read selected global runtimes; never create state or invoke managers."""
        return [row for adapter in self.adapters for row in adapter.selected()]

    def selections(self):
        """Verify each global selection by execution; report, never raise.

        Selections belong to the native managers. A broken or external one
        is returned to the caller and does not invalidate bootstrap-owned work.
        """
        return self.context.qualify(self.health(), exact=False)

    def shell(self, selections):
        """Check that a fresh production shell selects the verified runtimes.

        Only verified selections have an expected executable. External,
        blocked and conflicting ones remain in the report without a probe.
        Auxiliary components (Cabal) carry a component and are not selected
        by the shell.
        """
        qualified = {
            row["language"]: row
            for row in selections
            if row["state"] == "ok" and "component" not in row
        }
        languages = [
            language for language in self.context.only if language in qualified
        ]
        if not languages:
            return
        with tempfile.TemporaryDirectory(
            prefix="dev-bootstrap-shell-"
        ) as temporary:
            root = Path(temporary)
            # Production .zshenv exposes the package manager's directory
            # (Homebrew) before the language adapters load. The terminal that
            # runs bootstrap may predate it, for example right after this run
            # installed Homebrew, so the probe starts from that order too.
            search = [self.recipe["managerDirectory"]] + [
                entry
                for entry in os.environ.get("PATH", "").split(os.pathsep)
                if entry
            ]
            environment = {
                "PATH": os.pathsep.join(dict.fromkeys(search)),
                "HOME": str(root),
                "ZDOTDIR": str(root),
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_DATA_HOME": str(root / "data"),
                "XDG_STATE_HOME": str(root / "state"),
                "XDG_RUNTIME_DIR": str(root / "runtime"),
                **self.context.environment(),
                "DEV_BOOTSTRAP_ONLY": " ".join(languages),
                "ZSH_CONFIG_DIR": self.recipe["shellConfig"],
                "LCS_RUNTIME_MANAGER_BACKEND": "native",
                "LCS_NATIVE_FNM_READY": "1",
            }
            for language in languages:
                adapter = self.context.adapter(language)
                environment["DEV_BOOTSTRAP_EXPECTED_" + language.upper()] = (
                    qualified[language]["path"]
                )
                environment[
                    "DEV_BOOTSTRAP_NATIVE_" + adapter.manager_name.upper()
                ] = str(adapter.manager().resolve())
            (root / "runtime").mkdir(mode=0o700)
            output = process.run(
                [self.recipe["shell"], "-fi", self.recipe["shellProbe"]],
                env=environment,
                cwd=temporary,
            )
            observed = {}
            for line in output.splitlines():
                fields = line.split("\t")
                if len(fields) == 3 and fields[0] in languages:
                    observed[fields[0]] = Path(fields[1]).resolve()
            expected = {
                language: Path(qualified[language]["path"]).resolve()
                for language in languages
            }
            if observed != expected:
                raise BootstrapError(
                    f"Fresh shell selects unexpected runtimes: {output}"
                )

    def apply(self):
        """Run every stage and return the reported global selections."""
        context = self.context
        if os.geteuid() == 0:
            raise BootstrapError(
                "Run bootstrap as the owning account, never as root"
            )
        if Path("/etc/NIXOS").exists():
            raise BootstrapError("NixOS requires the explicit nixpkgs backend")
        if any(row["state"] == "conflict" for row in context.plan()):
            raise BootstrapError(
                "Inspect incomplete runtimes before prerequisite provisioning"
            )
        try:
            with context.locked():
                for stage, operation in [
                    ("prerequisites", self.prerequisites),
                    ("readiness", self.readiness),
                ]:
                    self.stage = stage
                    operation()
                self.stage = "runtimes"
                context.apply(context.plan(), lock_held=True, evolved=True)
                self.stage = "defaults"
                self.defaults()
                self.hooks()
                self.stage = "shell"
                selections = self.selections()
                self.shell(selections)
        except (
            BootstrapError,
            OSError,
            ValueError,
            tarfile.TarError,
        ) as error:
            raise BootstrapError(
                f"{self.stage}: {error}. Retry apply after resolving this stage; "
                "inspect incomplete prefixes rather than deleting them automatically."
            ) from error
        return selections
