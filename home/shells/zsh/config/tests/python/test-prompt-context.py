#!/usr/bin/env python3

"""Exercise useful Starship states with isolated repositories and environments.

The actual Starship binary renders the repository configuration, whose context
shares the first line with the location. The Python version probe that Home
Manager puts in front of python_binary is exercised directly.
Git operations, tool fixtures and configuration writes stay in temporary HOME.
"""

import importlib.util
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

# --------------------------- Configuration Paths ---------------------------- #

RESIZE_TEST = Path(__file__).with_name("test-prompt-resize.py")
SPEC = importlib.util.spec_from_file_location("prompt_resize", RESIZE_TEST)
RESIZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESIZE)
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PYTHON_PROBE = RESIZE.CONFIG_ROOT.parent.parent / "starship/scripts/python-version.sh"

# ---------------------------- Context Regression ---------------------------- #


@unittest.skipUnless(
    all(shutil.which(tool) for tool in ("git", "starship")),
    "requires Git and Starship",
)
class PromptContextTest(unittest.TestCase):
    """Validate information shown for actual command and repository states."""

    def setUp(self) -> None:
        """Create an isolated home, repository, executable directory and env."""
        temporary = tempfile.TemporaryDirectory(prefix="starship-context-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.work = self.root / "project-probe"
        self.work.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "STARSHIP_CONFIG": str(RESIZE.starship_config_path()),
            "STARSHIP_SHELL": "bash",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "Prompt Test",
            "GIT_AUTHOR_EMAIL": "prompt@example.invalid",
            "GIT_COMMITTER_NAME": "Prompt Test",
            "GIT_COMMITTER_EMAIL": "prompt@example.invalid",
        }
        self.git("init", "-q", "-b", "main")
        (self.work / "tracked.txt").write_text("initial\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial fixture")

    def git(self, *args: str) -> str:
        """Run Git only in the fixture; return stdout or fail on an error."""
        return subprocess.check_output(
            ["git", *args],
            cwd=self.work,
            env=self.env,
            text=True,
            stderr=subprocess.PIPE,
            timeout=10,
        )

    def render(self, *args: str) -> str:
        """Render a real prompt, reject warnings, and remove ANSI styling.

        Args:
            args: Starship arguments such as status, jobs or command duration.

        Returns:
            Visible prompt text, retaining spacing and line breaks.
        """
        result = subprocess.run(
            [
                "starship",
                "prompt",
                "--terminal-width",
                "120",
                "--status",
                "0",
                *args,
            ],
            cwd=self.work,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=10,
            check=True,
        )
        self.assertEqual(result.stderr, "", result.stderr)
        return ANSI.sub("", result.stdout).replace("\\[", "").replace("\\]", "")

    def executable(self, name: str, output: str) -> None:
        """Install a deterministic version-only tool in the fixture's PATH."""
        target = self.bin / name
        target.write_text("#!/bin/sh\nprintf '%s\\n' '" + output + "'\n")
        target.chmod(0o700)

    def test_git_counts_and_stash(self) -> None:
        """Distinguish staged, modified, untracked and stashed changes."""
        (self.work / "tracked.txt").write_text("stashed\n")
        self.git("stash", "push", "-qm", "Fixture stash")
        (self.work / "tracked.txt").write_text("modified\n")
        (self.work / "staged.txt").write_text("staged\n")
        self.git("add", "staged.txt")
        (self.work / "untracked.txt").write_text("untracked\n")
        prompt = self.render()
        for marker in ("+1", "!1", "?1", "≡1"):
            self.assertIn(marker, prompt)

    def test_git_upstream_and_detached_worktree(self) -> None:
        """Show ahead/behind counts and a commit in a detached linked worktree."""
        self.git("branch", "upstream")
        self.git("branch", "--set-upstream-to=upstream")
        self.git("commit", "--allow-empty", "-qm", "Ahead fixture")
        self.assertIn("↑1", self.render())
        self.git("checkout", "-q", "upstream")
        self.git("commit", "--allow-empty", "-qm", "Other fixture")
        self.git("checkout", "-q", "main")
        prompt = self.render()
        self.assertIn("↑1", prompt)
        self.assertIn("↓1", prompt)
        commit = self.git("rev-parse", "--short=7", "HEAD").strip()
        worktree = self.root / "detached-probe"
        self.git("worktree", "add", "-q", "--detach", str(worktree))
        self.work = worktree
        prompt = self.render()
        self.assertIn(commit, prompt)
        self.assertNotIn("󰘬 main", prompt)

    def test_merge_conflict_remains_visible_on_left(self) -> None:
        """Keep conflicts and the ongoing merge visible beside the repository."""
        self.git("checkout", "-qb", "other")
        (self.work / "tracked.txt").write_text("other\n")
        self.git("commit", "-qam", "Other change")
        self.git("checkout", "-q", "main")
        (self.work / "tracked.txt").write_text("main\n")
        self.git("commit", "-qam", "Main change")
        with self.assertRaises(subprocess.CalledProcessError):
            self.git("merge", "--no-edit", "other")
        prompt = self.render()
        self.assertIn("MERGING", prompt)
        self.assertIn("×1", prompt)

    def test_pipeline_failure_is_visible_when_last_command_succeeds(self) -> None:
        """Expose an earlier pipeline failure even with final exit status zero."""
        failed = self.render("--pipestatus", "1 0")
        self.assertIn("[1 | 0]", failed)
        succeeded = self.render("--pipestatus", "0 0")
        self.assertNotIn("[0 | 0]", succeeded)

    def test_python_environment_names_the_project_and_active_interpreter(self) -> None:
        """Prefer python in PATH and expand a generic .venv to its project name."""
        self.executable("python", "Python 3.12.9")
        self.executable("python3", "Python 3.13.1")
        virtualenv = self.work / ".venv"
        virtualenv.mkdir()
        self.env["VIRTUAL_ENV"] = str(virtualenv)
        prompt = self.render()
        self.assertIn("v3.12.9", prompt)
        self.assertIn("(project-probe)", prompt)
        self.assertNotIn("v3.13.1", prompt)
        self.assertNotIn("(.venv)", prompt)

    def test_c_and_cpp_markers_do_not_launch_compilers(self) -> None:
        """Detect C/C++ sources without paying for compiler subprocesses."""
        (self.work / "probe.cpp").write_text("int main() {}\n")
        (self.work / "probe.c").write_text("int main() {}\n")
        for name in ("cc", "c++"):
            compiler = self.bin / name
            compiler.write_text(
                "#!/bin/sh\ntouch compiler-started\nprintf 'GCC 14.2.0\\n'\n"
            )
            compiler.chmod(0o700)
        prompt = self.render()
        self.assertIn("", prompt)
        self.assertIn("", prompt)
        self.assertFalse((self.work / "compiler-started").exists())

    def test_bun_is_detected_from_its_lockfile(self) -> None:
        """Show the Bun version in a Bun project without changing other folders."""
        self.executable("bun", "1.3.0")
        self.assertNotIn("", self.render())
        (self.work / "bun.lock").write_text("{}\n")
        prompt = self.render()
        self.assertIn("", prompt)
        self.assertIn("v1.3.0", prompt)

    def test_missing_runtime_does_not_leave_an_empty_icon(self) -> None:
        """Hide the Node icon when a project exists but its runtime cannot run."""
        (self.work / "package.json").write_text("{}\n")
        node = self.bin / "node"
        node.write_text("#!/bin/sh\nexit 1\n")
        node.chmod(0o700)
        self.assertNotIn("󰎙", self.render())

    def test_context_shares_the_first_line_behind_a_bar(self) -> None:
        """Keep context on the information line and the bar only when needed."""
        quiet = self.render().splitlines()
        self.assertEqual(len(quiet), 2, quiet)
        self.assertNotIn("│", quiet[0])
        first, second = self.render("--jobs", "1").splitlines()
        self.assertIn("│ 󰜎 1", first)
        self.assertNotIn("󰜎", second)

    def test_jobs_and_slow_commands_are_contextual(self) -> None:
        """Show even one background job and elapsed time only for slow commands."""
        prompt = self.render("--jobs", "1", "--cmd-duration", "4200")
        self.assertIn("󰜎 1", prompt)
        self.assertIn("4s", prompt)
        quiet = self.render("--jobs", "0", "--cmd-duration", "100")
        self.assertNotIn("󰜎", quiet)
        self.assertNotIn("󱦟", quiet)


# ---------------------------- Python Version Probe --------------------------- #


@unittest.skipUnless(
    PYTHON_PROBE.is_file(), "python-version.sh is not beside this tree"
)
class PythonProbeTest(unittest.TestCase):
    """Answer Starship's python --version from files, not from pyenv shims."""

    def setUp(self) -> None:
        """Create a project, a pyenv root and stub interpreters that leave a trace."""
        temporary = tempfile.TemporaryDirectory(prefix="python-probe-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / "home" / "project"
        (self.project / "src").mkdir(parents=True)
        self.pyenv = self.root / "pyenv"
        self.trace = self.root / "started"
        self.stub(self.pyenv / "shims/python", "shim", "Python 9.9.9")
        self.stub(self.pyenv / "versions/3.12.1/bin/python", "3.12.1", "Python 3.12.1")
        self.stub(self.pyenv / "versions/3.13.2/bin/python", "3.13.2", "Python 3.13.2")
        (self.pyenv / "version").write_text("3.12.1\n")
        self.env = {
            "PATH": str(self.pyenv / "shims") + os.pathsep + "/usr/bin:/bin",
            "HOME": str(self.root / "home"),
            "PYENV_ROOT": str(self.pyenv),
        }

    def stub(self, path: Path, name: str, output: str) -> None:
        """Install an interpreter stub that records its name when started."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\necho {name} >> {self.trace}\necho '{output}'\n")
        path.chmod(0o700)

    def probe(self, cwd: Path) -> str:
        """Run the probe the way Starship does and return its answer."""
        return subprocess.check_output(
            [str(PYTHON_PROBE), "--version"],
            cwd=cwd,
            env=self.env,
            text=True,
            timeout=10,
        ).strip()

    def started(self) -> list[str]:
        """Names of the stub interpreters that actually ran."""
        return self.trace.read_text().split() if self.trace.exists() else []

    def test_project_venv_is_read_from_pyvenv_cfg(self) -> None:
        """Report the project's .venv from any subdirectory without running it."""
        venv = self.project / ".venv"
        venv.mkdir()
        (venv / "pyvenv.cfg").write_text(
            "home = /x\nversion_info = 3.11\nprompt = project\n"
        )
        self.assertEqual(self.probe(self.project / "src"), "Python 3.11")
        self.assertEqual(self.started(), [])

    def test_pyenv_selection_skips_the_shim(self) -> None:
        """Run the pyenv-selected interpreter directly, honouring .python-version."""
        self.assertEqual(self.probe(self.project), "Python 3.12.1")
        (self.project / ".python-version").write_text("3.13.2\n")
        self.assertEqual(self.probe(self.project / "src"), "Python 3.13.2")
        self.env["PYENV_VERSION"] = "3.12.1:3.13.2"
        self.assertEqual(self.probe(self.project / "src"), "Python 3.12.1")
        self.assertNotIn("shim", self.started())

    def test_unresolved_names_fall_back_to_the_shim(self) -> None:
        """Leave system and version prefixes to pyenv itself."""
        (self.pyenv / "version").write_text("system\n")
        self.assertEqual(self.probe(self.project), "Python 9.9.9")
        self.assertEqual(self.started(), ["shim"])


# ------------------------------- Entry Point -------------------------------- #

if __name__ == "__main__":
    unittest.main()
