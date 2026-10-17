"""toolchain: compiler identity, info, SDK headers and selection."""

import json
import shutil
import subprocess
import unittest
from pathlib import Path

from core.compilers import Kind, command, identify, inspect, names
from core.host import Platform
from core.sdk import HEADERS, survey
from core.selection import State, Switch, Toolchain, candidates, find, switch
from tests.support import TOOLS, Machine

CLANG = 'echo "clang version 23.1.3 (https://github.com/llvm/llvm-project)"'
APPLE = 'echo "Apple clang version 17.0.0 (clang-1700.0.13.3)"'
GNU = 'echo "gcc (GCC) 16.2.0"; echo "Copyright (C) Free Software Foundation"'


class CompilerTests(unittest.TestCase):
    """Reading CC and identifying compilers."""

    def setUp(self) -> None:
        """An empty machine."""
        self.machine = Machine(self)

    def test_cc_is_split_like_a_shell_without_evaluation(self) -> None:
        """Quotes group words; substitutions stay text."""
        self.assertEqual(
            command("ccache 'my clang' -O2"), ("ccache", "my clang", "-O2")
        )
        self.assertEqual(command("$(rm -rf x)"), ("$(rm", "-rf", "x)"))
        self.assertEqual(command("'unbalanced"), ("'unbalanced",))

    def test_an_executable_path_with_spaces_is_one_word(self) -> None:
        """A path that exists as a whole is not split."""
        tool = self.machine.tool("my cc", CLANG)
        self.assertEqual(command(str(tool)), (str(tool),))

    def test_families_and_vendors(self) -> None:
        """The banner names the family; the path and banner the vendor."""
        host = self.machine.host
        apple = self.machine.tool("gcc", APPLE)
        gnu = self.machine.tool("g++", GNU)
        apple_id = identify(host, (str(apple),), 5)
        self.assertEqual(
            (apple_id.kind, apple_id.vendor), (Kind.CLANG, "Apple")
        )
        gnu_id = identify(host, (str(gnu),), 5)
        self.assertEqual(gnu_id.kind, Kind.GCC)
        self.assertTrue(gnu_id.gnu)
        self.assertEqual(gnu_id.version, "16.2.0")
        broken = self.machine.tool("cc", "exit 1")
        self.assertFalse(identify(host, (str(broken),), 5).ran)

    def test_versioned_names_follow_the_usual_ones(self) -> None:
        """gcc-16 and clang-23 on PATH are listed, by family and version."""
        for name in ("gcc-16", "gcc-9", "clang-23", "gcc-ar-16"):
            self.machine.tool(name, GNU)
        listed = names(self.machine.host)
        self.assertEqual(listed[6:], ["gcc-9", "gcc-16", "clang-23"])

    def test_info_flags_a_masquerading_gcc(self) -> None:
        """gcc that is Apple's Clang is a warning, a missing name an error."""
        self.machine.tool("gcc", APPLE)
        entries = {e.name: e for e in inspect(self.machine.host, 5)}
        self.assertEqual(entries["gcc"].masquerade, "Clang")
        self.assertIsNone(entries["clang"].path)
        code, out, _ = self.machine.toolchain("info")
        self.assertEqual(code, 0)
        self.assertIn("Warning: resolves to Clang", out)
        self.assertIn("Not found in PATH", out)
        self.assertIn("1 compiler available; 5 missing.", out)

    def test_info_resolves_links_and_shows_overrides(self) -> None:
        """A link is followed to the real compiler; CC is listed."""
        real = self.machine.tool("clang-23", CLANG, self.machine.root / "llvm")
        (self.machine.bin / "clang").symlink_to(real)
        self.machine.env["CC"] = "clang"
        code, out, _ = self.machine.toolchain()
        self.assertEqual(code, 0)
        self.assertIn(f"{self.machine.bin / 'clang'} → {real}", out)
        self.assertIn("Environment overrides", out)


class SdkTests(unittest.TestCase):
    """Header reachability."""

    def setUp(self) -> None:
        """An active compiler that reaches zlib.h only; a system one."""
        self.machine = Machine(self)
        self.active = self.machine.tool(
            "cc", 'grep -q "<zlib.h>" "$2" || exit 1'
        )
        self.system = self.machine.tool(
            "system-cc", "exit 0", self.machine.root / "usr"
        )

    def test_divergence_is_found(self) -> None:
        """Every header but zlib.h diverges."""
        found = survey(self.machine.host, self.system)
        self.assertEqual(found.divergent, len(HEADERS) - 1)
        self.assertTrue(found.reaches[0].active)

    def test_without_a_system_compiler_nothing_diverges(self) -> None:
        """No reference, no divergence."""
        found = survey(self.machine.host, self.machine.root / "none")
        self.assertIsNone(found.system)
        self.assertEqual(found.divergent, 0)

    def test_a_cc_with_a_launcher_is_run_as_a_command(self) -> None:
        """CC with arguments reaches what its compiler reaches."""
        self.machine.tool("launcher", 'shift 0; "$@"')
        self.machine.env["CC"] = f"launcher {self.active}"
        found = survey(self.machine.host, self.system)
        self.assertTrue(found.reaches[0].active)

    def test_homebrew_hints_only_on_macos(self) -> None:
        """Linux has no Homebrew formulas to suggest."""
        found = survey(self.machine.host, self.system)
        self.assertEqual({r.hint for r in found.reaches}, {""})
        brew = self.machine.root / "brew"
        (brew / "opt" / "xz" / "include").mkdir(parents=True)
        self.machine.env["HOMEBREW_PREFIX"] = str(brew)
        self.machine.platform = Platform.MACOS
        hints = {
            r.hint for r in survey(self.machine.host, self.system).reaches
        }
        self.assertIn("brew: xz", hints)
        self.assertIn("brew install libffi", hints)


class SelectionTests(unittest.TestCase):
    """Choosing a pair and changing the shell."""

    def setUp(self) -> None:
        """An empty macOS machine."""
        self.machine = Machine(self, Platform.MACOS)

    def test_a_pair_comes_from_one_directory(self) -> None:
        """A C compiler without its C++ partner is skipped."""
        lone = self.machine.root / "lone"
        self.machine.tool("clang", CLANG, lone)
        both = self.machine.root / "both"
        self.machine.tool("clang", CLANG, both)
        self.machine.tool("clang++", CLANG, both)
        self.machine.env["PATH"] = f"{lone}:{both}"
        pair = find(self.machine.host, Toolchain.LLVM, 5)
        assert pair is not None
        self.assertEqual(
            (pair.c, pair.cxx), (both / "clang", both / "clang++")
        )

    def test_the_family_is_checked(self) -> None:
        """Apple's gcc is not GNU; versioned GNU names win in a directory."""
        self.machine.tool("gcc", APPLE)
        self.machine.tool("g++", APPLE)
        gnu = self.machine.root / "gnu"
        for name in ("gcc-15", "g++-15", "gcc-16", "g++-16", "gcc", "g++"):
            self.machine.tool(name, GNU, gnu)
        self.machine.env["PATH"] += f":{gnu}"
        pair = find(self.machine.host, Toolchain.GNU, 5)
        assert pair is not None
        self.assertEqual(pair.c, gnu / "gcc-16")
        self.assertEqual(pair.cxx, gnu / "g++-16")

    def test_linux_prefers_the_distribution(self) -> None:
        """System directories come before PATH on Linux."""
        self.machine.platform = Platform.LINUX
        found = candidates(self.machine.host, Toolchain.GNU)
        self.assertEqual(found[:2], [Path("/usr/bin"), Path("/usr/local/bin")])
        self.assertEqual(found[-1], self.machine.bin)

    def test_switch_and_back(self) -> None:
        """PATH gains only a missing directory; system restores CC/CXX."""
        llvm = self.machine.root / "llvm"
        self.machine.tool("clang", CLANG, llvm)
        self.machine.tool("clang++", CLANG, llvm)
        self.machine.env["CC"] = "/old/cc"
        host = self.machine.host
        pair = find(host, Toolchain.LLVM, 5)
        self.assertIsNone(pair)
        self.machine.env["PATH"] += f":{llvm}"
        pair = find(self.machine.host, Toolchain.LLVM, 5)
        assert pair is not None
        first = switch(self.machine.host, Toolchain.LLVM, None, pair)
        self.assertEqual(first.environment["CC"], str(llvm / "clang"))
        self.assertNotIn("PATH", first.environment)
        self.assertEqual(first.state.baseline, {"CC": "/old/cc", "CXX": None})
        back = switch(self.machine.host, Toolchain.SYSTEM, first.state, None)
        self.assertEqual(back.environment, {"CC": "/old/cc", "CXX": None})
        self.assertEqual(back.state.active, Toolchain.SYSTEM)

    def test_an_added_directory_is_removed_again(self) -> None:
        """Only the directory the switch added leaves PATH."""
        llvm = self.machine.root / "llvm"
        self.machine.tool("clang", CLANG, llvm)
        self.machine.tool("clang++", CLANG, llvm)
        self.machine.env["PATH"] = f"/usr/bin:{llvm}"
        pair = find(self.machine.host, Toolchain.LLVM, 5)
        assert pair is not None
        state = State(Toolchain.LLVM, "/added", {"CC": None})
        self.machine.env["PATH"] = f"/added:/usr/bin:{llvm}:/added"
        moved = switch(self.machine.host, Toolchain.GNU, state, pair)
        self.assertEqual(moved.environment["PATH"], f"/usr/bin:{llvm}")
        self.assertEqual(moved.state.baseline, {"CC": None})

    def test_state_round_trip_and_damage(self) -> None:
        """The state survives the shell; anything else is refused."""
        state = State(Toolchain.GNU, "/x", {"CC": "a b", "CXX": None})
        self.assertEqual(State.decode(state.encode()), state)
        for text in ("", "{", "[]", '{"version":2}', '{"version":1}'):
            self.assertIsNone(State.decode(text))
        bad = '{"version":1,"active":"gnu","baseline":{"CC":3}}'
        self.assertIsNone(State.decode(bad))

    def test_shell_code_quotes_everything(self) -> None:
        """Values are quoted; only the known names are ever set."""
        change = Switch(
            Toolchain.LLVM,
            {"CC": "/a b/'c'; rm -rf ~", "CXX": None},
            State(Toolchain.LLVM),
        )
        code = change.shell()
        self.assertIn("export CC='/a b/'\"'\"'c'\"'\"'; rm -rf ~'", code)
        self.assertIn("unset CXX", code)
        with self.assertRaises(ValueError):
            Switch(Toolchain.LLVM, {"LD_PRELOAD": "x"}, change.state).shell()

    def test_nothing_is_printed_when_no_pair_works(self) -> None:
        """A failed selection leaves the shell nothing to evaluate."""
        code, out, err = self.machine.toolchain("env", "llvm")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("No working Clang pair", err)

    @unittest.skipUnless(shutil.which("zsh"), "zsh is not installed")
    def test_zsh_evaluates_the_switch(self) -> None:
        """The printed code changes a real zsh exactly as reported."""
        llvm = self.machine.root / "llvm"
        self.machine.tool("clang", CLANG, llvm)
        self.machine.tool("clang++", CLANG, llvm)
        self.machine.env["PATH"] += f":{llvm}"
        _, code, _ = self.machine.toolchain("env", "llvm")
        script = (
            f'{code}\nprint -r -- "$CC|$TOOLCHAIN_ACTIVE|$_TOOLCHAIN_STATE"'
        )
        result = subprocess.run(
            [shutil.which("zsh") or "zsh", "-fc", script],
            capture_output=True,
            text=True,
            env={"PATH": TOOLS},
            check=True,
        )
        cc, active, state = result.stdout.strip().split("|", 2)
        self.assertEqual((cc, active), (str(llvm / "clang"), "llvm"))
        self.assertEqual(json.loads(state)["active"], "llvm")


if __name__ == "__main__":
    unittest.main()
