"""Process execution, owned paths and operational failures shared by adapters."""

import os
import json
import re
import shutil
import stat
import subprocess
from pathlib import Path


class BootstrapError(Exception):
    """An expected bootstrap prerequisite, identity or installation failure."""


# pyenv and rbenv record `system` as a global selection, and fnm links its
# default alias to this placeholder. The host PATH then decides which runtime
# runs, so health reports these selections as external instead of executing
# whatever happens to be found.
SYSTEM_SELECTION = "system"
FNM_SYSTEM_TARGET = "/dev/null/installation"


def external_selection(row):
    row.update(
        state="external",
        path="",
        reason="Global selection delegates to the host system runtime",
    )
    return row


# Source builds inherit account/temporary paths and network transport settings.
# Compiler, SDK and package-discovery inputs must come from the declaration.
BUILD_ENVIRONMENT = frozenset(
    [
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "TMP",
        "TEMP",
        "PATH",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "CURL_CA_BUNDLE",
    ]
)


def run(
    args,
    *,
    env=None,
    timeout=30,
    cwd=None,
    success_codes=(0,),
    source_build=False,
):
    """Execute literal arguments noninteractively; keep diagnostics on stderr."""
    clean = {
        key: value
        for key, value in os.environ.items()
        if not source_build or key in BUILD_ENVIRONMENT
    }
    # python-build accepts prefix, install and checksum-cache overrides from
    # the environment. Recovery owns those inputs, not the invoking project.
    overrides = [
        "PYTHON_PREFIX_PATH",
        "PYTHON_CONFIGURE_OPTS",
        "CONFIGURE_OPTS",
        "MAKE_INSTALL_OPTS",
        "MAKE_OPTS",
        "MAKEOPTS",
        "MAKEFLAGS",
        "MAKEOVERRIDES",
        "MAKE",
        "NODE_OPTIONS",
        "PYTHONPATH",
        "PYTHONHOME",
        "PYENV_VERSION",
        "FNM_MULTISHELL_PATH",
        "FNM_COREPACK_ENABLED",
        "OCAMLLIB",
        "OCAML_TOPLEVEL_PATH",
        "CAML_LD_LIBRARY_PATH",
        "BASH_ENV",
        "ENV",
        "RUSTUP_TOOLCHAIN",
        "ELAN_TOOLCHAIN",
        "RBENV_VERSION",
        "RUBYOPT",
        "RUBYLIB",
        "JAVA_HOME",
        "JAVA_TOOL_OPTIONS",
        "JDK_JAVA_OPTIONS",
        "_JAVA_OPTIONS",
        "JULIAUP_CHANNEL",
        "JULIA_PROJECT",
        "JULIA_LOAD_PATH",
    ]
    prefixes = (
        "OPAM",
        "PYTHON_BUILD_",
        "PYTHON_MAKE_",
        "HAS_CHECKSUM_SUPPORT_",
        "BASH_FUNC_",
    )
    clean = {
        key: value
        for key, value in clean.items()
        if key not in overrides and not key.startswith(prefixes)
    }
    clean.update({"LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"})
    clean.update(env or {})
    try:
        result = subprocess.run(
            args,
            env=clean,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BootstrapError(str(error)) from error
    if result.returncode not in success_codes:
        raise BootstrapError(
            f"{args[0]} exited {result.returncode}: {result.stderr[-2000:]}"
        )
    return result.stdout.strip()


def root_path(key, default, *, from_environment=True):
    """Keep writable roots outside the checkout and immutable store."""
    raw = (os.environ.get(key) if from_environment else None) or str(default)
    path = Path(raw)
    if not path.is_absolute():
        raise BootstrapError(f"{key} must be absolute")
    resolved = path.resolve()
    repositories = [
        parent
        for parent in (resolved, *resolved.parents)
        if (parent / ".git").exists()
    ]
    # The canonical Git-installed pyenv stores its ignored versions beneath
    # its own checkout. Allow that manager root, never an enclosing project.
    pyenv_checkout = False
    if key == "PYENV_ROOT" and repositories == [resolved]:
        config = resolved / ".git/config"
        if config.is_file() and (resolved / "bin/pyenv").is_file():
            pyenv_checkout = bool(
                re.search(
                    r"url\s*=\s*(?:https://github.com/pyenv/pyenv(?:\.git)?|git@github.com:pyenv/pyenv\.git)\s*$",
                    config.read_text(),
                    re.MULTILINE,
                )
            )
    if resolved.is_relative_to(Path("/nix/store")) or (
        repositories and not pyenv_checkout
    ):
        raise BootstrapError(
            f"{key} must stay outside the checkout and Nix store"
        )
    if resolved == Path("/") or resolved == Path.home().resolve():
        raise BootstrapError(f"{key} cannot be the filesystem or home root")
    return resolved


def writable_directory(path, *, create=True):
    """Reject redirected or shared writable recovery state before mutation."""
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise BootstrapError(f"Recovery directory is a symlink: {parent}")
        if parent.exists():
            info = parent.stat()
            if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
                raise BootstrapError(
                    f"Recovery ancestor permits shared writes: {parent}"
                )
    if create:
        path.mkdir(parents=True, mode=0o700, exist_ok=True)
    elif not path.exists():
        return
    info = path.stat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o022
    ):
        raise BootstrapError(
            "Recovery directory must be owned and writable only by this account: "
            f"{path}"
        )


def read_json_object(path):
    """Treat damaged manager state as an operational error, never as empty state."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise BootstrapError(
            f"Cannot read JSON state {path}: {error}"
        ) from error
    if not isinstance(data, dict):
        raise BootstrapError(f"JSON state must be an object: {path}")
    return data


def checksum_support():
    """python-build fails open without a SHA256 utility; fail closed here."""
    expected = (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    for name, arguments in (
        ("sha256sum", [os.devnull]),
        ("shasum", ["-a", "256", os.devnull]),
        ("openssl", ["dgst", "-sha256", os.devnull]),
    ):
        executable = shutil.which(name)
        if executable and expected in run([executable, *arguments]):
            return
    raise BootstrapError("Python builds require a working SHA256 verifier")


def native_command(name):
    executable = shutil.which(name)
    if not executable:
        raise BootstrapError(
            f"Install native {name} first; see home/dev/native-managers.nix"
        )
    if Path(executable).resolve().is_relative_to(Path("/nix/store")):
        raise BootstrapError(
            f"{name} still uses the Nix bridge; provision its native replacement first"
        )
    return executable
