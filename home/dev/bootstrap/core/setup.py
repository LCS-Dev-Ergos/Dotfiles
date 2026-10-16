"""Native prerequisites, initial selections and shell qualification.

The adapters own artifact installation. This module joins those operations
behind the explicit bootstrap entry, never shell startup.
"""

import os
import shlex
import tempfile
from pathlib import Path

from . import process
from .errors import BootstrapError
from .paths import NIX_STORE

STAGES = ("prerequisites", "readiness", "runtimes", "defaults", "shell")
COMPILER_MISSING = (
    "Runtimes built here record their C compiler, the Nix drivers of "
    "home/dev/toolchains/llvm, which no Home Manager profile provides yet: "
    "activate the configuration, then apply again"
)


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
        """Filesystem-only readiness; package availability is checked at apply.

        A missing manager says where apply gets it: its hash-checked
        installer or its native package. initialDefaults lists the
        ecosystems whose manager has no global selection yet, which the
        defaults stage sets to the declared release.
        """
        managers = []
        installers = self.recipe.get("installers", {})
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
                entry = {
                    "language": adapter.language,
                    "state": "missing",
                    "reason": str(error),
                }
                if adapter.language in installers:
                    entry["installer"] = installers[adapter.language]["url"]
                elif adapter.language in self.recipe.get("managers", {}):
                    entry["package"] = self.recipe["managers"][
                        adapter.language
                    ]
                managers.append(entry)
        return {
            "stages": list(STAGES),
            "nativeManagers": managers,
            "packageManager": self.recipe["packageManager"],
            "privilegedPackages": bool(self.recipe["privilege"]),
            "initialDefaults": [
                adapter.language
                for adapter in self.adapters
                if adapter.global_selection and adapter.selection() is None
            ],
        }

    def installable(self, rows):
        """Plan rows as apply sees them: missing managers come first.

        An adapter's plan blocks a runtime whose manager is missing, and
        stays right without this setup (--runtimes-only). Here the
        prerequisites stage installs every missing manager before the
        runtime stage, so such a runtime is missing like any other.
        """
        unavailable = {}
        for adapter in self.adapters:
            try:
                adapter.manager()
            except BootstrapError as error:
                unavailable[adapter.language] = (str(error), adapter)
        for row in rows:
            reason, adapter = unavailable.get(row["language"], (None, None))
            if row["state"] == "blocked" and row.get("reason") == reason:
                row.update(
                    state="missing",
                    reason=f"apply installs {adapter.manager_name} first",
                )
        return rows

    def required_packages(self):
        """The native packages each selected ecosystem needs, by language.

        Its build packages and, when an installer provides its manager, the
        installer's packages are needed whatever is already installed: the
        runtimes compile, link or load against the former and the manager
        runs the latter, so apply restores either when it went missing. A
        manager's own package is needed only while the manager is missing;
        an existing manager is adopted, never installed a second time.
        """
        required = {}
        for adapter in self.adapters:
            packages = set(
                self.recipe["buildPackages"].get(adapter.language, [])
            )
            if adapter.language in self.recipe.get("installers", {}):
                packages.update(self.recipe.get("installerPackages", []))
            try:
                adapter.manager()
            except BootstrapError:
                packages.update(adapter.manager_packages())
            required[adapter.language] = packages
        return required

    def building(self, rows, need):
        """Whether a runtime to install belongs to an adapter with `need`."""
        incomplete = {
            row["language"] for row in rows if row["state"] != "present"
        }
        return any(
            getattr(adapter, need) and adapter.language in incomplete
            for adapter in self.adapters
        )

    def needs_sdk(self, rows):
        """Whether a runtime to install builds from source against the SDK."""
        return bool(self.recipe["sdkProbe"]) and self.building(
            rows, "compiles"
        )

    def needs_compiler(self, rows):
        """Whether a runtime to install records the declared C compiler."""
        return bool(self.recipe.get("compilerProfiles")) and self.building(
            rows, "records_compiler"
        )

    def sdk_present(self, **options):
        try:
            sdk = process.run(
                self.recipe["sdkProbe"],
                env=self.context.build_environment(),
                source_build=True,
                **options,
            )
        except BootstrapError:
            return False
        return Path(sdk).is_dir()

    def prerequisites(self):
        rows = self.context.plan()
        required = set().union(*self.required_packages().values())
        if self.needs_sdk(rows) and not self.sdk_present():
            raise BootstrapError(
                "Install/select Apple developer tools and accept their license"
            )
        if (
            self.needs_compiler(rows)
            and self.context.compiler_profile() is None
        ):
            raise BootstrapError(COMPILER_MISSING)
        if required:
            self.install_packages(required)
        for adapter in self.adapters:
            with self.context.log(adapter.language):
                adapter.acquire()

    def foundation(self):
        """The package manager, when it is a native one apply may use."""
        package_manager = Path(self.recipe["packageManager"])
        if (
            package_manager.is_file()
            and not package_manager.resolve().is_relative_to(NIX_STORE)
        ):
            return package_manager
        return None

    def preflight(self):
        """What apply would install, and what would stop it, read-only.

        The native package query (pacman -T, brew list), the SDK probe and
        python-build's release list only read: nothing is created,
        installed or elevated, and no privileged command runs.
        """
        rows = self.context.plan()
        directory = self.context.query_directory
        required = self.required_packages()
        wanted = set().union(*required.values())
        package_manager = self.foundation()
        if package_manager is None:
            # Nothing can be installed without it; apply stops on these.
            missing = set(wanted)
        elif wanted:
            missing = set(
                self.missing_packages(package_manager, wanted, cwd=directory)
            )
        else:
            missing = set()
        privilege = self.recipe["privilege"]
        command = []
        if missing and package_manager is not None:
            command = [
                self.recipe["packageManager"],
                *self.recipe["install"],
                *sorted(missing),
            ]
            if privilege:
                command.insert(0, Path(privilege[0]).name)
        ecosystems = []
        for adapter in self.adapters:
            entry = {
                "language": adapter.language,
                "manager": "present",
                "packages": sorted(required[adapter.language]),
                "missing": sorted(required[adapter.language] & missing),
            }
            try:
                adapter.manager()
            except BootstrapError:
                entry["manager"] = "missing"
            selected = [
                row
                for row in rows
                if row["language"] == adapter.language
                and row["state"] == "missing"
            ]
            if selected and entry["manager"] == "present":
                unknown = adapter.unbuildable(selected)
                if unknown:
                    entry["unbuildable"] = unknown
            ecosystems.append(entry)
        result = {
            "packageManager": {
                "path": self.recipe["packageManager"],
                "state": "missing" if package_manager is None else "present",
            },
            "missing": sorted(missing),
            "privileged": bool(privilege and missing),
            "command": command,
            "ecosystems": ecosystems,
        }
        if self.needs_sdk(rows):
            result["sdk"] = (
                "present" if self.sdk_present(cwd=directory) else "missing"
            )
        if self.needs_compiler(rows):
            profile = self.context.compiler_profile()
            result["compiler"] = "missing" if profile is None else "present"
        return result

    def install_packages(self, required):
        package_manager = self.foundation()
        if package_manager is None:
            raise BootstrapError(
                f"Post-Nix foundation missing: {self.recipe['packageManager']}"
            )
        missing = self.missing_packages(package_manager, required)
        if not missing:
            return
        state = str(self.context.state)
        privilege = self.recipe["privilege"]
        command = [str(package_manager), *self.recipe["install"], *missing]
        if privilege:
            self.authenticate(command, state)
        with self.context.step(
            "packages",
            detail={
                "packages": missing,
                "command": [*privilege, *command],
                "privileged": bool(privilege),
            },
        ):
            try:
                process.run(
                    [*privilege, *command],
                    env=self.recipe["environment"],
                    timeout=1800,
                    cwd=state,
                )
            except BootstrapError as error:
                # Homebrew exits 1 when it installs a formula but cannot
                # link it over a file another formula owns, such as an old
                # openssl@1.1. Build prerequisites are used through their opt
                # prefixes, and readiness still checks every manager
                # executable, so only a package still missing fails here.
                if not self.missing_packages(package_manager, required):
                    return
                upgrade = self.upgrade(error, package_manager)
                if upgrade:
                    raise BootstrapError(
                        f"{error}\nThe package database looks older than "
                        f"its mirrors: upgrade the system with `{upgrade}`, "
                        "then apply again"
                    ) from error
                raise

    def authenticate(self, command, state):
        """Make sure the privileged install cannot stop for a password.

        The install runs through `sudo -n`, which never prompts. Without
        cached credentials, an attended apply prints the command and lets
        the privilege tool ask once; an unattended one stops before any
        change and names the command instead of failing mid-install.
        """
        privilege = self.recipe["privilege"]
        shown = shlex.join([Path(privilege[0]).name, *command])
        try:
            process.run([*privilege, "/usr/bin/true"], cwd=state)
            return
        except BootstrapError as error:
            uncached = error
        login = self.recipe.get("authenticate")
        if not login or not process.attended():
            retry = ""
            if login:
                retry = (
                    f"run `{shlex.join([Path(login[0]).name, *login[1:]])}` "
                    "in this terminal and retry, or "
                )
            raise BootstrapError(
                "Missing native packages need administrator rights: "
                f"{retry}install them with: {shown}"
            ) from uncached
        process.announce(
            "installing the missing native packages needs administrator "
            f"rights; this runs\n  {shown}"
        )
        try:
            process.attend(login)
        except BootstrapError as error:
            raise BootstrapError(
                "Administrator authentication failed; install the packages "
                f"with: {shown}"
            ) from error

    def upgrade(self, error, package_manager):
        """The full upgrade a failed install needs, when its database is stale.

        A sync database older than the mirrors fails with signs the recipe
        declares (pacman's missing targets and 404s). Refreshing it alone
        would be a partial upgrade, so we name the whole one and never run it.
        """
        stale = self.recipe.get("staleDatabase")
        if not stale or not any(sign in str(error) for sign in stale["signs"]):
            return ""
        privilege = self.recipe["privilege"]
        upgrade = [str(package_manager), *stale["upgrade"]]
        if privilege:
            upgrade.insert(0, Path(privilege[0]).name)
        return shlex.join(upgrade)

    def missing_packages(self, package_manager, required, *, cwd=None):
        environment = self.recipe["environment"]
        state = cwd or str(self.context.state)
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
            with self.context.log(adapter.language):
                adapter.readiness()

    def defaults(self):
        for adapter in self.adapters:
            with self.context.log(adapter.language):
                adapter.initialize_default()

    def hooks(self):
        for adapter in self.adapters:
            with self.context.log(adapter.language):
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
            # The managers' roots first: the probe's own home and XDG
            # directories then win over any an adapter passes its manager
            # (alr's settings follow the account's XDG directories).
            environment = {
                **self.context.environment(),
                "PATH": os.pathsep.join(dict.fromkeys(search)),
                "HOME": str(root),
                "ZDOTDIR": str(root),
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_DATA_HOME": str(root / "data"),
                "XDG_STATE_HOME": str(root / "state"),
                "XDG_RUNTIME_DIR": str(root / "runtime"),
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

    def qualify(self):
        """Verify the global selections, then that a fresh shell uses them."""
        selections = self.selections()
        self.shell(selections)
        return selections

    def run_stage(self, stage, operation):
        """One stage: named for an interruption, logged, reported as events.

        Child output outside any ecosystem goes to the stage's own log.
        """
        self.stage = stage
        with self.context.step("stage", stage=stage), self.context.log(stage):
            return operation()

    def apply(self):
        """Run every stage and return the reported global selections."""
        context = self.context
        context.require_consents()
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
                self.run_stage("prerequisites", self.prerequisites)
                self.run_stage("readiness", self.readiness)
                self.run_stage(
                    "runtimes",
                    lambda: context.apply(
                        context.plan(), lock_held=True, evolved=True
                    ),
                )
                self.run_stage(
                    "defaults", lambda: (self.defaults(), self.hooks())
                )
                selections = self.run_stage("shell", self.qualify)
        except (BootstrapError, OSError, ValueError) as error:
            raise BootstrapError(
                f"{self.stage}: {error}. Retry apply after resolving this "
                "stage; plan reports any incomplete installation."
            ) from error
        return selections
