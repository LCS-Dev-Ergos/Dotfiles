"""What dev-doctor checks: one ``Runtime`` per manager, language or tool.

Each entry says how to tell the runtime is installed, how to read its active
version, which binary PATH should resolve to it, how to count the versions
its manager keeps and how to check that it starts. Most of that is data; a
runtime whose answer needs more than one command (a symlink to read, a
release to compare) names a function of this module instead.

The registry is code in the store, not a file read at run time: nothing a
check executes can come from a file another program could rewrite. Every
command is an argument tuple; ``~`` at the start of its first word is the
home directory, and nothing else is expanded.
"""

import json
import os
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from . import process
from .compilers import selected
from .host import Host, Platform
from .jsondata import as_object
from .process import Outcome
from .versions import at_least, first_line, token

EMPTY = 65
"""The status of a version probe that printed no version."""


class Group(Enum):
    """A section of the report, in display order."""

    PLATFORM = "platform"
    SYSTEMS = "systems"
    JVM = "jvm"
    SCRIPTING = "scripting"
    FUNCTIONAL = "functional"
    SCIENCE = "science"
    APPS = "apps"
    OTHER = "other"

    @property
    def title(self) -> str:
        """The section title."""
        return {
            Group.PLATFORM: "Platform",
            Group.SYSTEMS: "Systems & C/C++",
            Group.JVM: "JVM",
            Group.SCRIPTING: "Scripting",
            Group.FUNCTIONAL: "Functional, Logic & Array",
            Group.SCIENCE: "Science & Proof",
            Group.APPS: "App Platforms",
            Group.OTHER: "Other",
        }[self]


@dataclass(frozen=True)
class Probe:
    """What a check knows while it runs: the host, the root, the time limit."""

    host: Host
    root: Path | None
    timeout: float

    def run(
        self, *argv: str, errors: bool = False, cwd: Path | None = None
    ) -> Outcome:
        """Run a command with the check's environment and time limit."""
        return process.run(
            argv, self.host.env, self.timeout, errors=errors, cwd=cwd
        )


@dataclass(frozen=True)
class Verdict:
    """A check's own judgement: 0 ok, 1 inconclusive, 2 broken."""

    level: int
    text: str


@dataclass(frozen=True)
class Run:
    """A command; its first word may be a path starting with ``~``."""

    argv: tuple[str, ...]


@dataclass(frozen=True)
class OnPath:
    """Installed when PATH finds this command."""

    name: str


@dataclass(frozen=True)
class InRoot:
    """Installed when this path exists inside the runtime's root."""

    relative: str = ""


type Presence = OnPath | InRoot | Callable[[Probe], bool | Path]
"""How to tell a runtime is installed; a function may name its root."""

type Version = Run | Callable[[Probe], Outcome]
"""How to read the active version."""

type Managed = Run | Callable[[Probe], list[str] | None]
"""How to list the versions a manager keeps."""

STARTS_WITH_VERSION = "version"
"""A startup check that reuses the version probe, which starts the runtime."""


@dataclass(frozen=True)
class Runtime:
    """One row of the report.

    Attributes:
        id: What ``--only`` names it by.
        label: What the report calls it.
        group: Its section.
        presence: How to tell it is installed.
        version: How to read its active version, if it has one.
        binary: The command PATH should resolve to it, if any.
        root_var: The variable that moves its root, if any.
        roots: Its default roots; the variable replaces the first.
        managed: How to list the versions its manager keeps.
        formula: The Homebrew formula an update signal is read from.
        hint: The command that updates it.
        activated: For a manager a shell activates itself, whether this
            shell has; ``None`` for one that is always active.
        startup: How to check it starts: ``STARTS_WITH_VERSION`` or a
            command; ``None`` for no check.
        verdict: A judgement of its own, made once everything else is ok.
        compiler: ``CC`` or ``CXX`` for the compiler rows.
        healthy: The detail of a healthy row, when the default would
            mislead.
        platforms: Where it applies.
    """

    id: str
    label: str
    group: Group
    presence: Presence
    version: Version | None = None
    binary: str | None = None
    root_var: str | None = None
    roots: tuple[str, ...] = ()
    managed: Managed | None = None
    formula: str | None = None
    hint: str | None = None
    activated: Callable[[Host], bool] | None = None
    startup: Run | str | None = STARTS_WITH_VERSION
    verdict: Callable[[Probe], Verdict] | None = None
    compiler: str | None = None
    healthy: str | None = None
    platforms: frozenset[Platform] = field(
        default_factory=lambda: frozenset(Platform)
    )

    def resolve_roots(self, host: Host) -> list[Path]:
        """Every root the runtime owns, the primary one first."""
        roots = [host.expand(root) for root in self.roots]
        moved = host.get(self.root_var) if self.root_var else ""
        if moved:
            roots[:1] = [Path(moved)]
        return roots


def _command(*argv: str) -> Run:
    """A command from its words."""
    return Run(argv)


# Compilers --------------------------------------------------------------------


def _compiler_present(variable: str, fallback: str) -> Callable[[Probe], bool]:
    """Present when the variable is set, even to something broken."""

    def present(probe: Probe) -> bool:
        """Whether a compiler is selected or PATH has the fallback."""
        host = probe.host
        return bool(host.get(variable)) or host.which(fallback) is not None

    return present


def _compiler_version(variable: str) -> Callable[[Probe], Outcome]:
    """Start the selected compiler with ``--version``."""

    def version(probe: Probe) -> Outcome:
        """The banner of the compiler the variable selects."""
        return probe.run(*selected(probe.host, variable), "--version")

    return version


# Platform ---------------------------------------------------------------------


def _nix_verdict(probe: Probe) -> Verdict:
    """Compare the ``nix`` on PATH, its daemon and the locked release.

    Home Manager writes the release the configuration's locked nixpkgs
    carries to ``$XDG_CONFIG_HOME/dev-doctor/nix-release``. A client older
    than the daemon is an installer's copy PATH still prefers; a daemon
    older than the lock missed the update that moves it.
    """
    client = probe.run("nix", "--version")
    if not client.ok:
        return Verdict(1, "nix --version failed")
    current = token(client.output)
    store = process.run(
        ("nix", "--extra-experimental-features", "nix-command")
        + ("store", "info", "--json"),
        {**probe.host.env, "NIX_REMOTE": "daemon"},
        probe.timeout,
    )
    daemon = _json_version(store.output) if store.ok else ""
    if not daemon:
        return Verdict(
            1, f"Client {current}; the daemon cannot be asked for its release"
        )
    release = probe.host.config_home() / "dev-doctor" / "nix-release"
    try:
        locked = release.read_text(encoding="utf-8").strip()
    except OSError:
        locked = ""
    if locked and not at_least(daemon, locked):
        if probe.host.platform is Platform.MACOS:
            fix = "switch the nix-darwin configuration"
        else:
            fix = (
                "run scripts/bootstrap/dev-bootstrap.sh --update-nix in the "
                "Dotfiles checkout"
            )
        return Verdict(
            2, f"Daemon {daemon} is older than the locked {locked}; {fix}"
        )
    if not at_least(current, daemon):
        where = probe.host.which("nix")
        return Verdict(
            2,
            f"nix on PATH ({where}) is {current}, the daemon {daemon}; "
            "remove the stale copy ahead on PATH",
        )
    lock = f", locked {locked}" if locked else ""
    return Verdict(0, f"Client {current}, daemon {daemon}{lock}")


def _json_version(text: str) -> str:
    """The ``version`` field of a JSON object, or an empty string."""
    try:
        data: object = json.loads(text)
    except ValueError:
        return ""
    value = (as_object(data) or {}).get("version")
    if isinstance(value, str) and value[:1].isdigit():
        return value
    return ""


def _toolchain_verdict(probe: Probe) -> Verdict:
    """Ask the Nix C/C++ toolchain check whether it still holds here.

    An Xcode, Command Line Tools or macOS update changes the SDK, linker or
    system without rebuilding anything, so the verification the last
    system build made can go stale unnoticed; this row is where it shows.
    """
    outcome = probe.run("cc-toolchain-check", "--status", errors=True)
    line = first_line(outcome.output)
    if outcome.ok:
        return Verdict(0, line)
    if outcome.timed_out:
        return Verdict(1, "Status probe timed out")
    if outcome.status == 1:
        return Verdict(1, line)
    return Verdict(2, line or f"Status probe failed (exit {outcome.status})")


# JVM --------------------------------------------------------------------------


def _sdkman_candidate(name: str) -> Callable[[Probe], Outcome]:
    """Read an SDKMAN candidate's selection from its ``current`` link.

    Running ``gradle --version`` would start a JVM and initialize
    ``~/.gradle``; the link already names the version.
    """

    def version(probe: Probe) -> Outcome:
        """The version the ``current`` link of the candidate points at."""
        if probe.root is None:
            return Outcome(1, "")
        current = probe.root / "candidates" / name / "current"
        if not current.exists():
            return Outcome(1, "")
        return Outcome(0, Path(os.path.realpath(current)).name)

    return version


def _sdkman_managed(probe: Probe) -> list[str] | None:
    """The SDKMAN candidates that have a current selection."""
    if probe.root is None:
        return None
    candidates = probe.root / "candidates"
    try:
        entries = sorted(candidates.iterdir())
    except OSError:
        return []
    return [entry.name for entry in entries if (entry / "current").exists()]


def _coursier_present(probe: Probe) -> bool | Path:
    """Coursier's launcher and its platform-specific data root."""
    host = probe.host
    if host.which("cs") is None and host.which("coursier") is None:
        return False
    if host.platform is Platform.MACOS:
        return host.home / "Library" / "Application Support" / "Coursier"
    return host.home / ".local" / "share" / "coursier"


def _coursier_version(probe: Probe) -> Outcome:
    """The Coursier launcher's own version."""
    launcher = "cs" if probe.host.which("cs") else "coursier"
    return probe.run(launcher, "version")


# Scripting --------------------------------------------------------------------


def _fnm_activated(host: Host) -> bool:
    """Whether this shell applied ``fnm env``.

    fnm's lazy initializer runs on the first fnm call, so a fresh shell
    serves Node from the Nix fallback by design.
    """
    multishell = host.get("FNM_MULTISHELL_PATH")
    return bool(multishell) and (Path(multishell) / "bin").is_dir()


def _fnm_version(probe: Probe) -> Outcome:
    """The Node version fnm serves, or its default alias when inactive.

    ``fnm current`` fails until ``fnm env`` has been applied. The alias
    points at ``<root>/node-versions/<version>/installation``, so the
    version is the parent of the resolved leaf.
    """
    if _fnm_activated(probe.host):
        current = probe.run("fnm", "current")
        if current.ok:
            return current
    root = probe.root or probe.host.expand("~/.local/share/fnm")
    alias = root / "aliases" / "default"
    if not alias.exists():
        return Outcome(1, "")
    resolved = Path(os.path.realpath(alias))
    if resolved.name == "installation":
        resolved = resolved.parent
    return Outcome(0, resolved.name)


_CONDA_ROOTS = ("~/.miniforge3", "/opt/miniconda3")


def _conda_present(probe: Probe) -> bool | Path:
    """Conda at the roots the shell setup knows, without its shell hook."""
    for candidate in _CONDA_ROOTS:
        root = probe.host.expand(candidate)
        conda = root / "bin" / "conda"
        if conda.is_file() and os.access(conda, os.X_OK):
            return root
    return False


def _conda_version(probe: Probe) -> Outcome:
    """The conda release, from its own binary."""
    if probe.root is None:
        return Outcome(1, "")
    return probe.run(str(probe.root / "bin" / "conda"), "--version")


def _conda_managed(probe: Probe) -> list[str] | None:
    """Conda's environments, listed without initializing its shell hook."""
    if probe.root is None:
        return None
    listing = probe.run(str(probe.root / "bin" / "conda"), "env", "list")
    if not listing.ok:
        return None
    lines = (line.strip() for line in listing.output.splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def _conda_activated(host: Host) -> bool:
    """Whether a conda environment is active in this shell."""
    return bool(host.get("CONDA_PREFIX") or host.get("CONDA_DEFAULT_ENV"))


# Science ----------------------------------------------------------------------


def _lean_version(probe: Probe) -> Outcome:
    """The Lean release elan selects outside any project.

    elan installs the toolchain a ``lean-toolchain`` file names the moment
    ``lean`` runs below it, so the probe runs from the home directory: a
    report must never download.
    """
    lean = probe.host.which("lean")
    if lean is None:
        return Outcome(process.NOT_RUNNABLE, "")
    return probe.run(str(lean), "--version", cwd=probe.host.home)


# Apps -------------------------------------------------------------------------


_FLUTTER_VERSION = re.compile(r'"flutterVersion"\s*:\s*"([^"]*)"')


def _flutter_version(probe: Probe) -> Outcome:
    """Flutter's cached version, after its bundled Dart VM starts.

    The ``flutter`` launcher can download artifacts even for ``--version``,
    so it never runs; the SDK it belongs to is read instead.
    """
    launcher = probe.host.which("flutter")
    if launcher is None:
        return Outcome(process.NOT_RUNNABLE, "")
    sdk = Path(os.path.realpath(launcher)).parent.parent
    try:
        metadata = (sdk / "bin" / "cache" / "flutter.version.json").read_text(
            encoding="utf-8"
        )
    except OSError:
        return Outcome(EMPTY, "")
    dart = sdk / "bin" / "cache" / "dart-sdk" / "bin" / "dart"
    started = probe.run(str(dart), "--version")
    if not started.ok:
        return Outcome(started.status, "")
    found = _FLUTTER_VERSION.search(metadata)
    return Outcome(0, found[1] if found else "")


# Registry ---------------------------------------------------------------------

_MACOS = frozenset({Platform.MACOS})
_LINUX = frozenset({Platform.LINUX})
_SDKMAN = ("~/.sdkman",)

RUNTIMES: tuple[Runtime, ...] = (
    Runtime(
        "brew",
        "Homebrew",
        Group.PLATFORM,
        OnPath("brew"),
        _command("brew", "--version"),
        root_var="HOMEBREW_PREFIX",
        hint="brew upgrade",
        startup=None,
    ),
    Runtime(
        "nix",
        "Nix",
        Group.PLATFORM,
        OnPath("nix"),
        _command("nix", "--version"),
        hint="nix flake update",
        startup=None,
        verdict=_nix_verdict,
    ),
    Runtime(
        "alire",
        "Ada",
        Group.SYSTEMS,
        OnPath("alr"),
        _command("alr", "--version"),
        root_var="ALR_HOME",
        roots=("~/.ada",),
        hint="alr toolchain --select",
        startup=None,
    ),
    Runtime(
        "cc",
        "C (CC)",
        Group.SYSTEMS,
        _compiler_present("CC", "cc"),
        _compiler_version("CC"),
        binary="cc",
        compiler="CC",
    ),
    Runtime(
        "cxx",
        "C++ (CXX)",
        Group.SYSTEMS,
        _compiler_present("CXX", "c++"),
        _compiler_version("CXX"),
        binary="c++",
        compiler="CXX",
    ),
    Runtime(
        "ccache",
        "ccache",
        Group.SYSTEMS,
        OnPath("ccache"),
        _command("ccache", "--version"),
        binary="ccache",
    ),
    Runtime(
        "clang",
        "Clang",
        Group.SYSTEMS,
        OnPath("clang"),
        _command("clang", "--version"),
        binary="clang",
    ),
    Runtime(
        "cmake",
        "CMake",
        Group.SYSTEMS,
        OnPath("cmake"),
        _command("cmake", "--version"),
        binary="cmake",
    ),
    Runtime(
        "fortran",
        "Fortran",
        Group.SYSTEMS,
        OnPath("gfortran"),
        _command("gfortran", "--version"),
        binary="gfortran",
        formula="gcc",
        hint="brew upgrade gcc",
    ),
    Runtime(
        "fpcupdeluxe",
        "Free Pascal",
        Group.SYSTEMS,
        InRoot(),
        _command("fpc", "-iV"),
        binary="fpc",
        roots=("~/.fpc-deluxe",),
        platforms=_MACOS,
    ),
    Runtime(
        "fpc",
        "Free Pascal",
        Group.SYSTEMS,
        OnPath("fpc"),
        _command("fpc", "-iV"),
        binary="fpc",
        platforms=_LINUX,
    ),
    Runtime(
        "gcc",
        "GCC driver",
        Group.SYSTEMS,
        OnPath("gcc"),
        _command("gcc", "--version"),
        binary="gcc",
    ),
    Runtime(
        "go",
        "Go",
        Group.SYSTEMS,
        OnPath("go"),
        _command("go", "version"),
        binary="go",
    ),
    Runtime(
        "mojo",
        "Mojo",
        Group.SYSTEMS,
        InRoot("bin/mojo"),
        _command("~/.miniforge3/envs/Mojo/bin/mojo", "--version"),
        roots=("~/.miniforge3/envs/Mojo",),
        hint="conda env update -n Mojo -f "
        "home/dev/languages/mojo/environment.yml",
        platforms=_MACOS,
    ),
    Runtime(
        "rustup",
        "Rust",
        Group.SYSTEMS,
        OnPath("rustup"),
        _command("rustc", "--version"),
        binary="rustc",
        root_var="RUSTUP_HOME",
        roots=("~/.rustup", "~/.cargo"),
        managed=_command("rustup", "toolchain", "list"),
        hint="rustup update",
    ),
    Runtime(
        "cctoolchain",
        "Toolchain check",
        Group.SYSTEMS,
        OnPath("cc-toolchain-check"),
        startup=None,
        verdict=_toolchain_verdict,
        platforms=_MACOS,
    ),
    Runtime(
        "zig",
        "Zig",
        Group.SYSTEMS,
        OnPath("zig"),
        _command("zig", "version"),
        binary="zig",
    ),
    Runtime(
        "sdkman",
        "Java",
        Group.JVM,
        InRoot("bin/sdkman-init.sh"),
        _sdkman_candidate("java"),
        binary="java",
        root_var="SDKMAN_DIR",
        roots=_SDKMAN,
        managed=_sdkman_managed,
        hint="sdk upgrade",
        startup=_command("java", "--version"),
    ),
    Runtime(
        "kotlin",
        "Kotlin",
        Group.JVM,
        OnPath("kotlin"),
        _command("kotlin", "-version"),
        binary="kotlin",
        root_var="SDKMAN_DIR",
        roots=_SDKMAN,
        hint="sdk upgrade kotlin",
    ),
    Runtime(
        "maven",
        "Maven",
        Group.JVM,
        OnPath("mvn"),
        _command("mvn", "--version"),
        binary="mvn",
        root_var="SDKMAN_DIR",
        roots=_SDKMAN,
        hint="sdk upgrade maven",
    ),
    Runtime(
        "gradle",
        "Gradle",
        Group.JVM,
        OnPath("gradle"),
        _sdkman_candidate("gradle"),
        binary="gradle",
        root_var="SDKMAN_DIR",
        roots=_SDKMAN,
        hint="sdk upgrade gradle",
        startup=None,
    ),
    Runtime(
        "coursier",
        "Scala",
        Group.JVM,
        _coursier_present,
        _coursier_version,
        binary="scala",
        hint="cs update",
        startup=_command("scala", "version", "--offline", "--scala-version"),
    ),
    Runtime(
        "bun",
        "Bun",
        Group.SCRIPTING,
        OnPath("bun"),
        _command("bun", "--version"),
        binary="bun",
    ),
    Runtime(
        "conda",
        "Conda",
        Group.SCRIPTING,
        _conda_present,
        _conda_version,
        managed=_conda_managed,
        hint="conda update -n base conda",
        activated=_conda_activated,
        startup=None,
    ),
    Runtime(
        "lua",
        "Lua",
        Group.SCRIPTING,
        OnPath("lua"),
        _command("lua", "-v"),
        binary="lua",
    ),
    Runtime(
        "fnm",
        "Node",
        Group.SCRIPTING,
        OnPath("fnm"),
        _fnm_version,
        binary="node",
        root_var="FNM_DIR",
        roots=("~/.local/share/fnm",),
        managed=_command("fnm", "list"),
        hint="fnm install --lts",
        activated=_fnm_activated,
        startup=_command("node", "--version"),
    ),
    Runtime(
        "perl",
        "Perl",
        Group.SCRIPTING,
        OnPath("perl"),
        _command("perl", "-e", 'print "$^V\\n"'),
        binary="perl",
        formula="perl",
        hint="brew upgrade perl",
    ),
    Runtime(
        "php",
        "PHP",
        Group.SCRIPTING,
        OnPath("php"),
        _command("php", "--version"),
        binary="php",
    ),
    Runtime(
        "pyenv",
        "Python",
        Group.SCRIPTING,
        OnPath("pyenv"),
        _command("pyenv", "version-name"),
        binary="python3",
        root_var="PYENV_ROOT",
        roots=("~/.pyenv",),
        managed=_command("pyenv", "versions", "--bare"),
        hint="pyenv install -l",
        startup=_command("python3", "--version"),
    ),
    Runtime(
        "rbenv",
        "Ruby",
        Group.SCRIPTING,
        OnPath("rbenv"),
        _command("rbenv", "version-name"),
        binary="ruby",
        root_var="RBENV_ROOT",
        roots=("~/.rbenv",),
        managed=_command("rbenv", "versions", "--bare"),
        hint="rbenv install -l",
        startup=_command("ruby", "--version"),
    ),
    Runtime(
        "bqn",
        "BQN",
        Group.FUNCTIONAL,
        OnPath("bqn"),
        _command("bqn", "--version"),
        binary="bqn",
    ),
    Runtime(
        "sbcl",
        "Common Lisp",
        Group.FUNCTIONAL,
        OnPath("sbcl"),
        _command("sbcl", "--version"),
        binary="sbcl",
    ),
    Runtime(
        "elixir",
        "Elixir",
        Group.FUNCTIONAL,
        OnPath("elixir"),
        _command("elixir", "--short-version"),
        binary="elixir",
    ),
    Runtime(
        "erlang",
        "Erlang",
        Group.FUNCTIONAL,
        OnPath("erl"),
        _command(
            "erl",
            "-noshell",
            "-eval",
            'io:format("~s~n", [erlang:system_info(otp_release)]), halt().',
        ),
        binary="erl",
    ),
    Runtime(
        "gleam",
        "Gleam",
        Group.FUNCTIONAL,
        OnPath("gleam"),
        _command("gleam", "--version"),
        binary="gleam",
    ),
    Runtime(
        "ghcup",
        "Haskell",
        Group.FUNCTIONAL,
        OnPath("ghcup"),
        _command("ghc", "--numeric-version"),
        binary="ghc",
        roots=("~/.ghcup",),
        managed=_command(
            "ghcup", "list", "-t", "ghc", "-c", "installed", "-r"
        ),
        hint="ghcup upgrade",
    ),
    Runtime(
        "koka",
        "Koka",
        Group.FUNCTIONAL,
        OnPath("koka"),
        _command("koka", "--version"),
        binary="koka",
    ),
    Runtime(
        "scheme",
        "MIT Scheme",
        Group.FUNCTIONAL,
        OnPath("mit-scheme"),
        _command("mit-scheme", "--version"),
        binary="mit-scheme",
        formula="mit-scheme",
        hint="brew upgrade mit-scheme",
    ),
    Runtime(
        "opam",
        "OCaml",
        Group.FUNCTIONAL,
        OnPath("opam"),
        _command("ocaml", "-version"),
        binary="ocaml",
        root_var="OPAMROOT",
        roots=("~/.opam",),
        managed=_command("opam", "switch", "list", "-s"),
        hint="opam update",
    ),
    Runtime(
        "prolog",
        "Prolog",
        Group.FUNCTIONAL,
        OnPath("swipl"),
        _command("swipl", "--version"),
        binary="swipl",
    ),
    Runtime(
        "racket",
        "Racket",
        Group.FUNCTIONAL,
        OnPath("racket"),
        _command("racket", "--version"),
        binary="racket",
        formula="racket",
        hint="brew upgrade racket",
    ),
    Runtime(
        "unison",
        "Unison",
        Group.FUNCTIONAL,
        OnPath("ucm"),
        _command("ucm", "--version"),
        binary="ucm",
    ),
    Runtime(
        "juliaup",
        "Julia",
        Group.SCIENCE,
        OnPath("juliaup"),
        _command("julia", "--version"),
        binary="julia",
        roots=("~/.juliaup",),
        hint="juliaup update",
    ),
    Runtime(
        "elan",
        "Lean",
        Group.SCIENCE,
        OnPath("elan"),
        _lean_version,
        binary="lean",
        root_var="ELAN_HOME",
        roots=("~/.elan",),
        managed=_command("elan", "toolchain", "list"),
        hint="elan update",
    ),
    Runtime(
        "dotnet",
        ".NET SDK",
        Group.APPS,
        OnPath("dotnet"),
        _command("dotnet", "--version"),
        binary="dotnet",
    ),
    Runtime(
        "android",
        "Android adb",
        Group.APPS,
        OnPath("adb"),
        _command("adb", "version"),
        binary="adb",
    ),
    Runtime(
        "flutter",
        "Flutter SDK",
        Group.APPS,
        OnPath("flutter"),
        _flutter_version,
        binary="flutter",
        hint="flutter upgrade",
        healthy="Cached Flutter version; bundled Dart starts",
    ),
    Runtime(
        "swift",
        "Swift",
        Group.APPS,
        OnPath("swift"),
        _command("swift", "--version"),
        binary="swift",
        platforms=_MACOS,
    ),
)
"""Every runtime, in no particular order; the report sorts them."""


def applicable(platform: Platform) -> list[Runtime]:
    """The runtimes that apply on ``platform``."""
    return [runtime for runtime in RUNTIMES if platform in runtime.platforms]
