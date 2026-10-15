"""The single process boundary: literal argv, scoped child environments.

Children run without a terminal, in their own process group. Two calls keep
the terminal: attend(), for the authentication a person answers, and
interact(), for the guided setup's questions.
"""

import os
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import time
from contextlib import contextmanager

from .errors import BootstrapError

# Seconds an interrupted child's process group gets to clean up after SIGTERM
# (python-build and ruby-build remove their partial prefix) before SIGKILL.
GRACE = 30

# The log a recorded run copies every child's output into, or None.
_log = None

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
        "FNM_NODE_DIST_MIRROR",
        "FNM_ARCH",
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
        result = complete(args, env=clean, timeout=timeout, cwd=cwd)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BootstrapError(str(error)) from error
    if result.returncode not in success_codes:
        # Some tools print the cause on stdout: Homebrew reports a failed link
        # step on stderr and the conflicting files on stdout. Keep both tails.
        detail = result.stderr[-2000:].strip()
        if result.stdout.strip():
            detail += f"\nstdout: {result.stdout[-2000:].strip()}"
        raise BootstrapError(f"{args[0]} exited {result.returncode}: {detail}")
    return result.stdout.strip()


class Log:
    """A run's log file, created by the first child that writes to it.

    A stage that runs no child leaves no empty file behind.
    """

    def __init__(self, path):
        self.path = path
        self.file = None

    def write(self, data):
        if self.file is None:
            descriptor = os.open(
                self.path,
                os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW,
                0o600,
            )
            self.file = open(descriptor, "ab", buffering=0)
        self.file.write(data)

    def close(self):
        if self.file is not None:
            self.file.close()
            self.file = None


@contextmanager
def recorded(path):
    """Copy the output of every child the block runs into the log at path."""
    global _log
    previous, log = _log, Log(path)
    _log = log
    try:
        yield log
    finally:
        _log = previous
        log.close()


def attended():
    """Whether a person can answer at the terminal: stdin is one."""
    return bool(sys.stdin and sys.stdin.isatty())


def announce(message):
    """Tell the person at the terminal what is about to ask them."""
    print(f"dev-bootstrap: {message}", file=sys.stderr, flush=True)


def attend(args, *, timeout=600):
    """Run the one child that may ask a person something: authentication.

    It keeps bootstrap's terminal, environment and process group, so the
    password prompt reaches the person and Ctrl-C stops both. It never
    installs anything; the privileged work itself still goes through run().
    """
    try:
        result = subprocess.run(args, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BootstrapError(str(error)) from error
    if result.returncode != 0:
        raise BootstrapError(f"{args[0]} exited {result.returncode}")


def interact(args, *, env):
    """Run a widget that asks a person at the terminal (Gum).

    Like attend(), the child keeps bootstrap's terminal and process group,
    so Ctrl-C reaches both. Its stdout is captured: the answer. It installs
    and changes nothing; the status is the caller's to read.
    """
    try:
        result = subprocess.run(
            args, env=env, stdout=subprocess.PIPE, text=True, check=False
        )
    except OSError as error:
        raise BootstrapError(str(error)) from error
    return result.returncode, result.stdout


def complete(args, *, env, timeout, cwd):
    """Run a child in its own process group, which ends with the call.

    Managers leave compilers and downloads running below them. When the call
    times out or bootstrap is interrupted, we end the whole group, so nothing
    keeps writing into a prefix after the lock is released. A terminal's
    Ctrl-C reaches only bootstrap, which then stops the group the same way.
    While a run is recorded, the child's output reaches its log as it is
    written, so a long build can be followed and an interrupted one keeps
    what it printed.
    """
    log = _log
    if log:
        log.write(f"$ {shlex.join(map(str, args))}\n".encode())
    started = time.monotonic()
    with subprocess.Popen(
        args,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        start_new_session=True,
    ) as child:
        try:
            stdout, stderr = collect(child, timeout, log)
        except BaseException:
            stop(child)
            if log:
                log.write(b"[stopped]\n\n")
            raise
    if log:
        elapsed = time.monotonic() - started
        log.write(
            f"[exit {child.returncode} after {elapsed:.1f} s]\n\n".encode()
        )
    return subprocess.CompletedProcess(
        args, child.returncode, decode(stdout), decode(stderr)
    )


def collect(child, timeout, log):
    """Read both pipes until they close, copying each chunk to the log."""
    deadline = time.monotonic() + timeout
    chunks = {child.stdout: [], child.stderr: []}
    with selectors.DefaultSelector() as selector:
        for pipe in chunks:
            selector.register(pipe, selectors.EVENT_READ)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(child.args, timeout)
            for key, _ in selector.select(remaining):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                chunks[key.fileobj].append(data)
                if log:
                    log.write(data)
    # A child may close its output and keep running.
    try:
        child.wait(timeout=max(deadline - time.monotonic(), 0))
    except subprocess.TimeoutExpired:
        raise subprocess.TimeoutExpired(child.args, timeout) from None
    return b"".join(chunks[child.stdout]), b"".join(chunks[child.stderr])


def decode(data):
    """Text as the callers read it: invalid bytes replaced, newlines unified."""
    text = data.decode("utf-8", errors="replace")
    return text.replace("\r\n", "\n").replace("\r", "\n")


def stop(child):
    """SIGTERM the child's process group, then SIGKILL what remains.

    A group already gone reports ESRCH, or EPERM on macOS while only zombies
    remain; neither may replace the exception that stopped the call.
    """
    try:
        os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=GRACE)
    except (ProcessLookupError, PermissionError, subprocess.TimeoutExpired):
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


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
