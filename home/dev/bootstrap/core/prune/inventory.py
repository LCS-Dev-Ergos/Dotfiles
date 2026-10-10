"""What lives inside an installed release, read from the filesystem only."""

import json
import os
import re
from pathlib import Path

# Packages a runtime ships itself; the successor has its own copy.
NODE_BUNDLED = frozenset({"npm", "corepack"})
PYTHON_BUNDLED = frozenset({"pip"})
# name-version[-platform].gemspec; a name never has a hyphen before a digit.
GEMSPEC = re.compile(
    r"(?P<name>.+?)-(?P<version>[0-9][0-9A-Za-z.]*)(?:-[^/]+)?\.gemspec"
)
PACKAGE_NAME = re.compile(r"(?:@[a-z0-9][\w.-]*/)?[a-z0-9][\w.-]*")
DISTRIBUTION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# Where tools keep the virtual environments they create. A project's own
# environment can live anywhere and is not found here.
VENV_HOMES = (
    ("UV_TOOL_DIR", "{data}/uv/tools", "*"),
    ("PIPX_HOME", "{data}/pipx", "venvs/*"),
    (None, "{home}/.local/pipx", "venvs/*"),
    (None, "{home}/Library/Application Support/pipx", "venvs/*"),
    (None, "{data}/nvim/mason/packages", "*/venv"),
    ("WORKON_HOME", "{home}/.virtualenvs", "*"),
    (None, "{home}", ".venv"),
    (None, "{home}/.venv", "*"),
)


def node_globals(installation):
    """Global npm packages by name; linked ones map to None."""
    modules = installation / "lib/node_modules"
    if not modules.is_dir():
        return {}
    packages = {}
    for entry in sorted(modules.iterdir()):
        if entry.name.startswith("@") and not entry.is_symlink():
            entries = sorted(entry.iterdir()) if entry.is_dir() else []
        else:
            entries = [entry]
        for package in entries:
            name = package.relative_to(modules).as_posix()
            if name in NODE_BUNDLED or not PACKAGE_NAME.fullmatch(name):
                continue
            if package.is_symlink():
                packages[name] = None
                continue
            try:
                version = json.loads((package / "package.json").read_text())[
                    "version"
                ]
            except (OSError, ValueError, KeyError, TypeError):
                continue
            packages[name] = version if isinstance(version, str) else None
    return packages


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def python_distributions(prefix):
    """Distributions installed into an interpreter, by normalized name."""
    found = {}
    for site in sorted(prefix.glob("lib/python3*/site-packages")):
        for info in site.glob("*.dist-info"):
            name, _, version = info.name.removesuffix(".dist-info").partition(
                "-"
            )
            if DISTRIBUTION.fullmatch(name) and version:
                found[normalize(name)] = version
    return {
        name: version
        for name, version in found.items()
        if name not in PYTHON_BUNDLED
    }


def ruby_gems(prefix, *, default=False):
    """Installed gems by name: user-installed ones, or every one."""
    gems = {}
    for directory in sorted(prefix.glob("lib/ruby/gems/*/specifications")):
        places = [directory, directory / "default"] if default else [directory]
        for place in places:
            for spec in place.glob("*.gemspec"):
                match = GEMSPEC.fullmatch(spec.name)
                if match:
                    gems[match["name"]] = match["version"]
    return gems


def rust_components(toolchain):
    """The components rustup recorded for an installed toolchain."""
    record = toolchain / "lib/rustlib/components"
    try:
        lines = record.read_text().splitlines()
    except OSError:
        return set()
    return {line.strip() for line in lines if line.strip()}


def virtual_environments(environment=None):
    """Environments below the known tool locations: (path, settings)."""
    environment = os.environ if environment is None else environment
    home = Path.home()
    data = environment.get("XDG_DATA_HOME") or str(home / ".local/share")
    seen = set()
    for variable, default, pattern in VENV_HOMES:
        base = Path(
            (environment.get(variable) if variable else None)
            or default.format(home=home, data=data)
        )
        if not base.is_dir():
            continue
        for candidate in sorted(base.glob(pattern)):
            config = candidate / "pyvenv.cfg"
            key = candidate.resolve()
            if key in seen or not config.is_file():
                continue
            seen.add(key)
            yield candidate, read_settings(config)


def read_settings(config):
    settings = {}
    for line in config.read_text(errors="replace").splitlines()[:64]:
        key, separator, value = line.partition("=")
        if separator:
            settings[key.strip()] = value.strip()
    return settings
