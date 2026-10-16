"""Offline contracts for the pre-Nix entry, using the macOS Bash 3.2 interface.

Run with python3 -B home/dev/bootstrap/tests/run.py source. Acquisition and host
discovery are substituted; installer fixtures only update disposable markers.
No real installer, privilege request, daemon mutation or runtime install runs.
"""

import hashlib
import os
import re
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


# The Nix release the locked nixpkgs carries, which nix-darwin starts from.
LOCKED_NIX = (
    "let lock = builtins.fromJSON (builtins.readFile ./flake.lock); in "
    "(import (builtins.fetchTree "
    "lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked) { }).nix.version"
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
            '#!/bin/bash\nprintf "%s\\n" "$@" >> "$LOG"\n'
            'printf "%s\\n" "${DEV_BOOTSTRAP_COMMAND-unset}" > "$LOG.command"\n'
            'exit "${NIX_STATUS:-0}"\n'
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
bootstrap_build_tools() { [[ -f "$FIXTURE/has-tools" ]]; }
bootstrap_nix_residue() { [[ ! -f "$FIXTURE/has-residue" ]] || printf '/nix\\n'; }
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
        for name in ("nix", "homebrew", "sdk", "tools", "residue"):
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

    def test_arch_foundation_check_reports_build_tools(self):
        """base-devel is to Arch what the Apple SDK is to macOS."""
        for present, expected in (
            (("nix",), 1),
            (("nix", "tools"), 0),
        ):
            with self.subTest(present=present):
                self.mark(*present)
                result = self.run_shell(
                    self.discovery
                    + """
bootstrap_platform() { printf 'arch\\n'; }
bootstrap_native() { :; }
bootstrap_main "$@"
""",
                    "--check-foundation",
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                state = "ready  " if expected == 0 else "missing"
                self.assertIn(
                    f"{state} native build tools (base-devel)", result.stdout
                )

    def test_installed_nix_is_the_locked_release(self):
        """--install-foundation installs the Nix the configuration starts from."""
        pinned = re.search(
            r"releases\.nixos\.org/nix/nix-([0-9.]+)/install",
            ENTRY.read_text(),
        )
        locked = subprocess.run(
            [
                "nix",
                "--extra-experimental-features",
                "nix-command",
                "eval",
                "--raw",
                "--impure",
                "--expr",
                LOCKED_NIX,
            ],
            cwd=ENTRY.parents[2],
            capture_output=True,
            text=True,
            timeout=300,
            check=True,
        ).stdout
        self.assertEqual(pinned.group(1), locked)

    def test_runtime_arguments_and_exit_status_are_preserved(self):
        """No shell re-evaluation, lockfile update or implicit apply is introduced."""
        self.mark("nix")
        for arguments in (
            (),
            ("plan", "--json"),
            ("setup", "--only", "node"),
            ("report", "--last"),
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
                # What to run next names this entry until activation puts
                # dev-bootstrap on PATH.
                self.assertEqual(
                    Path(f"{self.log}.command").read_text().strip(),
                    str(ENTRY),
                )

    def test_runtime_operations_leave_privilege_to_the_executor(self):
        """The executor asks for sudo itself, and only when it needs it."""
        self.mark("nix")
        for platform in ("arch", "darwin"):
            for arguments in (("apply",), ("apply", "--only", "rust")):
                with self.subTest(platform=platform, arguments=arguments):
                    self.log.unlink(missing_ok=True)
                    result = self.run_shell(
                        self.discovery
                        + f"""
bootstrap_platform() {{ printf '{platform}\\n'; }}
sudo() {{ printf 'sudo %s\\n' "$*" >> "$LOG"; }}
bootstrap_main "$@"
""",
                        *arguments,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    lines = self.log.read_text().splitlines()
                    self.assertFalse(
                        any(line.startswith("sudo") for line in lines)
                    )
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

    def test_arch_installs_build_tools_and_nix_only_when_missing(self):
        """Arch gets base-devel through pacman and the same pinned Nix."""
        installers = """
bootstrap_platform() { printf 'arch\\n'; }
bootstrap_native() { :; }
id() { printf '1000\\n'; }
sudo() {
  printf 'sudo %s\\n' "$*" >> "$LOG"
  [[ "$*" != *pacman* ]] || touch "$FIXTURE/has-tools"
}
bootstrap_download() {
  printf 'fetch %s\\n' "$1" >> "$LOG"
  printf 'touch "$FIXTURE/has-nix"\\n' > "$3"
}
bootstrap_install arch
bootstrap_install arch
"""
        for present in ((), ("nix",), ("tools",), ("nix", "tools")):
            with self.subTest(present=present):
                self.mark(*present)
                result = self.run_shell(self.discovery + installers)
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = (
                    self.log.read_text().splitlines()
                    if self.log.exists()
                    else []
                )
                pacman = [line for line in lines if "pacman" in line]
                fetches = [line for line in lines if line.startswith("fetch ")]
                self.assertEqual(
                    pacman,
                    []
                    if "tools" in present
                    else [
                        "sudo -n /usr/bin/pacman -S --needed --noconfirm "
                        "base-devel"
                    ],
                )
                self.assertEqual(
                    fetches,
                    []
                    if "nix" in present
                    else [
                        "fetch https://releases.nixos.org/nix/nix-2.34.8/install"
                    ],
                )
                self.assertNotIn("Homebrew", result.stderr)
                # The announcement names exactly what is missing.
                self.assertEqual(
                    "base-devel" in result.stderr, "tools" not in present
                )
                self.assertEqual(
                    "Nix 2.34.8" in result.stderr, "nix" not in present
                )

    def test_announcement_precedes_authentication(self):
        """The person sees what will be installed before sudo asks."""
        self.mark("homebrew")
        result = self.run_shell(
            self.discovery
            + """
id() { printf '1000\\n'; }
sudo() { printf 'sudo %s\\n' "$*" >&2; return 1; }
bootstrap_install darwin
"""
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(
            result.stderr.index("Nix 2.34.8"), result.stderr.index("sudo -n")
        )
        self.assertNotIn("Homebrew ", result.stderr)

    def test_earlier_nix_residue_stops_before_any_change(self):
        """A half-removed Nix is named, not handed to an installer that fails."""
        self.mark("residue")
        result = self.run_shell(
            self.discovery
            + """
id() { printf '1000\\n'; }
sudo() { printf 'sudo %s\\n' "$*" >> "$LOG"; }
bootstrap_download() { printf 'fetch %s\\n' "$1" >> "$LOG"; }
bootstrap_install darwin
"""
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("/nix", result.stderr)
        self.assertIn("installation/uninstall", result.stderr)
        self.assertFalse(self.log.exists())

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
