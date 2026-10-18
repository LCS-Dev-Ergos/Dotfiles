"""Shared fixtures: a vault, a site in a repository and a fake Hugo."""

import contextlib
import io
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import terminal_style as ui

from core import cli

GIT = shutil.which("git") or "git"

_TOOLS = os.pathsep.join(
    sorted(
        {
            os.path.dirname(found)
            for found in map(shutil.which, ("mkdir", "cat", "git"))
            if found
        }
    )
)

HUGO = """\
if [ "$1" = version ]; then echo "hugo v0.150.0 fake"; exit 0; fi
destination=""
while [ $# -gt 0 ]; do
  [ "$1" = --destination ] && destination="$2"
  shift
done
if [ "${HUGO_BUILD_NOJSCONFIGINASSETS:-}" != true ]; then
  echo "ERROR would rewrite assets/jsconfig.json" >&2
  exit 1
fi
if [ -n "${FAIL_HUGO:-}" ]; then
  echo "ERROR render of page failed" >&2
  exit 1
fi
mkdir -p "$destination/posts"
echo page > "$destination/index.html"
echo page > "$destination/posts/index.html"
"""
"""A Hugo that writes two pages; it fails when FAIL_HUGO is set, or when
it would rewrite the site's jsconfig.json."""


class Blog:
    """A vault, a Hugo site in a Git repository with a remote, and settings."""

    def __init__(self, test: unittest.TestCase) -> None:
        """Create the folders, the repository and the configuration."""
        handle = tempfile.TemporaryDirectory(prefix="blog-test.")
        test.addCleanup(handle.cleanup)
        self.root = Path(handle.name).resolve()
        self.posts = self.root / "vault" / "posts"
        self.images = self.root / "vault" / "images"
        self.repo = self.root / "repo"
        self.site = self.repo / "site"
        self.remote = self.root / "remote.git"
        self.config = self.root / "config.toml"
        self.state = self.root / "state"
        for folder in (self.posts, self.images, self.site / "content"):
            folder.mkdir(parents=True)
        (self.site / "hugo.toml").write_text('title = "Test"\n')
        gitconfig = self.root / "gitconfig"
        gitconfig.write_text(
            "[user]\n\tname = Test\n\temail = test@example.com\n"
            "[commit]\n\tgpgsign = false\n"
            "[init]\n\tdefaultBranch = main\n"
        )
        self.environ = {
            "PATH": f"{self.root / 'bin'}{os.pathsep}{_TOOLS}",
            "HOME": str(self.root / "home"),
            "XDG_STATE_HOME": str(self.state),
            "GIT_CONFIG_GLOBAL": str(gitconfig),
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        self.write_config()
        script = self.root / "bin" / "hugo"
        script.parent.mkdir()
        script.write_text(f'#!/bin/sh\nPATH="$PATH:{_TOOLS}"\n{HUGO}')
        script.chmod(0o755)
        self.git_at(self.root, "init", "--quiet", "--bare", str(self.remote))
        self.git("init", "--quiet")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("commit", "--quiet", "--allow-empty", "-m", "Start")
        self.git("push", "--quiet", "-u", "origin", "main")

    def write_config(self, extra: str = "") -> None:
        """The settings, followed by ``extra`` TOML lines."""
        self.config.write_text(
            f'site = "{self.site}"\n'
            f'posts = "{self.posts}"\n'
            f'images = "{self.images}"\n{extra}'
        )

    def post(self, name: str, text: str = "Body.\n") -> Path:
        """A post in the vault, with front matter."""
        path = self.posts / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"---\ntitle: {path.stem}\n---\n{text}")
        return path

    def image(self, name: str, data: bytes = b"\x89PNG") -> Path:
        """An image in the vault."""
        path = self.images / name
        path.write_bytes(data)
        return path

    def git(self, *arguments: str) -> str:
        """Run git in the site's repository; its output."""
        return self.git_at(self.repo, *arguments)

    def git_at(self, folder: Path, *arguments: str) -> str:
        """Run git in a folder with the test's settings; its output."""
        folder.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [GIT, *arguments],
            cwd=folder,
            env=self.environ,
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout

    def run(
        self, *argv: str, env: dict[str, str] | None = None
    ) -> tuple[int, str, str]:
        """Run blog with these settings: its status, output and errors."""
        out, err = io.StringIO(), io.StringIO()
        arguments = [*argv, "--config", str(self.config)]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                status = cli.main(
                    arguments, self.environ | (env or {}), ui.Style(False)
                )
            except SystemExit as error:
                status = int(error.code or 0)
        return status, out.getvalue(), err.getvalue()
