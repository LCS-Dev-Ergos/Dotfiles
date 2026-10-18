"""Git and Hugo, run as programs from the caller's PATH.

Every command gets literal arguments and a time limit. Git commits only the
folders ``blog`` writes, so whatever else is staged or changed in the
repository stays as it was; a push never forces. Hugo builds into a
temporary folder: the check leaves the site's tracked files as they were.
"""

import os
import shutil
import subprocess
import tempfile
from collections.abc import Mapping, Sequence
from pathlib import Path

from .config import ToolError

GIT_TIMEOUT = 600
"""Seconds a push may take."""

HUGO_TIMEOUT = 300
"""Seconds a build may take."""


def program(name: str, environ: Mapping[str, str]) -> str:
    """A program's path on PATH.

    Raises:
        ToolError: If it is not installed.
    """
    found = shutil.which(name, path=environ.get("PATH", ""))
    if found is None:
        raise ToolError(f"{name} is not installed")
    return found


def run(
    command: Sequence[str],
    environ: Mapping[str, str],
    *,
    cwd: Path | None = None,
    timeout: int = 60,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run a program to completion and capture what it prints.

    Raises:
        ToolError: If it cannot start, runs out of time, or fails while
            ``check`` is set; its last error line says why.
    """
    name = Path(command[0]).name
    try:
        result = subprocess.run(
            list(command),
            cwd=cwd,
            env=dict(environ),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise ToolError(f"{name} took longer than {timeout}s") from error
    except OSError as error:
        raise ToolError(f"Cannot run {name}: {error.strerror}") from error
    if check and result.returncode != 0:
        raise ToolError(f"{name} failed: {last_error(result)}")
    return result


def last_error(result: subprocess.CompletedProcess[str]) -> str:
    """The line of a failed program's output that best says why."""
    lines = [
        line.strip()
        for line in (result.stderr or result.stdout).splitlines()
        if line.strip()
    ]
    errors = [line for line in lines if "error" in line.lower()]
    if errors or lines:
        return (errors or lines)[-1]
    return f"status {result.returncode}"


# Git --------------------------------------------------------------------------


def git(
    repository: Path,
    *arguments: str,
    environ: Mapping[str, str],
    timeout: int = 60,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run git in a repository; prompts are off, so nothing waits on input."""
    command = [program("git", environ), "-C", str(repository), *arguments]
    quiet = {**environ, "GIT_TERMINAL_PROMPT": "0"}
    return run(command, quiet, timeout=timeout, check=check)


def toplevel(folder: Path, environ: Mapping[str, str]) -> Path:
    """The repository a folder belongs to.

    Raises:
        ToolError: If it is in none.
    """
    result = git(
        folder, "rev-parse", "--show-toplevel", environ=environ, check=False
    )
    if result.returncode != 0:
        raise ToolError(f"{folder} is not in a Git repository")
    return Path(result.stdout.strip())


def branch(repository: Path, environ: Mapping[str, str]) -> str:
    """The checked-out branch, empty on a detached HEAD."""
    result = git(
        repository,
        "symbolic-ref",
        "--quiet",
        "--short",
        "HEAD",
        environ=environ,
        check=False,
    )
    return result.stdout.strip()


def ahead(repository: Path, environ: Mapping[str, str]) -> int | None:
    """Commits not yet on the upstream, as last fetched; None without one."""
    result = git(
        repository,
        "rev-list",
        "--count",
        "@{upstream}..HEAD",
        environ=environ,
        check=False,
    )
    if result.returncode != 0:
        return None
    return int(result.stdout.strip() or 0)


def pending(
    repository: Path, paths: Sequence[str], environ: Mapping[str, str]
) -> int:
    """Uncommitted files in the given folders."""
    result = git(
        repository,
        "status",
        "--porcelain",
        "-z",
        "--untracked-files=all",
        "--",
        *paths,
        environ=environ,
    )
    count = 0
    entries = iter(result.stdout.split("\0"))
    for entry in entries:
        if not entry:
            continue
        count += 1
        if entry[0] in "RC":
            next(entries, None)
    return count


def commit(
    repository: Path,
    paths: Sequence[str],
    message: str,
    environ: Mapping[str, str],
) -> bool:
    """Commit the given folders alone; whether there was anything to commit.

    No folder means nothing to commit: Git would read an empty list of
    paths as the whole repository.

    Raises:
        ToolError: If staging or committing fails.
    """
    if not paths:
        return False
    git(repository, "add", "--all", "--", *paths, environ=environ)
    staged = git(
        repository,
        "diff",
        "--cached",
        "--quiet",
        "--",
        *paths,
        environ=environ,
        check=False,
    )
    if staged.returncode == 0:
        return False
    git(
        repository,
        "commit",
        "--quiet",
        "--message",
        message,
        "--",
        *paths,
        environ=environ,
        timeout=GIT_TIMEOUT,
    )
    return True


def push(
    repository: Path, remote: str, name: str, environ: Mapping[str, str]
) -> None:
    """Push a branch to the remote branch of the same name, never forcing.

    Raises:
        ToolError: If the push is refused or fails; the commits stay.
    """
    try:
        git(
            repository,
            "push",
            "--quiet",
            remote,
            f"refs/heads/{name}:refs/heads/{name}",
            environ=environ,
            timeout=GIT_TIMEOUT,
        )
    except ToolError as error:
        raise ToolError(
            f"{error}; the commit is kept, so pull if {remote} moved on, "
            "then publish again"
        ) from error


# Hugo -------------------------------------------------------------------------


def hugo_version(environ: Mapping[str, str]) -> str:
    """Hugo's version line, or why there is none."""
    try:
        result = run([program("hugo", environ), "version"], environ)
    except ToolError as error:
        return str(error)
    return result.stdout.strip().splitlines()[0] if result.stdout else ""


def build(site: Path, environ: Mapping[str, str]) -> int:
    """Build the site into a temporary folder; how many pages it made.

    Hugo would otherwise rewrite the tracked ``assets/jsconfig.json`` in its
    own format, so that file is switched off for the build; its resource
    cache under the ignored ``resources/`` is kept, which speeds the next
    build.

    Raises:
        ToolError: If Hugo is missing, fails or runs out of time.
    """
    hugo = program("hugo", environ)
    with tempfile.TemporaryDirectory(prefix="blog-build.") as output:
        run(
            [
                hugo,
                "--source",
                str(site),
                "--destination",
                output,
                "--minify",
                "--noBuildLock",
                "--quiet",
            ],
            {**environ, "HUGO_BUILD_NOJSCONFIGINASSETS": "true"},
            timeout=HUGO_TIMEOUT,
        )
        return sum(
            name.endswith(".html")
            for _, _, names in os.walk(output)
            for name in names
        )
