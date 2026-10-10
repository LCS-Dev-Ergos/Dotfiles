"""Toolchains: removal through each manager, or of a directory none tracks."""

import shutil
import tomllib

from .. import process
from ..adapters.coursier import EXEC, LAUNCHERS
from ..adapters.rust import HOSTS
from ..errors import BootstrapError
from .base import Retirer, Step
from .inventory import ruby_gems, rust_components
from .runtimes import described, inside

TIMEOUT = 600


class ToolchainRetirer(Retirer):
    """One declared release at nativeToolchains.<language>.version."""

    key = "version"

    def paths(self):
        return {None: f"nativeToolchains.{self.adapter.language}.{self.key}"}

    def invoke(self, *arguments):
        return self.adapter.invoke(*arguments, timeout=TIMEOUT)

    def reselect(self, retirement):
        self.invoke(*self.adapter.default_arguments())


class SettingsRetirer(ToolchainRetirer):
    """rustup and elan record directory overrides in settings.toml."""

    def toolchain(self, release):
        raise NotImplementedError

    def overrides(self, *toolchains):
        """Directories whose override names one of the toolchains."""
        path = self.adapter.root / "settings.toml"
        if not path.is_file():
            return []
        try:
            settings = tomllib.loads(path.read_text())
        except (OSError, tomllib.TOMLDecodeError) as error:
            # Unreadable overrides could name the release: keep it.
            raise BootstrapError(f"Cannot read {path}: {error}") from error
        return sorted(
            directory
            for directory, toolchain in settings.get("overrides", {}).items()
            if toolchain in toolchains
        )

    def inspect(self, retirement):
        release = retirement.release
        try:
            directories = self.overrides(release, self.toolchain(release))
        except BootstrapError as error:
            retirement.blockers.append(str(error))
            return
        for directory in directories:
            retirement.blockers.append(
                f"the directory override for {directory} selects it"
            )

    def uninstall(self, retirement):
        self.invoke(
            "toolchain", "uninstall", self.toolchain(retirement.release)
        )


class RustRetirer(SettingsRetirer):
    def toolchain(self, release):
        return f"{release}-{HOSTS[self.context.data['platform']]}"

    def prefix(self, release, component):
        return self.adapter.root / "toolchains" / self.toolchain(release)

    def inspect(self, retirement):
        super().inspect(retirement)
        successor = retirement.successor
        target = self.prefix(successor, None)
        missing = rust_components(retirement.prefix) - rust_components(target)
        if not missing or retirement.blockers:
            return
        if not target.is_dir():
            retirement.blockers.append(
                f"its components need {successor} installed; apply first"
            )
            return
        host = HOSTS[self.context.data["platform"]]
        components, targets = [], []
        for name in sorted(missing):
            if name.startswith("rust-std-"):
                targets.append(name.removeprefix("rust-std-"))
            else:
                components.append(name.removesuffix(f"-{host}"))
        retirement.steps.append(
            Step(
                f"add to {successor}: {described(components + targets)}",
                lambda: self.add(successor, components, targets),
            )
        )

    def add(self, successor, components, targets):
        toolchain = self.toolchain(successor)
        if components:
            self.invoke(
                "component", "add", "--toolchain", toolchain, *components
            )
        if targets:
            self.invoke("target", "add", "--toolchain", toolchain, *targets)


class LeanRetirer(SettingsRetirer):
    def toolchain(self, release):
        return f"leanprover/lean4:v{release}"

    def prefix(self, release, component):
        return self.adapter.binary(self.toolchain(release)).parent.parent

    def inspect(self, retirement):
        super().inspect(retirement)
        retirement.notes.append(
            "a project whose lean-toolchain names it installs it again on use"
        )


class RubyRetirer(ToolchainRetirer):
    def prefix(self, release, component):
        return self.adapter.root / "versions" / release

    def inspect(self, retirement):
        successor = retirement.successor
        target = self.prefix(successor, None)
        present = ruby_gems(target, default=True)
        missing = {
            name: version
            for name, version in ruby_gems(retirement.prefix).items()
            if name not in present
        }
        if not missing:
            return
        if not target.is_dir():
            retirement.blockers.append(
                f"its gems need {successor} installed; apply first"
            )
            return
        retirement.steps.append(
            Step(
                f"install gems into {successor}: {described(missing)}",
                lambda: self.install_gems(target, missing),
            )
        )

    def install_gems(self, target, gems):
        # gem's shebang names its own interpreter; native extensions build
        # with the same environment the Ruby build used.
        process.run(
            [
                str(target / "bin/gem"),
                "install",
                "--no-document",
                *(f"{name}:{version}" for name, version in gems.items()),
            ],
            env=self.adapter.recipe.get("buildEnvironment", {})
            | self.adapter.environment(),
            source_build=True,
            cwd=str(self.context.state),
            timeout=3600,
        )

    def uninstall(self, retirement):
        self.invoke("uninstall", "-f", retirement.release)
        self.invoke("rehash")


class HaskellRetirer(ToolchainRetirer):
    def paths(self):
        base = "nativeToolchains.haskell"
        return {
            "ghc": f"{base}.version",
            "cabal": f"{base}.cabal",
            "hls": f"{base}.hls",
        }

    def prefix(self, release, component):
        if component == "cabal":
            return self.adapter.root / "bin" / f"cabal-{release}"
        return self.adapter.root / component / release

    def inspect(self, retirement):
        if retirement.component == "ghc":
            retirement.notes.append(
                "Cabal's package store for this compiler stays in place"
            )

    def reselect(self, retirement):
        self.invoke("set", retirement.component, retirement.successor)

    def uninstall(self, retirement):
        self.invoke("rm", retirement.component, retirement.release)


class SdkmanRetirer(ToolchainRetirer):
    @property
    def key(self):
        # Java's directories carry SDKMAN's identifier, not the identity.
        return "candidate" if self.adapter.language == "jvm" else "version"

    def prefix(self, release, component):
        return self.adapter.root / self.adapter.runtime_directory / release

    def uninstall(self, retirement):
        self.invoke("uninstall", self.adapter.candidate, retirement.release)


class JuliaRetirer(ToolchainRetirer):
    """juliaup removes a release with the last channel that names it."""

    def entry(self, release):
        installed = self.adapter.config().get("InstalledVersions", {})
        for identity, entry in installed.items():
            if identity.split("+", 1)[0] == release:
                return identity, entry
        return None, {}

    def prefix(self, release, component):
        _, entry = self.entry(release)
        path = entry.get("Path")
        return self.adapter.root / "juliaup" / path if path else None

    def channels(self, release):
        identity, _ = self.entry(release)
        channels = self.adapter.config().get("InstalledChannels", {})
        return sorted(
            name
            for name, channel in channels.items()
            if identity and channel.get("Version") == identity
        )

    def inspect(self, retirement):
        channels = self.channels(retirement.release)
        if not channels:
            retirement.blockers.append(
                "no juliaup channel names it; `juliaup gc` removes it"
            )
        for channel in channels:
            if channel != retirement.release:
                retirement.blockers.append(
                    f"the juliaup channel {channel} follows it; "
                    f"`juliaup update` moves it, or `juliaup remove {channel}`"
                )

    def uninstall(self, retirement):
        for channel in self.channels(retirement.release):
            self.invoke("remove", channel)


class DirectoryRetirer(ToolchainRetirer):
    """No uninstall command: the release is one directory in the root."""

    def uninstall(self, retirement):
        prefix = retirement.prefix
        if prefix.is_symlink() or not prefix.is_dir():
            raise BootstrapError(f"{prefix} is not a directory")
        shutil.rmtree(prefix)


class ScalaRetirer(DirectoryRetirer):
    """A distribution in Coursier's archive cache, run by launchers."""

    def prefix(self, release, component):
        return self.adapter.distributions() / release

    def launchers(self, retirement):
        """Launchers in Coursier's bin directory that run the release."""
        home = self.adapter.home
        if not home.is_dir():
            return []
        found = []
        for launcher in sorted(home.iterdir()):
            if launcher.is_symlink() or not launcher.is_file():
                continue
            with launcher.open("rb") as file:
                match = EXEC.search(file.read(4096))
            if match and inside(match.group(1).decode(), retirement.prefix):
                found.append(launcher.name)
        return found

    def selects(self, retirement):
        # scala and scalac are the selection; either one still counts.
        return any(name in LAUNCHERS for name in self.launchers(retirement))

    def inspect(self, retirement):
        for name in self.launchers(retirement):
            if name not in LAUNCHERS:
                retirement.blockers.append(
                    f"the Coursier launcher {name} runs it"
                )

    def reselect(self, retirement):
        self.invoke(
            "install",
            "--install-dir",
            str(self.adapter.home),
            *(f"{name}:{retirement.successor}" for name in LAUNCHERS),
        )


class DotnetRetirer(DirectoryRetirer):
    def prefix(self, release, component):
        return self.adapter.root / "sdk" / release

    def inspect(self, retirement):
        retirement.notes.append(
            "the runtimes it brought under shared/ stay, and a global.json "
            "that requires exactly this SDK stops resolving"
        )
