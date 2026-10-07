"""Native prerequisites, initial selections and shell qualification.

The runtime executor owns artifact installation. This module joins those
operations behind the explicit bootstrap entry, never shell startup.
"""

import os
import re
import tempfile
import tarfile
from pathlib import Path

from engine import MANAGERS
from support import (
    FNM_SYSTEM_TARGET,
    SYSTEM_SELECTION,
    BootstrapError,
    external_selection,
    run,
    writable_directory,
)
from native_toolchains import LANGUAGES


class BootstrapSetup:
    """Execute the Nix-declared post-Nix setup stages for native hosts."""

    def __init__(self, recovery):
        self.recovery = recovery
        self.recipe = recovery.data["setup"]
        self.stage = "prerequisites"

    def manager(self, language):
        return self.recovery.manager(language)

    def plan(self):
        """Filesystem-only readiness; package availability is checked at apply."""
        managers = []
        for language in self.recovery.only:
            try:
                path = str(self.manager(language))
                managers.append(
                    {"language": language, "state": "present", "path": path}
                )
            except BootstrapError as error:
                managers.append(
                    {
                        "language": language,
                        "state": "missing",
                        "reason": str(error),
                    }
                )
        return {
            "stages": [
                "prerequisites",
                "readiness",
                "runtimes",
                "defaults",
                "shell",
            ],
            "nativeManagers": managers,
            "packageManager": self.recipe["packageManager"],
            "privilegedPackages": bool(self.recipe["privilege"]),
        }

    def prerequisites(self):
        recovery = self.recovery
        rows = recovery.plan()
        required = set()
        for language in recovery.only:
            try:
                self.manager(language)
            except BootstrapError:
                package = self.recipe["managers"].get(language)
                if package:
                    required.add(package)
                if language in LANGUAGES and language != "ruby":
                    required.update(self.recipe.get("installerPackages", []))
            if any(
                row["language"] == language and row["state"] != "present"
                for row in rows
            ):
                required.update(self.recipe["buildPackages"].get(language, []))
        building = any(
            row["language"] in ("python", "ocaml", "ruby", "haskell", "rust")
            and row["state"] != "present"
            for row in rows
        )
        if building and self.recipe["sdkProbe"]:
            sdk = run(
                self.recipe["sdkProbe"],
                env=self.recipe.get("buildEnvironment", {}),
                source_build=True,
            )
            if not Path(sdk).is_dir():
                raise BootstrapError(
                    "Install/select Apple developer tools and accept their license"
                )
        if not required:
            recovery.native.acquire()
            return
        package_manager = Path(self.recipe["packageManager"])
        if (
            not package_manager.is_file()
            or package_manager.resolve().is_relative_to(Path("/nix/store"))
        ):
            raise BootstrapError(
                f"Post-Nix foundation missing: {package_manager}"
            )
        environment = self.recipe["environment"]
        if self.recipe.get("missingQuery"):
            # Pacman dependency tests honor installed providers such as
            # CachyOS's zlib-ng-compat. Exit 127 means missing dependencies.
            missing = run(
                [
                    str(package_manager),
                    *self.recipe["missingQuery"],
                    *sorted(required),
                ],
                env=environment,
                cwd=str(recovery.state),
                success_codes=(0, 127),
            ).splitlines()
            if not set(missing).issubset(required):
                raise BootstrapError(
                    "Unexpected native dependency query output"
                )
        else:
            installed = set(
                run(
                    [str(package_manager), *self.recipe["query"]],
                    env=environment,
                    cwd=str(recovery.state),
                ).splitlines()
            )
            missing = sorted(required - installed)
        if missing:
            run(
                [
                    *self.recipe["privilege"],
                    str(package_manager),
                    *self.recipe["install"],
                    *missing,
                ],
                env=environment,
                timeout=1800,
                cwd=str(recovery.state),
            )
        recovery.native.acquire()

    def readiness(self):
        for language in self.recovery.only:
            if language in LANGUAGES:
                self.recovery.native.readiness(language)
                continue
            output = run([str(self.manager(language)), "--version"])
            match = re.search(r"[0-9]+\.[0-9]+\.[0-9]+", output)
            minimum = self.recovery.data["policy"]["managerMinimums"][language]
            if not match or tuple(map(int, match.group().split("."))) < tuple(
                map(int, minimum.split("."))
            ):
                raise BootstrapError(
                    f"Unsupported native manager: {output}; requires >= {minimum}"
                )
        if "node" in self.recovery.only:
            writable_directory(self.recovery.fnm)
            link = self.recovery.fnm / "fnm"
            native = self.manager("node")
            # Existing shell adapters prioritize this single-command directory
            # when native readiness is enabled, without promoting all Homebrew.
            if os.path.lexists(link):
                if link.resolve() != native.resolve():
                    raise BootstrapError(
                        f"Conflicting native FNM exposure: {link}"
                    )
            else:
                link.symlink_to(native)

    def defaults(self):
        recovery = self.recovery
        recovery.native.defaults()
        defaults = recovery.data["defaults"]
        selected = recovery.observed_state()["globalSelections"]
        # These managers share a file-backed, absence-only default contract.
        # opam's repository/global-switch state needs its own validation below.
        selections = (
            (
                "node",
                recovery.fnm / "aliases/default",
                "nodeDefault",
                {"root": str(recovery.fnm)},
                {},
            ),
            (
                "python",
                recovery.pyenv / "version",
                "pythonDefault",
                {},
                {"PYENV_ROOT": str(recovery.pyenv)},
            ),
        )
        for language, marker, command, bindings, environment in selections:
            if language in recovery.only and not os.path.lexists(marker):
                run(
                    [
                        str(self.manager(language)),
                        *recovery.arguments(
                            command, version=defaults[language], **bindings
                        ),
                    ],
                    env=environment,
                    cwd=str(recovery.state),
                )
        if "ocaml" in recovery.only and selected["ocaml"] is None:
            config = recovery.opam / "config"
            if config.is_file() and re.search(
                r"^switch:", config.read_text(), re.MULTILINE
            ):
                raise BootstrapError(
                    "Inspect the existing opam global selection"
                )
            recovery.ocaml.run(
                *recovery.arguments(
                    "opamDefault", switch=f"lcs-ocaml-{defaults['ocaml']}"
                )
            )

    def hooks(self):
        if "python" in self.recovery.only:
            shim = self.recovery.pyenv / "shims/python"
            if not shim.is_file():
                run(
                    [
                        str(self.manager("python")),
                        *self.recovery.arguments("pythonRehash"),
                    ],
                    env={"PYENV_ROOT": str(self.recovery.pyenv)},
                    cwd=str(self.recovery.state),
                )
            if not shim.is_file():
                raise BootstrapError(
                    "pyenv did not create the requested Python shim"
                )
        if "ocaml" not in self.recovery.only:
            return
        hook = self.recovery.opam / "opam-init/env_hook.zsh"
        if not hook.is_file():
            self.recovery.ocaml.run(*self.recovery.arguments("opamHooks"))
        if not hook.is_file():
            raise BootstrapError("opam did not create the requested Zsh hook")

    def health(self):
        """Read selected global runtimes; never create state or invoke managers."""
        recovery = self.recovery
        selected = recovery.observed_state()["globalSelections"]
        rows = []
        for language in recovery.only:
            if language in LANGUAGES:
                continue
            try:
                self.manager(language)
                delegated = {
                    "language": language,
                    "version": recovery.data["defaults"][language],
                    "owner": self.recipe["managers"][language],
                }
                if language == "node":
                    alias = recovery.fnm / "aliases/default"
                    if not alias.is_symlink():
                        raise BootstrapError("No valid FNM default alias")
                    if os.readlink(alias) == FNM_SYSTEM_TARGET:
                        rows.append(external_selection(delegated))
                        continue
                    executable = alias.resolve() / "bin/node"
                    if not executable.is_relative_to(recovery.fnm):
                        raise BootstrapError(
                            "FNM default escapes its runtime root"
                        )
                elif language == "python":
                    selection = (selected[language] or "").split()
                    if selection[:1] == [SYSTEM_SELECTION]:
                        rows.append(external_selection(delegated))
                        continue
                    if not selection or not re.fullmatch(
                        r"[A-Za-z0-9][A-Za-z0-9._-]*", selection[0]
                    ):
                        raise BootstrapError(
                            "No supported pyenv global selection"
                        )
                    executable = (
                        recovery.pyenv
                        / "versions"
                        / selection[0]
                        / "bin/python"
                    )
                else:
                    selection = selected[language]
                    if not selection:
                        raise BootstrapError("No global opam switch selected")
                    if Path(selection).is_absolute():
                        executable = Path(selection) / "_opam/bin/ocamlc"
                    elif re.fullmatch(
                        r"[A-Za-z0-9][A-Za-z0-9._-]*", selection
                    ):
                        executable = recovery.opam / selection / "bin/ocamlc"
                    else:
                        raise BootstrapError(
                            "Unsupported opam global switch identity"
                        )
                if (
                    not executable.is_file()
                    or executable.resolve().is_relative_to(Path("/nix/store"))
                ):
                    raise BootstrapError(
                        f"Selected native runtime is unavailable: {executable}"
                    )
                rows.append(
                    {
                        "language": language,
                        "path": str(executable),
                        "version": recovery.data["defaults"][language],
                        "state": "present",
                        "owner": self.recipe["managers"][language],
                    }
                )
            except BootstrapError as error:
                rows.append(
                    {
                        "language": language,
                        "version": recovery.data["defaults"][language],
                        "path": "",
                        "state": "blocked",
                        "reason": str(error),
                    }
                )
        return rows + recovery.native.health()

    def selections(self):
        """Verify each global selection by execution; report, never raise.

        Selections belong to the native managers. A broken or external one
        is returned to the caller and does not invalidate bootstrap-owned work.
        """
        recovery = self.recovery
        rows = self.health()
        for row in rows:
            if row["state"] != "present":
                continue
            try:
                row["actualVersion"] = recovery.verify_healthy_runtime(row)
                if row["language"] == "ocaml" and recovery.ocaml.read_pending(
                    row
                ):
                    raise BootstrapError(
                        "Repository handover is still pending"
                    )
                row["state"] = "ok"
            except BootstrapError as error:
                row.update(state="conflict", reason=str(error))
        return rows

    def shell(self, selections):
        """Check that a fresh production shell selects the verified runtimes.

        Only verified selections have an expected executable. External,
        blocked and conflicting ones remain in the report without a probe.
        """
        recovery = self.recovery
        qualified = {
            row["language"]: row
            for row in selections
            if row["state"] == "ok" and row.get("component") != "cabal"
        }
        languages = [
            language for language in recovery.only if language in qualified
        ]
        if not languages:
            return
        with tempfile.TemporaryDirectory(
            prefix="dev-bootstrap-shell-"
        ) as temporary:
            root = Path(temporary)
            environment = {
                "HOME": str(root),
                "ZDOTDIR": str(root),
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_DATA_HOME": str(root / "data"),
                "XDG_STATE_HOME": str(root / "state"),
                "XDG_RUNTIME_DIR": str(root / "runtime"),
                "FNM_DIR": str(recovery.fnm),
                "PYENV_ROOT": str(recovery.pyenv),
                "OPAMROOT": str(recovery.opam),
                "DEV_BOOTSTRAP_ONLY": " ".join(languages),
                "ZSH_CONFIG_DIR": self.recipe["shellConfig"],
                "LCS_RUNTIME_MANAGER_BACKEND": "native",
                "LCS_NATIVE_FNM_READY": "1",
            }
            environment.update(recovery.native.environment())
            for language in languages:
                if language in LANGUAGES:
                    environment[
                        "DEV_BOOTSTRAP_EXPECTED_" + language.upper()
                    ] = qualified[language]["path"]
                environment[
                    "DEV_BOOTSTRAP_NATIVE_" + MANAGERS[language].upper()
                ] = str(self.manager(language).resolve())
            (root / "runtime").mkdir(mode=0o700)
            output = run(
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
        recovery = self.recovery
        if os.geteuid() == 0:
            raise BootstrapError(
                "Run bootstrap as the owning account, never as root"
            )
        if Path("/etc/NIXOS").exists():
            raise BootstrapError("NixOS requires the explicit nixpkgs backend")
        if any(row["state"] == "conflict" for row in recovery.plan()):
            raise BootstrapError(
                "Inspect incomplete runtimes before prerequisite provisioning"
            )
        try:
            with recovery.locked():
                for stage, operation in [
                    ("prerequisites", self.prerequisites),
                    ("readiness", self.readiness),
                ]:
                    self.stage = stage
                    operation()
                self.stage = "runtimes"
                recovery.apply(recovery.plan(), lock_held=True, evolved=True)
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
