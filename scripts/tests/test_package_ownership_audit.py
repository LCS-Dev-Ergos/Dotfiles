"""Verify ownership reporting with isolated package-manager and PATH fixtures."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


AUDIT = (
    Path(__file__).resolve().parents[1] / "audits/audit-package-ownership.sh"
)
BASH = shutil.which("bash")


class OwnershipAuditTests(unittest.TestCase):
    """Exercise the complete audit without Nix, Homebrew or policy files."""

    def setUp(self):
        """Create matching inventories and executable candidates in a private home."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.nix_bin = self.home / ".nix-profile/bin"
        self.brew = self.root / "brew"
        self.brew_bin = self.brew / "bin"
        self.other_bin = self.root / "other"
        self.tools = self.root / "tools"
        for path in (self.nix_bin, self.brew_bin, self.other_bin, self.tools):
            path.mkdir(parents=True)
        self.audit_path = (
            self.root / "repo/scripts/audits/audit-package-ownership.sh"
        )
        self.audit_path.parent.mkdir(parents=True)
        shutil.copyfile(AUDIT, self.audit_path)
        for name in (
            "awk",
            "comm",
            "dirname",
            "grep",
            "jq",
            "mktemp",
            "realpath",
            "rm",
            "sort",
            "tr",
            "uniq",
            "wc",
        ):
            binary = shutil.which(name)
            if not binary:
                self.fail(f"Audit fixture requires {name}")
            (self.tools / name).symlink_to(binary)
        self.script(self.nix_bin / "demo", "exit 0\n")
        keg = self.brew / "Cellar/demo/1/bin/demo"
        self.script(keg, "exit 0\n")
        (self.brew_bin / "demo").symlink_to(keg)
        self.script(self.other_bin / "demo", "exit 0\n")
        declared = {"brews": [{"name": "demo"}], "casks": [], "taps": []}
        installed = {
            "formulae": [
                {
                    "name": "demo",
                    "full_name": "demo",
                    "installed": [{"installed_on_request": True}],
                }
            ],
            "casks": [],
        }
        (self.root / "declared.json").write_text(json.dumps(declared))
        (self.root / "installed.json").write_text(json.dumps(installed))
        self.script(
            self.tools / "nix",
            'exec /bin/cat "$AUDIT_FIXTURE/declared.json"\n',
        )
        self.script(
            self.tools / "brew",
            """case "$1" in
  --prefix) printf '%s\\n' "$AUDIT_BREW_PREFIX" ;;
  info) exec /bin/cat "$AUDIT_FIXTURE/installed.json" ;;
  list) printf 'demo\\n' ;;
  tap) : ;;
  *) exit 99 ;;
esac
""",
        )

    def script(self, path, body):
        """Write an executable shell fixture without invoking its commands."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o700)

    def audit(self, directories, *args):
        """Run the copied audit against a controlled PATH and matching inventories."""
        env = dict(
            os.environ,
            HOME=str(self.home),
            AUDIT_FIXTURE=str(self.root),
            AUDIT_BREW_PREFIX=str(self.brew),
            TMPDIR=str(self.root),
            PATH=os.pathsep.join(map(str, [*directories, self.tools])),
        )
        return subprocess.run(
            [BASH, str(self.audit_path), *args],
            env=env,
            cwd=self.root,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def test_nix_wins_without_an_allowlist(self):
        """Accept Nix precedence without requiring any external policy file."""
        result = self.audit([self.nix_bin, self.brew_bin])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BENIGN OVERLAPS", result.stdout)
        self.assertIn("demo (1)", result.stdout)

    def test_verbose_reports_nix_winner(self):
        """Show the winning executable and Homebrew owner in verbose mode."""
        result = self.audit([self.nix_bin, self.brew_bin], "--verbose")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("NIX-WINS", result.stdout)
        self.assertIn(str(self.nix_bin / "demo"), result.stdout)

    def test_homebrew_winner_is_a_failure(self):
        """Reject a Homebrew command that shadows an available Nix command."""
        result = self.audit([self.brew_bin, self.nix_bin])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("UNEXPECTED WINNER", result.stdout)
        self.assertIn("Unexpected Homebrew PATH winners: 1.", result.stdout)

    def test_other_winner_is_still_reported(self):
        """Report a third provider shadowing both Nix and Homebrew candidates."""
        result = self.audit([self.other_bin, self.nix_bin, self.brew_bin])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("OTHER WINNERS", result.stdout)
        self.assertIn("Other PATH winners: 1.", result.stdout)

    def test_unsafe_path_remains_a_failure(self):
        """Retain rejection of implicit current-directory PATH entries."""
        result = self.audit([self.nix_bin, self.brew_bin, ""])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("UNSAFE PATH ENTRY", result.stderr)
        self.assertIn("Unsafe PATH entries: 1.", result.stdout)


if __name__ == "__main__":
    unittest.main()
