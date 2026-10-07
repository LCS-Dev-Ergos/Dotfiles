"""The single process boundary: literal argv, scoped child environments."""

import os
import shutil
import subprocess

from .errors import BootstrapError

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
