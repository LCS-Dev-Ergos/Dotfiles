"""dev-doctor's checks, conflicts, updates and command line."""

import json
import os
import time
import unittest
from pathlib import Path
from typing import Any

import terminal_style as ui

from core.doctor import (
    Conflict,
    State,
    check,
    check_all,
    npm_conflict,
    order,
    path_conflicts,
    updates,
)
from core.host import Host, Platform
from core.registry import (
    RUNTIMES,
    Group,
    InRoot,
    OnPath,
    Run,
    Runtime,
    applicable,
)
from tests.support import Machine


def runtime(**fields: Any) -> Runtime:
    """A synthetic runtime: ``tool`` on PATH, its version from ``tool -v``."""
    values: dict[str, Any] = {
        "id": "tool",
        "label": "Tool",
        "group": Group.OTHER,
        "presence": OnPath("tool"),
        "version": Run(("tool", "-v")),
        "binary": "tool",
    }
    values.update(fields)
    return Runtime(**values)


def _never(_: Host) -> bool:
    """A session manager this shell never activated."""
    return False


def registered(identifier: str) -> Runtime:
    """The real registry's entry."""
    return next(r for r in RUNTIMES if r.id == identifier)


class CheckTests(unittest.TestCase):
    """One runtime at a time."""

    def setUp(self) -> None:
        """An empty machine."""
        self.machine = Machine(self)

    def run_check(self, subject: Runtime, timeout: float = 5):
        """Check ``subject`` on the machine."""
        return check(subject, self.machine.host, timeout)

    def test_a_working_runtime_reports_its_version(self) -> None:
        """Present, versioned and started: ok, with where it comes from."""
        self.machine.tool("tool", 'echo "tool version v1.2.3"')
        record = self.run_check(runtime())
        self.assertEqual(record.state, State.OK)
        self.assertEqual(record.active, "1.2.3")
        self.assertEqual(record.origin, "other")
        self.assertEqual(record.detail, "Runtime starts")

    def test_an_absent_runtime(self) -> None:
        """Nothing on PATH is absent, without running anything."""
        self.assertEqual(self.run_check(runtime()).state, State.ABSENT)

    def test_a_timeout_is_inconclusive(self) -> None:
        """A hanging probe is unknown, neither healthy nor broken."""
        self.machine.tool("tool", "sleep 5")
        started = time.monotonic()
        record = self.run_check(runtime(), timeout=0.5)
        self.assertLess(time.monotonic() - started, 4)
        self.assertEqual(record.state, State.UNKNOWN)
        self.assertIn("timed out", record.detail)

    def test_a_failing_runtime_is_broken(self) -> None:
        """A startup that fails names its status and binary."""
        self.machine.tool("tool", "exit 3")
        record = self.run_check(runtime())
        self.assertEqual(record.state, State.BROKEN)
        self.assertIn("exit 3", record.detail)

    def test_a_missing_managed_executable_is_broken(self) -> None:
        """A manager whose runtime proxy is gone cannot be healthy."""
        self.machine.tool("mgr")
        subject = runtime(
            presence=OnPath("mgr"), version=Run(("tool", "-v")), binary="tool"
        )
        record = self.run_check(subject)
        self.assertEqual(record.state, State.BROKEN)

    def test_no_version_output_is_inconclusive(self) -> None:
        """A runtime that prints nothing is unknown."""
        self.machine.tool("tool", "exit 0")
        record = self.run_check(runtime())
        self.assertEqual(record.state, State.UNKNOWN)
        self.assertIn("no version", record.detail)

    def test_a_manager_root_that_vanished_is_broken(self) -> None:
        """A declared root that is gone is the clearest breakage."""
        self.machine.tool("tool", "echo 1.0")
        subject = runtime(roots=("~/.tool",))
        record = self.run_check(subject)
        self.assertEqual(record.state, State.BROKEN)
        self.assertEqual(record.detail, "Root missing: ~/.tool")

    def test_the_root_variable_moves_the_first_root(self) -> None:
        """The variable replaces the first default and keeps the others."""
        self.machine.env["TOOL_HOME"] = "/elsewhere"
        subject = runtime(root_var="TOOL_HOME", roots=("~/.a", "~/.b"))
        roots = subject.resolve_roots(self.machine.host)
        self.assertEqual(roots, [Path("/elsewhere"), self.machine.home / ".b"])

    def test_an_empty_manager_does_not_start_its_shims(self) -> None:
        """No managed version means the version proxy never runs."""
        marker = self.machine.root / "started"
        root = self.machine.home / ".tool"
        root.mkdir()
        self.machine.tool("mgr", "exit 0")
        self.machine.tool("tool", f'touch "{marker}"; echo 1.0')
        subject = runtime(
            presence=OnPath("mgr"),
            roots=("~/.tool",),
            managed=Run(("mgr", "list")),
        )
        record = self.run_check(subject)
        self.assertEqual(record.state, State.UNUSED)
        self.assertFalse(marker.exists())

    def test_a_manager_shadowed_by_another_binary(self) -> None:
        """Managed versions, but PATH answers with something else."""
        root = self.machine.home / ".tool"
        (root / "bin").mkdir(parents=True)
        self.machine.tool("mgr", 'echo "* 1.0"; echo "  2.0"')
        self.machine.tool("tool", "echo 1.0")
        subject = runtime(
            presence=OnPath("mgr"),
            roots=("~/.tool",),
            managed=Run(("mgr", "list")),
        )
        record = self.run_check(subject)
        self.assertEqual(record.state, State.SHADOWED)
        self.assertIn("tool resolves to other", record.detail)

    def test_a_managed_binary_is_ok_with_its_count(self) -> None:
        """A binary inside the manager's root counts it as the winner."""
        root = self.machine.home / ".tool"
        self.machine.tool("tool", "echo 1.0", root / "bin")
        self.machine.prepend(root / "bin")
        self.machine.tool("mgr", 'echo "* 1.0"; echo "  2.0"')
        subject = runtime(
            presence=OnPath("mgr"),
            roots=("~/.tool",),
            managed=Run(("mgr", "list")),
            startup=None,
        )
        record = self.run_check(subject)
        self.assertEqual(record.state, State.OK)
        self.assertEqual(record.origin, "manager")
        self.assertEqual(record.detail, "2 managed")

    def test_an_unactivated_session_manager_is_dormant(self) -> None:
        """Not activated here: dormant, explained, and nothing started."""
        root = self.machine.home / ".tool"
        root.mkdir()
        marker = self.machine.root / "started"
        self.machine.tool("mgr", 'echo "1.0"')
        self.machine.tool("tool", f'touch "{marker}"; echo 1.0')
        subject = runtime(
            presence=OnPath("mgr"),
            version=Run(("mgr",)),
            roots=("~/.tool",),
            managed=Run(("mgr", "list")),
            activated=_never,
            startup=Run(("tool", "-v")),
        )
        record = self.run_check(subject)
        self.assertEqual(record.state, State.DORMANT)
        self.assertIn("Not activated here", record.detail)
        self.assertFalse(marker.exists())

    def test_tabs_and_newlines_never_reach_a_field(self) -> None:
        """Whatever a probe prints stays on one line."""
        self.machine.tool("tool", "printf '1.0\\tx\\n'")
        record = self.run_check(runtime(startup=None))
        self.assertNotIn("\t", record.active)

    def test_a_crashing_probe_is_unknown_not_fatal(self) -> None:
        """A check that raises is reported, and the others still run."""

        def broken(_: object) -> bool:
            """A presence check that fails."""
            raise RuntimeError("boom")

        self.machine.tool("tool", "echo 1.0")
        records = check_all(
            [runtime(id="bad", presence=broken), runtime()],
            self.machine.host,
            5,
            0,
        )
        self.assertEqual(records[0].state, State.UNKNOWN)
        self.assertIn("boom", records[0].detail)
        self.assertEqual(records[1].state, State.OK)

    def test_in_root_presence(self) -> None:
        """A file inside the root marks the runtime present."""
        root = self.machine.home / ".sdk"
        (root / "bin").mkdir(parents=True)
        subject = runtime(
            presence=InRoot("bin/init.sh"), roots=("~/.sdk",), version=None
        )
        self.assertEqual(self.run_check(subject).state, State.ABSENT)
        (root / "bin" / "init.sh").write_text("")
        self.assertEqual(self.run_check(subject).state, State.OK)

    def test_order_by_group_then_label(self) -> None:
        """Groups in report order, labels ignoring case inside each."""
        self.machine.tool("tool", "echo 1.0")
        records = [
            check(runtime(id=i, label=n, group=g), self.machine.host, 5)
            for i, n, g in (
                ("z", "zeta", Group.SYSTEMS),
                ("a", "Alpha", Group.OTHER),
                ("b", "beta", Group.SYSTEMS),
                ("p", "Platform", Group.PLATFORM),
            )
        ]
        self.assertEqual(
            [r.runtime.id for r in order(records)], ["p", "b", "z", "a"]
        )


class CompilerRowTests(unittest.TestCase):
    """The CC and CXX rows."""

    def setUp(self) -> None:
        """A machine with a compiler that echoes its arguments."""
        self.machine = Machine(self)
        self.machine.tool("clang", 'echo "clang version 23.1.3 $*"')

    def test_overrides_with_arguments_are_honoured(self) -> None:
        """A launcher and its flags are kept, quoted paths too."""
        self.machine.tool("ccache", 'shift 0; "$@"')
        self.machine.env["CC"] = "ccache clang -O2"
        record = check(registered("cc"), self.machine.host, 5)
        self.assertEqual(record.state, State.OK)
        self.assertEqual(record.active, "23.1.3")

    def test_an_invalid_override_is_broken(self) -> None:
        """A CC naming nothing is not hidden behind cc on PATH."""
        self.machine.tool("cc", 'echo "clang version 1.0"')
        self.machine.env["CC"] = "/missing/compiler"
        record = check(registered("cc"), self.machine.host, 5)
        self.assertEqual(record.state, State.BROKEN)

    def test_an_override_is_never_evaluated(self) -> None:
        """Command substitution in CC is text, not code."""
        marker = self.machine.root / "evaluated"
        self.machine.env["CC"] = f"$(touch {marker})"
        check(registered("cc"), self.machine.host, 5)
        self.assertFalse(marker.exists())

    def test_a_healthy_compiler_names_its_path(self) -> None:
        """The detail is where the compiler is."""
        self.machine.env["CC"] = str(self.machine.bin / "clang")
        record = check(registered("cc"), self.machine.host, 5)
        self.assertEqual(record.detail, str(self.machine.bin / "clang"))


class VerdictTests(unittest.TestCase):
    """Rows that judge for themselves: Nix and the toolchain check."""

    def setUp(self) -> None:
        """An empty machine."""
        self.machine = Machine(self)

    def nix(self, client: str, daemon: str | None, locked: str = "") -> State:
        """The Nix row with these releases; its detail is kept."""
        store = (
            f'echo \'{{"url":"daemon","version":"{daemon}"}}\''
            if daemon
            else "exit 1"
        )
        self.machine.tool(
            "nix",
            f'case "$*" in *"store info"*) {store} ;; '
            f'*) echo "nix (Nix) {client}" ;; esac',
        )
        if locked:
            release = self.machine.home / ".config" / "dev-doctor"
            release.mkdir(parents=True, exist_ok=True)
            (release / "nix-release").write_text(f"{locked}\n")
        record = check(registered("nix"), self.machine.host, 5)
        self.detail = record.detail
        return record.state

    def test_matching_releases_are_ok(self) -> None:
        """Client, daemon and lock agree."""
        self.assertEqual(self.nix("2.34.8", "2.34.8", "2.34.8"), State.OK)
        self.assertIn("locked 2.34.8", self.detail)

    def test_a_client_older_than_the_daemon_is_broken(self) -> None:
        """PATH prefers a stale installer copy."""
        self.assertEqual(self.nix("2.24.5", "2.34.8"), State.BROKEN)
        self.assertIn("remove the stale copy", self.detail)

    def test_a_daemon_behind_the_lock_is_broken(self) -> None:
        """The daemon missed its update; the fix is named."""
        self.assertEqual(self.nix("2.34.8", "2.30.0", "2.34.8"), State.BROKEN)
        self.assertIn("dev-bootstrap.sh --update-nix", self.detail)

    def test_an_unreachable_daemon_is_inconclusive(self) -> None:
        """Without the daemon's answer the verdict is unknown."""
        self.assertEqual(self.nix("2.34.8", None), State.UNKNOWN)

    def toolchain(self, body: str) -> tuple[State, str]:
        """The toolchain-check row with this status command."""
        self.machine.platform = Platform.MACOS
        self.machine.tool("cc-toolchain-check", body)
        record = check(registered("cctoolchain"), self.machine.host, 5)
        return record.state, record.detail

    def test_a_verified_toolchain_is_ok(self) -> None:
        """A verified toolchain names what was verified."""
        state, detail = self.toolchain('echo "verified: SDK 27.0"')
        self.assertEqual((state, detail), (State.OK, "verified: SDK 27.0"))

    def test_a_stale_verification_is_unknown(self) -> None:
        """A stale one says how to renew it."""
        state, detail = self.toolchain('echo "stale: rebuild"; exit 1')
        self.assertEqual((state, detail), (State.UNKNOWN, "stale: rebuild"))

    def test_a_check_that_cannot_run_is_broken(self) -> None:
        """Any other failure is broken."""
        state, _ = self.toolchain("exit 2")
        self.assertEqual(state, State.BROKEN)


class RegistryTests(unittest.TestCase):
    """The real registry."""

    def test_ids_are_unique_and_shaped(self) -> None:
        """Every id is unique and a plain word ``--only`` can name."""
        ids = [r.id for r in RUNTIMES]
        self.assertEqual(len(ids), len(set(ids)))
        for identifier in ids:
            self.assertRegex(identifier, r"^[a-z0-9_-]+$")

    def test_platform_rows_are_filtered(self) -> None:
        """A macOS-only row does not apply on Linux, and the reverse."""
        linux = {r.id for r in applicable(Platform.LINUX)}
        macos = {r.id for r in applicable(Platform.MACOS)}
        self.assertIn("fpc", linux - macos)
        self.assertIn("swift", macos - linux)

    def test_go_without_a_workspace(self) -> None:
        """Go is healthy without GOPATH, and the probe creates nothing."""
        machine = Machine(self)
        machine.tool("go", 'echo "go version go1.27.1 linux/amd64"')
        machine.env["GOPATH"] = str(machine.root / "missing")
        record = check(registered("go"), machine.host, 5)
        self.assertEqual((record.state, record.active), (State.OK, "1.27.1"))
        self.assertFalse((machine.root / "missing").exists())

    def test_sdkman_reads_links_without_starting_a_jvm(self) -> None:
        """Java's and Gradle's versions come from the current links."""
        machine = Machine(self)
        root = machine.home / ".sdkman"
        (root / "bin").mkdir(parents=True)
        (root / "bin" / "sdkman-init.sh").write_text("")
        java = root / "candidates" / "java"
        (java / "21.0.1").mkdir(parents=True)
        (java / "current").symlink_to(java / "21.0.1")
        machine.tool("java", 'echo "openjdk 21.0.1 2025"')
        record = check(registered("sdkman"), machine.host, 5)
        self.assertEqual(record.active, "21.0.1")
        self.assertEqual(record.state, State.SHADOWED)

    def test_rustup_may_not_install_a_toolchain(self) -> None:
        """Every probe runs with automatic toolchain installs disabled."""
        machine = Machine(self)
        (machine.home / ".rustup").mkdir()
        machine.tool("rustup", 'echo "stable-x86_64 (default)"')
        log = machine.root / "env"
        machine.tool("rustc", f'echo "$RUSTUP_AUTO_INSTALL" > "{log}"')
        check(registered("rustup"), machine.host, 5)
        self.assertEqual(log.read_text().strip(), "0")


class ConflictTests(unittest.TestCase):
    """What PATH itself gets wrong."""

    def setUp(self) -> None:
        """An empty machine."""
        self.machine = Machine(self)

    def kinds(self, binaries: list[str], managed: list[str]) -> list[str]:
        """The kinds of conflict found."""
        found = path_conflicts(self.machine.host, binaries, managed)
        return [conflict.kind for conflict in found]

    def test_stale_entries_and_empty_shims(self) -> None:
        """A missing directory and a shim directory without shims."""
        shims = self.machine.root / "mgr" / "shims"
        shims.mkdir(parents=True)
        self.machine.env["PATH"] += f":/missing/dir:{shims}"
        self.assertEqual(self.kinds([], []), ["stale entry", "empty shims"])

    def test_shims_after_a_package_manager(self) -> None:
        """Shims behind Homebrew's directory have lost their priority."""
        shims = self.machine.root / "mgr" / "shims"
        shims.mkdir(parents=True)
        (shims / "python").write_text("")
        brew = self.machine.root / "brew" / "bin"
        brew.mkdir(parents=True)
        self.machine.env["HOMEBREW_PREFIX"] = str(brew.parent)
        self.machine.env["PATH"] = f"{brew}:{shims}"
        self.assertEqual(self.kinds([], []), ["shim priority"])

    def test_a_binary_with_several_origins(self) -> None:
        """Two different copies of one binary are reported, not failed."""
        other = self.machine.root / "other"
        self.machine.tool("lang", directory=other)
        self.machine.tool("lang")
        self.machine.env["PATH"] += f":{other}"
        found = path_conflicts(self.machine.host, ["lang"], [])
        self.assertEqual([c.kind for c in found], ["shadowed binary"])
        self.assertEqual(found[0].rank, 0)
        self.assertEqual(self.kinds(["lang"], ["lang"]), [])

    def test_npm_prefix_inside_a_version_tree(self) -> None:
        """Global npm packages inside a Node version are flagged."""
        root = self.machine.home / "fnm"
        self.machine.tool("npm")
        self.machine.env["NPM_CONFIG_PREFIX"] = str(root / "node-versions/v1")
        found = npm_conflict(self.machine.host, [root], 5)
        self.assertIsNotNone(found)
        self.machine.env["NPM_CONFIG_PREFIX"] = str(self.machine.home / "g")
        self.assertIsNone(npm_conflict(self.machine.host, [root], 5))


class UpdateTests(unittest.TestCase):
    """The remote tier and its cache."""

    def setUp(self) -> None:
        """A machine with Homebrew reporting one outdated formula."""
        self.machine = Machine(self)
        self.calls = self.machine.root / "calls"
        self.machine.tool(
            "brew",
            f'echo x >> "{self.calls}"; '
            'case "$1" in outdated) echo "homebrew/core/gcc" ;; '
            '*) echo "Homebrew 5.0.0" ;; esac',
        )

    def test_outdated_formulas_and_the_cache(self) -> None:
        """Signals are cached privately and reused until refreshed."""
        found = updates(self.machine.host, refresh=False, ttl=60, timeout=5)
        self.assertEqual(found.formulas, {"gcc"})
        cache = self.machine.home / ".cache" / "dev-doctor" / "updates.json"
        self.assertEqual(os.stat(cache.parent).st_mode & 0o077, 0)
        updates(self.machine.host, refresh=False, ttl=60, timeout=5)
        self.assertEqual(len(self.calls.read_text().split()), 1)
        updates(self.machine.host, refresh=True, ttl=60, timeout=5)
        self.assertEqual(len(self.calls.read_text().split()), 2)

    def test_a_damaged_cache_is_ignored(self) -> None:
        """A cache that is not what the tool wrote is asked again."""
        cache = self.machine.home / ".cache" / "dev-doctor" / "updates.json"
        cache.parent.mkdir(parents=True)
        cache.write_text(json.dumps({"time": time.time(), "formulas": [1]}))
        found = updates(self.machine.host, refresh=False, ttl=60, timeout=5)
        self.assertEqual(found.formulas, {"gcc"})

    def test_an_outdated_formula_marks_its_runtime(self) -> None:
        """The runtime whose formula is outdated carries the update hint."""
        self.machine.tool("gfortran", 'echo "GNU Fortran (GCC) 16.2.0"')
        code, out, _ = self.machine.doctor(
            "--only", "fortran", "--updates", "--json"
        )
        manager = json.loads(out)["managers"][0]
        self.assertEqual(code, 0)
        self.assertEqual(manager["state"], "outdated")
        self.assertEqual(manager["detail"], "brew upgrade gcc")


class CommandTests(unittest.TestCase):
    """The dev-doctor command line."""

    def setUp(self) -> None:
        """A machine with one healthy runtime and one broken one."""
        self.machine = Machine(self)
        self.machine.tool("go", 'echo "go version go1.27.1"')
        self.machine.tool("zig", "exit 4")

    def test_json_is_valid_whatever_probes_print(self) -> None:
        """Control characters in a version still give valid JSON."""
        self.machine.tool("lua", "printf 'Lua 5.5\\033[0m\\r\\n'")
        code, out, _ = self.machine.doctor("--json")
        data = json.loads(out)
        states = {m["id"]: m["state"] for m in data["managers"]}
        self.assertEqual(states["go"], "ok")
        self.assertEqual(states["zig"], "broken")
        self.assertEqual(code, 2)
        self.assertNotIn("bqn", states)

    def test_all_includes_what_is_not_installed(self) -> None:
        """--all lists absent runtimes too."""
        _, out, _ = self.machine.doctor("--all", "--json")
        states = {m["id"]: m["state"] for m in json.loads(out)["managers"]}
        self.assertEqual(states["bqn"], "absent")

    def test_only_and_usage_errors(self) -> None:
        """An unknown id or option is a usage error."""
        code, out, _ = self.machine.doctor("--only", "go", "--json")
        self.assertEqual(
            [m["id"] for m in json.loads(out)["managers"]], ["go"]
        )
        self.assertEqual(code, 0)
        self.assertEqual(self.machine.doctor("--only", "nope")[0], 2)
        self.assertEqual(self.machine.doctor("--nope")[0], 2)
        self.assertEqual(self.machine.doctor("--help")[0], 0)

    def test_a_bad_setting_is_refused(self) -> None:
        """A timeout that is not a positive number stops the run."""
        self.machine.env["DEVDOCTOR_TIMEOUT"] = "soon"
        code, _, err = self.machine.doctor()
        self.assertEqual(code, 2)
        self.assertIn("DEVDOCTOR_TIMEOUT", err)

    def test_plain_report(self) -> None:
        """Masthead, one table, the tally and the hint; no escapes."""
        code, out, _ = self.machine.doctor()
        self.assertEqual(code, 2)
        self.assertIn("dev-doctor · Development Environment", out)
        self.assertIn("GROUP", out)
        self.assertIn("BROKEN", out)
        self.assertIn(
            "[ERROR] 1 ok, 1 broken; review the flagged entries.", out
        )
        self.assertIn("Run 'dev-doctor --updates'", out)
        self.assertNotIn("\033", out)

    def test_styled_report_fits_the_terminal(self) -> None:
        """No styled line is wider than the terminal, conflicts included."""
        other = self.machine.root / ("very-long-directory-name-" * 3)
        self.machine.tool("go", "echo go1.0", other)
        self.machine.env["PATH"] += f":{other}:/a/stale/entry/{'x' * 80}"
        for width in (60, 80, 120):
            _, out, _ = self.machine.doctor(styled=True, width=width)
            for line in out.splitlines():
                with self.subTest(width=width, line=line):
                    self.assertLessEqual(ui.text_width(ui.strip(line)), width)
        _, out, _ = self.machine.doctor(styled=True)
        self.assertIn("PATH conflicts", out)
        self.assertIn("●", out)

    def test_a_conflict_needing_action_raises_the_status(self) -> None:
        """A stale PATH entry makes an otherwise healthy run exit 1."""
        self.machine.tool("zig", 'echo "0.16.0"')
        self.machine.env["PATH"] += ":/missing"
        code, out, _ = self.machine.doctor("--json")
        self.assertEqual(code, 1)
        self.assertEqual(
            json.loads(out)["conflicts"][0]["kind"], "stale entry"
        )


class ConflictRankTests(unittest.TestCase):
    """How conflicts count."""

    def test_only_a_shadowed_binary_is_informational(self) -> None:
        """Every other kind asks for action."""
        self.assertEqual(Conflict("shadowed binary", "x", "").rank, 0)
        self.assertEqual(Conflict("stale entry", "x", "").rank, 1)


if __name__ == "__main__":
    unittest.main()
