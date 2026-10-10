#!/usr/bin/env python3
"""Offline tests for the runtime baseline updater (scripts/updates).

Upstream responses are recorded fixtures; declarations are temporary copies
evaluated by the real `nix eval`. Nothing here touches the network.
"""

import contextlib
import copy
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/updates"))

from update_runtime_baseline import cli, declarations, model  # noqa: E402
from update_runtime_baseline import upstream as transport  # noqa: E402
from update_runtime_baseline.resolvers import (  # noqa: E402
    RESOLVERS,
    installers,
    sources,
)

BASELINE = {
    "defaults": {"node": "26.10.0", "python": "3.14.7", "dotnet": "10.0.401"},
    "node": {"versions": ["24.21.0", "26.10.0"]},
    "python": {"version": "3.14.7"},
    "ocaml": {"versions": ["5.4.1", "5.5.1"]},
    "nativeToolchains": {
        "rust": {"version": "1.98.1"},
        "haskell": {
            "version": "9.14.1",
            "cabal": "3.16.1.0",
            "hls": "2.14.0.0",
        },
        "jvm": {"version": "21.0.12.1", "candidate": "21.0.12+1.1-tem"},
        "dotnet": {"version": "10.0.401"},
    },
}


class FakeUpstream:
    """Recorded responses by URL; anything unrecorded fails the test."""

    def __init__(self, responses=None, existing=(), redirects=None):
        self.responses = responses or {}
        self.existing = set(existing)
        self.redirects = redirects or {}

    def fetch(self, url, **kwargs):
        if url not in self.responses:
            raise AssertionError(f"unrecorded source: {url}")
        value = self.responses[url]
        if isinstance(value, Exception):
            raise value
        return value if isinstance(value, bytes) else value.encode()

    def json(self, url, **kwargs):
        value = self.responses.get(url)
        if value is None:
            raise AssertionError(f"unrecorded source: {url}")
        return value

    def text(self, url, **kwargs):
        return self.fetch(url).decode()

    def github(self, path):
        return self.json("https://api.github.com/" + path)

    def yaml(self, url):
        return self.json(url)

    def exists(self, url):
        return url in self.existing

    def redirect(self, url):
        return self.redirects.get(url)


def kinds(findings):
    return [(f.name, f.kind, f.available) for f in findings]


class Classification(unittest.TestCase):
    def test_patch_line_and_current(self):
        found = model.classify(
            "julia", "julia", "1.12.6", {"1.12.6", "1.12.7", "1.13.1"}, 2
        )
        self.assertEqual(
            kinds(found),
            [("julia", "update", "1.12.7"), ("julia", "line", "1.13.1")],
        )
        self.assertEqual(
            kinds(model.classify("julia", "julia", "1.12.7", {"1.12.7"}, 2)),
            [("julia", "current", "")],
        )

    def test_uninstallable_newest_falls_back_and_stays_pending(self):
        found = model.classify(
            "python",
            "python",
            "3.14.7",
            {"3.14.8", "3.14.9"},
            2,
            lambda v: None if v == "3.14.8" else "no definition",
        )
        self.assertEqual(
            kinds(found),
            [("python", "update", "3.14.8"), ("python", "pending", "3.14.9")],
        )
        self.assertIn("3.14.9: no definition", found[1].note)

    def test_manual_lines_carry_no_rewrite(self):
        found = model.classify(
            "python", "python", "3.14.7", {"3.15.0"}, 2, edits=lambda v: [v]
        )
        self.assertEqual(kinds(found), [("python", "line", "3.15.0")])
        self.assertFalse(found[0].edits)
        self.assertIn("by hand", found[0].note)

    def test_rolling_tools_have_no_lines_at_depth_zero(self):
        found = model.classify("conda", "conda", "26.7.2", {"27.1.0"}, 0)
        self.assertEqual(kinds(found), [("conda", "update", "27.1.0")])

    def test_only_the_newest_declared_line_reports_lines(self):
        found = model.classify(
            "node", "node 24", "24.21.0", {"26.11.1", "28.0.0"}, 1, lines=False
        )
        self.assertEqual(kinds(found), [("node 24", "current", "")])

    def test_edits_are_built_only_on_demand(self):
        built = []
        found = model.classify(
            "rust",
            "rust",
            "1.98.1",
            {"1.99.0"},
            1,
            edits=lambda v: built.append(v) or ["edit"],
        )
        self.assertEqual(built, [])
        self.assertEqual(found[0].edits(), ["edit"])
        self.assertEqual(built, ["1.99.0"])


class Resolvers(unittest.TestCase):
    def test_node_ignores_releases_without_both_platforms(self):
        upstream = FakeUpstream(
            {
                "https://nodejs.org/dist/index.json": [
                    {"version": "v28.0.0", "files": ["linux-x64"]},
                    {
                        "version": "v26.11.1",
                        "files": ["osx-arm64-tar", "linux-x64"],
                    },
                    {
                        "version": "v24.21.0",
                        "files": ["osx-arm64-tar", "linux-x64"],
                    },
                ]
            }
        )
        found = RESOLVERS["node"](upstream, BASELINE, {})
        self.assertEqual(
            kinds(found),
            [("node 24", "current", ""), ("node 26", "update", "26.11.1")],
        )
        (edit,) = found[1].edits()
        self.assertEqual((edit.old, edit.new), ('"26.10.0"', '"26.11.1"'))
        self.assertEqual(edit.scopes, ("node.versions", "defaults.node"))

    def test_python_waits_for_a_pyenv_definition(self):
        raw = (
            "https://raw.githubusercontent.com/pyenv/pyenv/v2.8.9/plugins/"
            "python-build/share/python-build/"
        )
        upstream = FakeUpstream(
            {
                "https://www.python.org/api/v2/downloads/release/"
                "?is_published=true&pre_release=false": [
                    {"name": "Python 3.14.8"},
                    {"name": "Python 3.14.9"},
                    {"name": "Python 3.15.0b1"},
                    {"name": "Python 2.7.18"},
                ],
                "https://api.github.com/repos/pyenv/pyenv/releases/latest": {
                    "tag_name": "v2.8.9"
                },
            },
            existing={raw + "3.14.8"},
        )
        found = RESOLVERS["python"](upstream, BASELINE, {})
        self.assertEqual(
            kinds(found),
            [("python", "update", "3.14.8"), ("python", "pending", "3.14.9")],
        )

    def adoptium(self, release_name, openjdk_version):
        return [
            {
                "release_name": release_name,
                "version": {"openjdk_version": openjdk_version},
            }
        ]

    def jvm_upstream(self, broker_target, lts=21):
        responses: dict = {
            f"{sources.ADOPTIUM}/info/available_releases": {
                "most_recent_lts": lts
            }
        }
        for os_name, architecture in (("mac", "aarch64"), ("linux", "x64")):
            responses[
                f"{sources.ADOPTIUM}/assets/latest/21/hotspot?architecture="
                f"{architecture}&image_type=jdk&os={os_name}&vendor=eclipse"
            ] = self.adoptium("jdk-21.0.13+11", "21.0.13+11-LTS")
        # The platform lists disagree, as SDKMAN's do.
        responses[
            f"{sources.SDKMAN_LISTS}/java/darwinarm64/versions/list?installed="
        ] = " Temurin | | 21.0.0.0+35 | 21.0.0.0+35-tem\n"
        responses[
            f"{sources.SDKMAN_LISTS}/java/linuxx64/versions/list?installed="
        ] = " Temurin | | 21.0.13 | 21.0.13-tem\n"
        redirects = {}
        for platform in sources.SDKMAN_PLATFORMS:
            redirects[
                f"{sources.SDKMAN_BROKER}/java/21.0.0.0+35-tem/{platform}"
            ] = (
                "https://github.com/adoptium/temurin21-binaries/releases/"
                "download/jdk-21%2B35/x.tar.gz"
            )
            redirects[
                f"{sources.SDKMAN_BROKER}/java/21.0.13-tem/{platform}"
            ] = broker_target
        return FakeUpstream(responses, redirects=redirects)

    def test_jvm_candidate_is_the_one_the_broker_serves(self):
        upstream = self.jvm_upstream(
            "https://github.com/adoptium/temurin21-binaries/releases/"
            "download/jdk-21.0.13%2B11/x.tar.gz"
        )
        (finding,) = RESOLVERS["jvm"](upstream, BASELINE, {})
        self.assertEqual(
            (finding.kind, finding.available, finding.note),
            ("update", "21.0.13", "SDKMAN 21.0.13-tem"),
        )
        version, candidate = finding.edits()
        self.assertEqual(candidate.new, '"21.0.13-tem"')
        self.assertEqual(version.new, '"21.0.13"')

    def test_jvm_is_pending_until_sdkman_serves_the_release(self):
        upstream = self.jvm_upstream("https://elsewhere.invalid/old.tar.gz")
        (finding,) = RESOLVERS["jvm"](upstream, BASELINE, {})
        self.assertEqual(finding.kind, "pending")
        self.assertIn("jdk-21.0.13+11", finding.note)

    def dotnet_upstream(self, sdks, channels):
        def channel(versions):
            return {
                "releases": [
                    {
                        "sdks": [
                            {
                                "version": v,
                                "files": [
                                    {"rid": "osx-arm64"},
                                    {"rid": "linux-x64"},
                                ],
                            }
                            for v in versions
                        ]
                    }
                ]
            }

        base = (
            "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/"
        )
        responses = {
            base + "releases-index.json": {
                "releases-index": [
                    {"channel-version": c, "support-phase": phase}
                    for c, phase in channels.items()
                ]
            }
        }
        for name, versions in sdks.items():
            responses[base + f"{name}/releases.json"] = channel(versions)
        return FakeUpstream(responses)

    def test_dotnet_patches_within_the_feature_band(self):
        upstream = self.dotnet_upstream(
            {"10.0": ["10.0.401", "10.0.402", "10.0.500", "10.0.113"]},
            {"10.0": "active", "11.0": "go-live"},
        )
        found = RESOLVERS["dotnet"](upstream, BASELINE, {})
        self.assertEqual(
            kinds(found),
            [
                ("dotnet 10.0.4xx", "update", "10.0.402"),
                ("dotnet 10.0.4xx", "line", "10.0.500"),
            ],
        )

    def test_dotnet_reports_an_active_newer_channel(self):
        upstream = self.dotnet_upstream(
            {"10.0": ["10.0.401"], "11.0": ["11.0.100", "11.0.100-rc.2"]},
            {"10.0": "active", "11.0": "active"},
        )
        found = RESOLVERS["dotnet"](upstream, BASELINE, {})
        self.assertEqual(
            kinds(found), [("dotnet 10.0.4xx", "line", "11.0.100")]
        )
        self.assertIn(".NET 11.0", found[0].note)

    def test_haskell_follows_the_channel_and_both_bindists(self):
        both = {
            "viArch": {"A_ARM64": {"Darwin": {}}, "A_64": {"Linux_Debian": {}}}
        }
        linux_only = {"viArch": {"A_64": {"Linux_Debian": {}}}}
        metadata = {
            "ghcupDownloads": {
                "GHC": {
                    "toolVersions": {
                        "9.14.1": both,
                        "9.14.2": linux_only,
                        "9.16.1": both,
                    }
                },
                "Cabal": {
                    "toolVersions": {
                        "3.16.1.0": both,
                        "3.18.0.0": dict(both, viTags=["Recommended"]),
                    }
                },
                "HLS": {
                    "toolVersions": {
                        "2.14.0.0": dict(both, viTags=["Recommended"]),
                        "2.15.0.0": dict(both, viTags=["Latest"]),
                    }
                },
            }
        }
        upstream = FakeUpstream({sources.GHCUP_METADATA: metadata})
        found = RESOLVERS["haskell"](upstream, BASELINE, {})
        self.assertEqual(
            kinds(found),
            [
                ("haskell ghc", "pending", "9.14.2"),
                ("haskell ghc", "line", "9.16.1"),
                ("haskell cabal", "update", "3.18.0.0"),
                ("haskell hls", "current", ""),
            ],
        )


class Installers(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="runtime-baseline-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        environment = patch.dict(
            os.environ, {"XDG_CACHE_HOME": str(self.root)}
        )
        environment.start()
        self.addCleanup(environment.stop)
        self.managers_file = self.root / "native-managers.nix"
        shutil.copy(ROOT / "home/dev/native-managers.nix", self.managers_file)
        self.managers_file.chmod(0o600)
        moved = patch.object(declarations, "MANAGERS", self.managers_file)
        moved.start()
        self.addCleanup(moved.stop)
        self.managers = declarations.evaluate(self.managers_file)
        self.rust = self.managers["bootstrap"]["aarch64-darwin"]["installers"][
            "rust"
        ]

    def upstream(self, data):
        return FakeUpstream({self.rust["url"]: data})

    def test_drift_is_saved_for_review_and_accepted_only_after_it(self):
        changed = b"#!/bin/sh\necho changed\n"
        digest = hashlib.sha256(changed).hexdigest()
        findings = [
            f
            for f in installers.resolve(
                FakeUpstream(
                    {
                        installer["url"]: b"unchanged"
                        for installer in installers.mutable_installers(
                            self.managers
                        ).values()
                    }
                    | {self.rust["url"]: changed}
                ),
                {},
                self.managers,
            )
            if f.name == "installer rust"
        ]
        self.assertEqual(findings[0].kind, "drift")
        saved = installers.review_path("rust", digest)
        self.assertEqual(saved.read_bytes(), changed)
        # Upstream changed again after the review: refuse.
        with self.assertRaisesRegex(model.SourceError, "nobody reviewed"):
            installers.accept(
                ["rust"], self.upstream(b"newer still\n"), self.managers
            )
        self.assertIn(self.rust["sha256"], self.managers_file.read_text())
        with contextlib.redirect_stdout(io.StringIO()):
            installers.accept(["rust"], self.upstream(changed), self.managers)
        after = declarations.evaluate(self.managers_file)["bootstrap"]
        for platform in declarations.PLATFORMS:
            self.assertEqual(
                after[platform]["installers"]["rust"]["sha256"], digest
            )

    def test_unknown_installer_is_refused(self):
        with self.assertRaisesRegex(model.SourceError, "choose from"):
            installers.accept(["scala"], FakeUpstream(), self.managers)


def copy_declarations(test):
    """A temporary copy of the baseline and what it imports; its path."""
    temporary = tempfile.TemporaryDirectory(prefix="runtime-baseline-")
    test.addCleanup(temporary.cleanup)
    tree = Path(temporary.name)
    for relative in (
        "home/dev/runtime-baseline.nix",
        "home/dev/bootstrap/validate.nix",
        "home/dev/bootstrap/platforms.nix",
    ):
        (tree / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / relative, tree / relative)
    return tree / "home/dev/runtime-baseline.nix"


class Rewrite(unittest.TestCase):
    """Exact replacement against copies of the real declarations."""

    def setUp(self):
        self.baseline = copy_declarations(self)
        self.original = self.baseline.read_text()
        self.node = declarations.evaluate(self.baseline)["defaults"]["node"]

    def edit(self, new, *scopes):
        return model.Edit(self.baseline, f'"{self.node}"', f'"{new}"', scopes)

    def test_only_the_intended_values_change(self):
        declarations.apply_edits(
            [self.edit("99.0.0", "node.versions", "defaults.node")]
        )
        after = declarations.evaluate(self.baseline)
        self.assertEqual(after["defaults"]["node"], "99.0.0")
        self.assertIn("99.0.0", after["node"]["versions"])

    def test_a_stray_change_restores_the_file(self):
        with self.assertRaisesRegex(model.SourceError, "defaults.node"):
            declarations.apply_edits([self.edit("99.0.0", "node.versions")])
        self.assertEqual(self.baseline.read_text(), self.original)

    def test_an_invalid_result_restores_the_file(self):
        # validate.nix rejects a Node default that names no declared release.
        edit = model.Edit(
            self.baseline,
            f'node = "{self.node}"',
            'node = "1.0.0"',
            ("defaults.node",),
        )
        with self.assertRaisesRegex(model.SourceError, "does not evaluate"):
            declarations.apply_edits([edit])
        self.assertEqual(self.baseline.read_text(), self.original)

    def test_a_missing_value_writes_nothing(self):
        with self.assertRaisesRegex(model.SourceError, "not found"):
            declarations.apply_edits(
                [model.Edit(self.baseline, '"0.0.0"', '"1"', ("x",))]
            )
        self.assertEqual(self.baseline.read_text(), self.original)


class Retirement(unittest.TestCase):
    """The `retired` block, which --apply extends with replaced releases."""

    def setUp(self):
        self.baseline = copy_declarations(self)
        moved = patch.object(declarations, "BASELINE", self.baseline)
        moved.start()
        self.addCleanup(moved.stop)
        self.declared = declarations.evaluate(self.baseline)

    def move(self, path, old, new, *scopes):
        finding = model.Finding(
            path.split(".")[0],
            path,
            old,
            new,
            model.Kind.UPDATE,
            retires=((path, old),),
        )
        edits = [declarations.baseline_edit(old, new, path, *scopes)]
        return finding, edits

    def apply(self, *moves):
        findings = [finding for finding, _ in moves]
        edits = [edit for _, group in moves for edit in group]
        edits.append(declarations.retirement(self.declared, findings))
        declarations.apply_edits(edits)
        nixfmt = shutil.which("nixfmt")
        if nixfmt:
            check = subprocess.run(
                [nixfmt, "--check", str(self.baseline)], capture_output=True
            )
            self.assertEqual(check.returncode, 0, check.stderr)
        return declarations.evaluate(self.baseline)

    def test_the_block_renders_as_written(self):
        match = declarations.RETIRED.search(self.baseline.read_text())
        assert match
        indent = match["indent"]
        rendered = declarations.render(self.declared["retired"], indent)
        self.assertEqual(f"{indent}retired = {rendered};\n", match.group())

    def test_replaced_releases_are_retired_at_their_paths(self):
        node = self.declared["defaults"]["node"]
        hls = self.declared["nativeToolchains"]["haskell"]["hls"]
        after = self.apply(
            self.move("node.versions", node, "99.0.0", "defaults.node"),
            self.move("nativeToolchains.haskell.hls", hls, "9.0.0.0"),
        )
        retired = after["retired"]
        self.assertIn(node, retired["node"]["versions"])
        self.assertEqual(retired["nativeToolchains"]["haskell"]["hls"], [hls])
        self.assertEqual(after["defaults"]["node"], "99.0.0")

    def test_a_release_declared_again_leaves_the_list(self):
        current = self.declared["python"]["version"]
        (old,) = self.declared["retired"]["python"]["version"]
        after = self.apply(
            self.move("python.version", current, old, "defaults.python")
        )
        self.assertEqual(after["retired"]["python"]["version"], [current])

    def test_a_retired_value_matching_a_moved_pin_survives(self):
        # The rewrite of the pin also matches inside the block; the block's
        # rendering, applied last, puts the retired value back.
        rust = self.declared["nativeToolchains"]["rust"]["version"]
        text = self.baseline.read_text()
        (node,) = self.declared["retired"]["node"]["versions"]
        self.baseline.write_text(
            text.replace(
                f'node.versions = [ "{node}" ];',
                f'node.versions = [ "{rust}" ];',
            )
        )
        self.declared = declarations.evaluate(self.baseline)
        after = self.apply(
            self.move(
                "nativeToolchains.rust.version",
                rust,
                "99.0.0",
                "defaults.rust",
            )
        )
        self.assertEqual(after["retired"]["node"]["versions"], [rust])
        self.assertIn(
            rust, after["retired"]["nativeToolchains"]["rust"]["version"]
        )

    def test_nothing_retired_without_a_replacement(self):
        self.assertIsNone(
            declarations.retirement(
                self.declared, [model.Finding("rust", "rust", "1.0.0")]
            )
        )


class Entry(unittest.TestCase):
    def run_main(self, argv, upstream, baseline=BASELINE):
        output = io.StringIO()
        with (
            patch.object(cli, "Upstream", lambda token: upstream),
            patch.object(
                cli,
                "evaluate",
                lambda path: (
                    copy.deepcopy(baseline)
                    if path == declarations.BASELINE
                    else {}
                ),
            ),
            contextlib.redirect_stdout(output),
        ):
            code = cli.main(argv)
        return code, output.getvalue()

    def rust(self, version):
        return FakeUpstream(
            {
                "https://static.rust-lang.org/dist/channel-rust-stable.toml": (
                    f'[pkg.rust]\nversion = "{version} (abc 2026-01-01)"\n'
                )
            }
        )

    def test_check_exits_one_only_when_something_is_actionable(self):
        code, output = self.run_main(["--check", "rust"], self.rust("1.99.0"))
        self.assertEqual(code, 1)
        self.assertIn("update", output)
        code, _ = self.run_main(["--check", "rust"], self.rust("1.98.1"))
        self.assertEqual(code, 0)

    def test_source_errors_exit_two(self):
        unreachable = FakeUpstream(
            {
                "https://static.rust-lang.org/dist/channel-rust-stable.toml": (
                    model.SourceError("connection refused")
                )
            }
        )
        code, output = self.run_main(["--check", "rust"], unreachable)
        self.assertEqual(code, 2)
        self.assertIn("connection refused", output)

    def test_markdown_lists_only_findings(self):
        code, output = self.run_main(
            ["--check", "--markdown", "rust"], self.rust("1.99.0")
        )
        self.assertIn("| rust | 1.98.1 | 1.99.0 | update |", output)

    def test_usage_errors(self):
        for argv in (
            ["--check", "--line", "rust"],
            ["--apply", "--line", "python"],
            ["--check", "cobol"],
        ):
            with (
                self.subTest(argv=argv),
                self.assertRaises(SystemExit) as raised,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                cli.main(argv)
            self.assertEqual(raised.exception.code, 2)


class Transport(unittest.TestCase):
    def test_the_token_goes_to_the_github_api_only(self):
        upstream = transport.Upstream("secret")
        api = upstream.request("https://api.github.com/repos/x/y")
        raw = upstream.request("https://raw.githubusercontent.com/x/y")
        self.assertEqual(
            api.unredirected_hdrs.get("Authorization"), "Bearer secret"
        )
        self.assertNotIn("Authorization", api.headers)
        self.assertNotIn("Authorization", raw.unredirected_hdrs)
        self.assertNotIn("Authorization", raw.headers)

    def test_plain_http_is_refused(self):
        with self.assertRaisesRegex(model.SourceError, "non-HTTPS"):
            transport.Upstream().request("http://example.com/")


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    unittest.main(verbosity=1)
