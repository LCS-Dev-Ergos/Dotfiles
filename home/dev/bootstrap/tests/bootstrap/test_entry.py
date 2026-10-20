"""Offline contracts for the pre-Nix entry, using the macOS Bash 3.2 interface.

Run with python3 -B home/dev/bootstrap/tests/run.py source. Acquisition and host
discovery are substituted; installer fixtures only update disposable markers.
No real installer, privilege request, daemon mutation or runtime install runs.
"""

import hashlib
import json
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


PINS = ENTRY.parent / "foundation.nix"
# The Nix release the locked nixpkgs carries, which nix-darwin starts from.
LOCKED_NIX = (
    "(builtins.head (import ./scripts/bootstrap/development-bootstrap.nix "
    '{ target = "nix"; })).version'
)


def nix_eval(*arguments):
    return subprocess.run(
        ["nix", "--extra-experimental-features", "nix-command flakes", "eval"]
        + list(arguments),
        cwd=ENTRY.parents[2],
        capture_output=True,
        text=True,
        timeout=300,
        check=True,
    ).stdout


class BootstrapEntryTests(unittest.TestCase):
    """Exercise entry behavior and acquisition integrity, not upstream installers."""

    @classmethod
    def setUpClass(cls):
        cls.nix_version = json.loads(nix_eval("--json", "--file", str(PINS)))[
            "nixVersion"
        ]

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bootstrap entry ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / "commands"
        self.nix = self.root / "nix"
        self.nix.write_text(
            '#!/bin/bash\nprintf "%s\\n" "$@" >> "$LOG"\n'
            'printf "%s\\n" "${DEV_BOOTSTRAP_COMMAND-unset}" > "$LOG.command"\n'
            'printf "%s\\n" "${NIX_REMOTE-unset}" > "$LOG.remote"\n'
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
bootstrap_systemd() { [[ ! -f "$FIXTURE/has-no-systemd" ]]; }
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
        for name in (
            "nix",
            "homebrew",
            "sdk",
            "tools",
            "residue",
            "no-systemd",
        ):
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
                        ],
                    )
                    self.assertEqual(
                        Path(f"{self.log}.remote").read_text().strip(),
                        "daemon",
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
        pinned = json.loads(nix_eval("--json", "--file", str(PINS)))
        locked = nix_eval("--raw", "--impure", "--expr", LOCKED_NIX)
        self.assertEqual(pinned["nixVersion"], locked)

    def test_entry_reads_the_pins_nix_reads(self):
        """The line reader and Nix agree on every pin, so updates reach both."""
        pinned = json.loads(nix_eval("--json", "--file", str(PINS)))
        result = self.run_shell(
            'for name in "$@"; do bootstrap_pin "$name"; done', *pinned
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), list(pinned.values()))
        broken = self.root / "foundation.nix"
        broken.write_text(PINS.read_text() + '  nixVersion = "9.9.9";\n')
        result = self.run_shell(
            f'BOOTSTRAP_PINS="{broken}"; bootstrap_pin nixVersion'
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("must declare nixVersion once", result.stderr)

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
            ("--update-nix", "apply"),
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
                    self.assertIn(
                        f"nix-{self.nix_version}/install", fetches[1]
                    )
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
                        "fetch https://releases.nixos.org/nix/"
                        f"nix-{self.nix_version}/install"
                    ],
                )
                self.assertNotIn("Homebrew", result.stderr)
                # The announcement names exactly what is missing.
                self.assertEqual(
                    "base-devel" in result.stderr, "tools" not in present
                )
                self.assertEqual(
                    f"Nix {self.nix_version}" in result.stderr,
                    "nix" not in present,
                )

    def test_attended_install_asks_before_authentication(self):
        """At a terminal, only an explicit yes reaches sudo."""
        for answer, status in (("n\n", 1), ("\n", 1), ("y\n", 0)):
            with self.subTest(answer=answer):
                self.mark("homebrew")
                result = subprocess.run(
                    [
                        "/bin/bash",
                        "-c",
                        'source "$1"; shift\n'
                        + self.discovery
                        + """
bootstrap_attended() { :; }
id() { printf '1000\\n'; }
sudo() { printf 'sudo %s\\n' "$*" >> "$LOG"; }
bootstrap_download() { printf 'touch "$FIXTURE/has-nix"\\n' > "$3"; }
bootstrap_install darwin
""",
                        "bootstrap-test",
                        str(ENTRY),
                    ],
                    env=self.environment,
                    input=answer,
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=False,
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("Proceed? [y/N]", result.stderr)
                self.assertEqual(self.log.exists(), status == 0)
                if status:
                    self.assertIn("nothing was changed", result.stderr)

    def test_failed_nix_installer_names_what_it_left(self):
        """The installer does not roll back; the entry says what blocks a rerun."""
        self.mark("homebrew")
        result = self.run_shell(
            self.discovery
            + """
id() { printf '1000\\n'; }
sudo() { :; }
bootstrap_download() {
  printf 'touch "$FIXTURE/has-residue"; exit 5\\n' > "$3"
}
bootstrap_install darwin
"""
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("The Nix installer failed and left /nix", result.stderr)
        self.assertIn("installation/uninstall", result.stderr)

    def test_linux_nix_needs_systemd(self):
        """Without systemd the multi-user daemon cannot run; stop first."""
        self.mark("tools", "no-systemd")
        result = self.run_shell(
            self.discovery
            + """
bootstrap_native() { :; }
id() { printf '1000\\n'; }
sudo() { printf 'sudo %s\\n' "$*" >> "$LOG"; }
bootstrap_install arch
"""
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("needs systemd", result.stderr)
        self.assertFalse(self.log.exists())

    def update_nix(self, platform, daemon, *marks):
        """--update-nix against a stub client, daemon and store."""
        self.mark("nix", *marks)
        (self.root / "updated").unlink(missing_ok=True)
        client = self.root / "client"
        client.write_text(
            '#!/bin/bash\nprintf "nix %s\\n" "$*" >> "$LOG"\n'
            'case "$*" in\n'
            '  *" eval "*) printf 2.40.1 ;;\n'
            '  *" build "*) printf "%s\\n" /nix/store/a-nss-cacert-3.1 '
            "/nix/store/b-nix-2.40.1 ;;\n"
            "esac\n"
        )
        client.chmod(0o700)
        return self.run_shell(
            self.discovery
            + f"""
bootstrap_nix() {{ [[ -f "$FIXTURE/has-nix" ]] && printf '%s\\n' "$FIXTURE/client"; }}
bootstrap_official_nix() {{ [[ ! -f "$FIXTURE/has-foreign" ]]; }}
bootstrap_daemon_version() {{
  if [[ -f "$FIXTURE/updated" ]]; then printf '2.40.1\\n'; else printf '{daemon}\\n'; fi
}}
id() {{ printf '1000\\n'; }}
sudo() {{
  printf 'sudo %s\\n' "$*" >> "$LOG"
  [[ "$*" != *restart* ]] || touch "$FIXTURE/updated"
}}
bootstrap_update_nix {platform} "$FIXTURE"
"""
        )

    def commands(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_update_nix_moves_an_older_linux_daemon_to_the_lock(self):
        """Install the locked nix and CA bundle in the default profile, restart."""
        result = self.update_nix("arch", "2.34.8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("from 2.34.8 to 2.40.1", result.stderr)
        self.assertIn("ready   Nix daemon 2.40.1", result.stdout)
        sudo = [line for line in self.commands() if line.startswith("sudo")]
        self.assertEqual(
            sudo,
            [
                "sudo -n -v",
                "sudo -n -H /nix/store/b-nix-2.40.1/bin/nix-env --profile "
                "/nix/var/nix/profiles/default --install "
                "/nix/store/a-nss-cacert-3.1 /nix/store/b-nix-2.40.1",
                "sudo -n systemctl daemon-reload",
                "sudo -n systemctl restart nix-daemon.service",
            ],
        )

    def test_update_nix_changes_nothing_otherwise(self):
        """Current, newer, foreign, macOS: nothing to install, no sudo."""
        for platform, daemon, marks, status, message in (
            ("arch", "2.40.1", (), 0, "the locked release"),
            ("arch", "2.41.0", (), 0, "never downgraded"),
            ("arch", "2.34.8", ("foreign",), 2, "pacman -Syu"),
            ("darwin", "2.34.8", (), 0, "nix-darwin owns"),
        ):
            with self.subTest(platform=platform, daemon=daemon, marks=marks):
                result = self.update_nix(platform, daemon, *marks)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertFalse(
                    any(line.startswith("sudo") for line in self.commands())
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
            result.stderr.index(f"Nix {self.nix_version}"),
            result.stderr.index("sudo -n"),
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
