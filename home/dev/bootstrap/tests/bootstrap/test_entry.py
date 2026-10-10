"""Offline contracts for the pre-Nix entry, using the macOS Bash 3.2 interface.

Run with python3 -B home/dev/bootstrap/tests/run.py source. Acquisition and host
discovery are substituted; installer fixtures only update disposable markers.
No real installer, privilege request, daemon mutation or runtime install runs.
"""

import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ENTRY = (
    Path(__file__).resolve().parents[2]
    / "../../../scripts/bootstrap/dev-bootstrap.sh"
).resolve()
if not ENTRY.is_file():
    raise unittest.SkipTest(
        "pre-Nix entry is available in the source checkout"
    )


class BootstrapEntryTests(unittest.TestCase):
    """Exercise entry behavior and acquisition integrity, not upstream installers."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bootstrap entry ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / "commands"
        self.nix = self.root / "nix"
        self.nix.write_text(
            '#!/bin/bash\nprintf "%s\\n" "$@" >> "$LOG"\nexit "${NIX_STATUS:-0}"\n'
        )
        self.nix.chmod(0o700)
        self.environment = dict(
            os.environ,
            HOME=str(self.root),
            TMPDIR=str(self.root),
            LOG=str(self.log),
            FIXTURE=str(self.root),
            NIX=str(self.nix),
        )
        self.discovery = """
bootstrap_platform() { printf 'darwin\\n'; }
bootstrap_nix() { [[ -f "$FIXTURE/has-nix" ]] && printf '%s\\n' "$NIX"; }
bootstrap_native() { [[ -f "$FIXTURE/has-homebrew" ]]; }
bootstrap_sdk() { [[ -f "$FIXTURE/has-sdk" ]]; }
"""

    def run_shell(self, code, *arguments, environment=None):
        """Source the production functions and invoke a controlled entry point."""
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; shift\n' + code,
                "bootstrap-test",
                str(ENTRY),
                *arguments,
            ],
            env=environment or self.environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def mark(self, *names):
        for name in ("nix", "homebrew", "sdk"):
            (self.root / f"has-{name}").unlink(missing_ok=True)
        for name in names:
            (self.root / f"has-{name}").touch()
        self.log.unlink(missing_ok=True)

    def test_foundation_check_reports_independent_blockers(self):
        """Checking reports absence/daemon failure without acquisition or writes."""
        for present, daemon_status, expected in (
            ((), 0, 1),
            (("nix",), 0, 1),
            (("nix", "homebrew", "sdk"), 0, 0),
            (("nix", "homebrew", "sdk"), 7, 1),
        ):
            with self.subTest(present=present, daemon_status=daemon_status):
                self.mark(*present)
                result = self.run_shell(
                    self.discovery + 'bootstrap_main "$@"',
                    "--check-foundation",
                    environment=dict(
                        self.environment, NIX_STATUS=str(daemon_status)
                    ),
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                if self.log.exists():
                    self.assertEqual(
                        self.log.read_text().splitlines(),
                        [
                            "--extra-experimental-features",
                            "nix-command",
                            "store",
                            "info",
                            "--json",
                            "--store",
                            "daemon",
                        ],
                    )

    def test_runtime_arguments_and_exit_status_are_preserved(self):
        """No shell re-evaluation, lockfile update or implicit apply is introduced."""
        self.mark("nix")
        for arguments in (
            (),
            ("plan", "--json"),
            ("verify", "--manifest", "a path;$(touch injected)"),
        ):
            with self.subTest(arguments=arguments):
                self.log.unlink(missing_ok=True)
                result = self.run_shell(
                    self.discovery + 'bootstrap_main "$@"',
                    *arguments,
                    environment=dict(self.environment, NIX_STATUS="19"),
                )
                self.assertEqual(result.returncode, 19, result.stderr)
                self.assertEqual(
                    self.log.read_text().splitlines(),
                    [
                        "--extra-experimental-features",
                        "nix-command flakes",
                        "run",
                        "--impure",
                        "--expr",
                        "import ./scripts/bootstrap/development-bootstrap.nix {}",
                        "",
                        "--",
                        *arguments,
                    ],
                )

    def test_interactive_arch_apply_authenticates_before_running(self):
        """Only an attended Arch apply that may install packages asks sudo."""
        self.mark("nix")
        for platform, attended, arguments, sudo, expected in (
            ("arch", "true", ("apply",), "true", True),
            ("arch", "true", ("apply", "--only", "rust"), "true", True),
            ("arch", "false", ("apply",), "true", False),
            ("arch", "true", ("apply", "--runtimes-only"), "true", False),
            ("arch", "true", ("plan",), "true", False),
            ("darwin", "true", ("apply",), "true", False),
            ("arch", "true", ("apply",), "false", None),
        ):
            with self.subTest(
                platform=platform, attended=attended, arguments=arguments
            ):
                self.log.unlink(missing_ok=True)
                result = self.run_shell(
                    self.discovery
                    + f"""
bootstrap_platform() {{ printf '{platform}\\n'; }}
bootstrap_interactive() {{ {attended}; }}
sudo() {{ printf 'sudo %s\\n' "$*" >> "$LOG"; {sudo}; }}
bootstrap_main "$@"
""",
                    *arguments,
                )
                lines = self.log.read_text().splitlines()
                if expected is None:
                    # Failed authentication stops before the executor runs.
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(lines, ["sudo -v"])
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual("sudo -v" in lines, expected)
                self.assertEqual(lines[-len(arguments) :], list(arguments))

    def test_invalid_entry_and_missing_nix_never_install(self):
        """Argument errors and normal planning cannot trigger foundation mutation."""
        self.mark()
        for arguments in (
            ("--install-foundation", "typo"),
            ("--check-foundation", "apply"),
            ("plan",),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_shell(
                    self.discovery
                    + """
bootstrap_install() { printf 'unexpected installer' >> "$LOG"; }
bootstrap_main "$@"
""",
                    *arguments,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.log.exists())

    def test_only_missing_foundations_are_installed_and_rerun_is_empty(self):
        """One adapter sequence covers fresh, partial and already prepared hosts."""
        installers = """
id() { printf '1000\\n'; }
sudo() { printf 'sudo %s\\n' "$*" >> "$LOG"; }
bootstrap_download() {
  printf 'fetch %s\\n' "$1" >> "$LOG"
  case "$3" in
    */homebrew.sh) printf 'touch "$FIXTURE/has-homebrew"\\n' > "$3" ;;
    */nix.sh) printf 'touch "$FIXTURE/has-nix"\\n' > "$3" ;;
  esac
}
bootstrap_install darwin
bootstrap_install darwin
"""
        for present in ((), ("nix",), ("homebrew",), ("nix", "homebrew")):
            with self.subTest(present=present):
                self.mark(*present)
                result = self.run_shell(self.discovery + installers)
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = (
                    self.log.read_text().splitlines()
                    if self.log.exists()
                    else []
                )
                fetches = [line for line in lines if line.startswith("fetch ")]
                self.assertEqual(len(fetches), 2 - len(present))
                if len(fetches) == 2:
                    self.assertIn("Homebrew/install/", fetches[0])
                    self.assertIn("nix-2.34.8/install", fetches[1])
                self.assertFalse(list(self.root.glob("dev-bootstrap.*")))

    def test_failed_foundation_stops_before_runtime(self):
        """Acquisition/installer errors stop the sequence and clean private scratch."""
        for download, status in (
            ("return 23", 23),
            ('''printf 'exit 29\\n' > "$3"''', 29),
        ):
            with self.subTest(status=status):
                self.mark()
                result = self.run_shell(
                    self.discovery
                    + """
id() { printf '1000\\n'; }
sudo() { :; }
bootstrap_download() { """
                    + download
                    + """; }
bootstrap_main --install-foundation apply --only node
"""
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertFalse(self.log.exists())
                self.assertFalse((self.root / "has-homebrew").exists())
                self.assertFalse(list(self.root.glob("dev-bootstrap.*")))

    def test_download_integrity(self):
        """The fetched file must match the declared digest before it can run."""
        payload = self.root / "payload"
        payload.write_bytes(b"inert installer fixture\n")
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        for expected, status in ((digest, 0), ("0" * 64, 2)):
            with self.subTest(expected=expected):
                result = self.run_shell(
                    """
curl() { cp "$FIXTURE/payload" "${@: -1}"; }
bootstrap_download https://example.invalid/installer "$1" "$FIXTURE/download"
""",
                    expected,
                )
                self.assertEqual(result.returncode, status, result.stderr)


if __name__ == "__main__":
    unittest.main()
