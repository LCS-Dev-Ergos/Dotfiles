"""Node, Python and OCaml: managers driven through the declared argv policy."""

import os
import re
from pathlib import Path

from .. import process
from ..errors import BootstrapError
from .base import Retirer, Step, numeric
from .inventory import node_globals, python_distributions, virtual_environments

SWITCH_ROOTS = re.compile(r"^roots:\s*\[(.*?)\]", re.MULTILINE | re.DOTALL)
# Packages a fresh `opam switch create` may record as roots.
COMPILERS = frozenset(
    {
        "ocaml",
        "ocaml-base-compiler",
        "ocaml-compiler",
        "ocaml-config",
        "ocaml-system",
        "ocaml-variants",
    }
)
COMPILER_PREFIXES = ("ocaml-option", "base-", "host-arch-", "host-system-")


def described(names, limit=6):
    names = sorted(names)
    shown = ", ".join(names[:limit])
    return shown + (
        f" and {len(names) - limit} more" if len(names) > limit else ""
    )


class NodeRetirer(Retirer):
    depth = 1

    def paths(self):
        return {None: "node.versions"}

    def prefix(self, release, component):
        return self.adapter.root / "node-versions" / f"v{release}"

    def inspect(self, retirement):
        prefix = retirement.prefix.resolve()
        aliases = self.adapter.root / "aliases"
        if aliases.is_dir():
            for alias in sorted(aliases.iterdir()):
                if (
                    alias.name != "default"
                    and alias.is_symlink()
                    and alias.resolve().is_relative_to(prefix)
                ):
                    retirement.blockers.append(
                        f"the fnm alias {alias.name} points to it"
                    )
        packages = node_globals(retirement.prefix / "installation")
        linked = [name for name, version in packages.items() if not version]
        if linked:
            retirement.blockers.append(
                f"globally linked packages need relinking: {described(linked)}"
            )
        target = self.prefix(retirement.successor, None) / "installation"
        present = node_globals(target)
        missing = {
            name: version
            for name, version in packages.items()
            if version and name not in present
        }
        if not missing:
            return
        if not target.is_dir():
            retirement.blockers.append(
                f"its global packages need {retirement.successor} "
                "installed; apply first"
            )
            return
        retirement.steps.append(
            Step(
                f"install global packages into {retirement.successor}: "
                + described(missing),
                lambda: self.install_globals(target, missing),
            )
        )

    def install_globals(self, installation, packages):
        binaries = installation / "bin"
        process.run(
            [
                str(binaries / "npm"),
                "install",
                "--global",
                "--prefix",
                str(installation),
                "--no-fund",
                "--no-audit",
                "--no-update-notifier",
                *(f"{name}@{version}" for name, version in packages.items()),
            ],
            # npm runs through `#!/usr/bin/env node`: the successor first.
            env={
                "PATH": f"{binaries}{os.pathsep}{os.environ.get('PATH', '')}"
            },
            cwd=str(self.context.state),
            timeout=1800,
        )

    def fnm(self, operation, version):
        process.run(
            [
                str(self.adapter.manager()),
                *self.context.arguments(
                    operation, root=str(self.adapter.root), version=version
                ),
            ],
            env={},
            cwd=str(self.context.state),
        )

    def reselect(self, retirement):
        self.fnm("nodeDefault", retirement.successor)

    def uninstall(self, retirement):
        self.fnm("nodeUninstall", retirement.release)


class PythonRetirer(Retirer):
    depth = 2

    def paths(self):
        return {None: "python.version"}

    def prefix(self, release, component):
        return self.adapter.root / "versions" / release

    def inspect(self, retirement):
        release, successor = retirement.release, retirement.successor
        prefix = retirement.prefix
        target = self.prefix(successor, None)
        selection = (self.adapter.selection() or "").split()
        if release in selection and len(selection) > 1:
            retirement.blockers.append(
                "the global pyenv selection names it among several "
                "releases; change it with `pyenv global`"
            )
        environments = prefix / "envs"
        if environments.is_dir() and any(environments.iterdir()):
            retirement.blockers.append(
                "pyenv-virtualenv environments live inside it: "
                + described(path.name for path in environments.iterdir())
            )
        same_minor = numeric(release)[:2] == numeric(successor)[:2]
        dependents = [
            path
            for path, settings in virtual_environments()
            if inside(settings.get("home"), prefix)
        ]
        if dependents and not same_minor:
            retirement.blockers.append(
                f"{len(dependents)} virtual environments use it and "
                f"{successor} is another minor release; recreate them"
            )
        # A copied interpreter keeps running this release's own binary.
        copied = [
            str(path)
            for path in dependents
            if not (path / "bin/python").is_symlink()
        ]
        if copied:
            retirement.blockers.append(
                "virtual environments with a copied interpreter need "
                f"recreating: {described(copied)}"
            )
        present = python_distributions(target)
        missing = {
            name: version
            for name, version in python_distributions(prefix).items()
            if name not in present
        }
        if (dependents or missing) and not target.is_dir():
            retirement.blockers.append(
                f"what it holds needs {successor} installed; apply first"
            )
        retirement.notes.append(
            "environments elsewhere, such as a project's .venv, are not checked"
        )
        if retirement.blockers:
            return
        if dependents:
            retirement.steps.append(
                Step(
                    f"repoint {len(dependents)} virtual environments to "
                    f"{successor}",
                    lambda: self.repoint(dependents, retirement, target),
                )
            )
        if missing:
            retirement.steps.append(
                Step(
                    f"install into {successor}: {described(missing)}",
                    lambda: self.install_distributions(target, missing),
                )
            )

    def repoint(self, environments, retirement, target):
        """Same minor release: only the interpreter links and settings move."""
        old = retirement.prefix
        for environment in environments:
            for link in sorted((environment / "bin").iterdir()):
                if not link.is_symlink():
                    continue
                destination = Path(os.readlink(link))
                if not destination.is_absolute() or not inside(
                    destination, old
                ):
                    continue
                moved = target / destination.relative_to(old)
                if not moved.exists():
                    raise BootstrapError(f"{moved} does not exist")
                replace_symlink(link, moved)
            rewrite_settings(
                environment / "pyvenv.cfg",
                old,
                target,
                retirement.release,
                retirement.successor,
            )
            reported = process.run(
                [
                    str(environment / "bin/python"),
                    "-I",
                    "-c",
                    "import platform; print(platform.python_version())",
                ],
                cwd=str(self.context.state),
            )
            if reported != retirement.successor:
                raise BootstrapError(
                    f"{environment} runs Python {reported} after repointing"
                )

    def install_distributions(self, target, distributions):
        process.run(
            [
                str(target / "bin/python"),
                "-I",
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "--no-input",
                *(
                    f"{name}=={version}"
                    for name, version in distributions.items()
                ),
            ],
            # A user's require-virtualenv setting must not refuse the base.
            env={"PIP_REQUIRE_VIRTUALENV": "false"},
            cwd=str(self.context.state),
            timeout=1800,
        )

    def pyenv(self, operation, version):
        process.run(
            [
                str(self.adapter.manager()),
                *self.context.arguments(operation, version=version),
            ],
            env={"PYENV_ROOT": str(self.adapter.root)},
            cwd=str(self.context.state),
            timeout=600,
        )

    def reselect(self, retirement):
        self.pyenv("pythonDefault", retirement.successor)

    def uninstall(self, retirement):
        self.pyenv("pythonUninstall", retirement.release)
        self.adapter.rehash(cwd=str(self.context.state))


class OcamlRetirer(Retirer):
    """Only a switch bootstrap created, never a switch it adopted."""

    depth = 2

    def paths(self):
        return {None: "ocaml.versions"}

    def prefix(self, release, component):
        return self.adapter.root / self.adapter.seed(release)

    def installed(self, release, component):
        switch = self.adapter.switch(release)
        return (self.adapter.root / switch / "bin/ocamlc").is_file()

    def inspect(self, retirement):
        state = retirement.prefix / ".opam-switch/switch-state"
        try:
            text = state.read_text(errors="replace")[: 1024 * 1024]
        except OSError:
            retirement.blockers.append("it is not a complete opam switch")
            return
        match = SWITCH_ROOTS.search(text)
        roots = re.findall(r'"([^"]+)"', match.group(1)) if match else []
        installed = [root for root in roots if not compiler_package(root)]
        if installed:
            retirement.blockers.append(
                f"packages were installed into it: {described(installed)}; "
                "remove the switch with opam when they are no longer needed"
            )

    def reselect(self, retirement):
        switch = self.adapter.switch(retirement.successor)
        self.adapter.run(*self.context.arguments("opamDefault", switch=switch))

    def uninstall(self, retirement):
        self.adapter.run(
            *self.context.arguments(
                "opamRemove", switch=retirement.prefix.name
            ),
            timeout=600,
        )


def compiler_package(root):
    name = root.split(".", 1)[0]
    return name in COMPILERS or name.startswith(COMPILER_PREFIXES)


def inside(path, prefix):
    if not path:
        return False
    path = Path(path)
    return path.is_absolute() and (
        path.resolve().is_relative_to(prefix.resolve())
        or path.is_relative_to(prefix)
    )


def replace_symlink(link, target):
    temporary = link.with_name(f".{link.name}.dev-bootstrap")
    if os.path.lexists(temporary):
        temporary.unlink()
    temporary.symlink_to(target)
    os.replace(temporary, link)


def rewrite_settings(config, old, new, release, successor):
    """Move pyvenv.cfg's interpreter paths and version to the successor."""
    lines = []
    for line in config.read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator and key.strip() in ("version", "version_info"):
            if value.strip() == release:
                line = f"{key.rstrip()} = {successor}"
        else:
            for before, after in ((old.resolve(), new.resolve()), (old, new)):
                # A whole path component only: 3.14.7 never matches 3.14.70.
                line = re.sub(
                    re.escape(str(before)) + r"(?=/|\s|$)",
                    lambda _, after=after: str(after),
                    line,
                )
        lines.append(line)
    temporary = config.with_name(f".{config.name}.dev-bootstrap")
    temporary.write_text("\n".join(lines) + "\n")
    os.chmod(temporary, config.stat().st_mode & 0o777)
    os.replace(temporary, config)
