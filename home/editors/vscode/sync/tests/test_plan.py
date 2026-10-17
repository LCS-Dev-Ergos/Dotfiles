"""Planning: what setup, remove and clean decide for each case."""

import json
import os
import unittest

from core.plan import (
    Action,
    ItemStatus,
    LinkFolder,
    LinkItem,
    Plan,
    Quarantine,
    RestoreFolder,
    RestoreItem,
    UnlinkFolder,
    WriteFile,
    plan_clean,
    plan_remove,
    plan_setup,
)
from tests.support import INSIDERS, STABLE, Machine


def actions(plan: Plan) -> dict[str, Action]:
    """Each decision's action, by the folder the entry names."""
    return {decision.folder: decision.action for decision in plan.decisions}


def kinds(plan: Plan) -> list[str]:
    """The kind and subject of each operation, in order."""
    found: list[str] = []
    for operation in plan.operations:
        subject = getattr(operation, "name", None) or operation.path.name
        found.append(f"{type(operation).__name__} {subject}")
    return found


class SetupTests(unittest.TestCase):
    """How setup treats each kind of Insiders entry."""

    def setUp(self) -> None:
        """A machine where Stable has one extension in its default profile."""
        self.machine = Machine(self)
        self.folder = self.machine.extension(STABLE, "pub.tool", "1.0.0")
        self.machine.manifest(STABLE, [self.folder])

    def test_the_same_build_becomes_a_link(self) -> None:
        """Insiders' own copy of Stable's build is replaced by a link."""
        self.machine.extension(INSIDERS, "pub.tool", "1.0.0")
        self.machine.manifest(INSIDERS, [self.folder])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(actions(plan), {self.folder: Action.LINK})
        self.assertEqual(kinds(plan), [f"LinkFolder {self.folder}"])

    def test_a_missing_folder_is_linked(self) -> None:
        """An entry whose folder is gone gets Stable's."""
        self.machine.manifest(INSIDERS, [self.folder])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(actions(plan), {self.folder: Action.LINK})

    def test_an_older_build_follows_stable(self) -> None:
        """The entry moves to Stable's build; the old link is removed."""
        old = self.machine.extension(STABLE, "pub.tool", "0.9.0")
        self.machine.link(old)
        entry = self.machine.entry(
            INSIDERS, old, metadata={"pinned": True, "targetPlatform": "x"}
        )
        stable_entry = self.machine.entry(
            STABLE, self.folder, metadata={"targetPlatform": "undefined"}
        )
        self.machine.manifest(STABLE, [stable_entry])
        self.machine.manifest(INSIDERS, [entry])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(actions(plan), {old: Action.REBIND})
        self.assertEqual(
            kinds(plan),
            [
                "WriteFile extensions.json",
                f"LinkFolder {self.folder}",
                f"UnlinkFolder {old}",
            ],
        )
        write = plan.operations[0]
        assert isinstance(write, WriteFile)
        rebound = json.loads(write.data)[0]
        located = self.machine.root(INSIDERS) / self.folder
        self.assertEqual(rebound["relativeLocation"], self.folder)
        self.assertEqual(rebound["location"]["path"], str(located))
        self.assertEqual(rebound["version"], "1.0.0")
        self.assertEqual(
            rebound["metadata"],
            {"pinned": True, "targetPlatform": "undefined"},
        )

    def test_a_newer_build_of_insiders_is_kept(self) -> None:
        """Stable never downgrades a build Insiders installed itself."""
        newer = self.machine.extension(INSIDERS, "pub.tool", "2.0.0")
        self.machine.manifest(INSIDERS, [newer])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(actions(plan), {newer: Action.NATIVE})
        self.assertFalse(plan.changed)

    def test_excluded_extensions_keep_their_own_copy(self) -> None:
        """A link to Stable's Copilot is replaced by a copy of it."""
        copilot = self.machine.extension(STABLE, "github.copilot", "1.0.0")
        self.machine.manifest(STABLE, [self.folder, copilot])
        self.machine.link(copilot)
        native = self.machine.extension(INSIDERS, "github.copilot-chat", "2.0")
        self.machine.manifest(INSIDERS, [copilot, native])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(
            actions(plan), {copilot: Action.RESTORE, native: Action.NATIVE}
        )
        self.assertEqual(kinds(plan), [f"RestoreFolder {copilot}"])

    def test_foreign_links_are_left_alone(self) -> None:
        """A link this tool did not make is reported, never replaced."""
        elsewhere = self.machine.home / "checkout"
        elsewhere.mkdir()
        (self.machine.root(INSIDERS) / self.folder).symlink_to(elsewhere)
        self.machine.manifest(INSIDERS, [self.folder])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(actions(plan), {self.folder: Action.FOREIGN})
        self.assertFalse(plan.changed)

    def test_entries_never_point_into_stables_directory(self) -> None:
        """An entry naming Stable's folder is moved to Insiders' own path.

        VS Code deletes an obsolete extension at its entry's location, so an
        Insiders entry naming Stable's folder could delete it from Stable.
        """
        self.machine.link(self.folder)
        entry = self.machine.entry(INSIDERS, self.folder, root=STABLE)
        self.machine.manifest(INSIDERS, [entry])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(actions(plan), {self.folder: Action.RELOCATE})
        write = plan.operations[0]
        assert isinstance(write, WriteFile)
        location = json.loads(write.data)[0]["location"]["path"]
        self.assertEqual(
            location, str(self.machine.root(INSIDERS) / self.folder)
        )

    def test_the_same_profile_decides_the_build(self) -> None:
        """A Stable profile's older build wins over the newest one."""
        newer = self.machine.extension(STABLE, "pub.tool", "2.0.0")
        self.machine.manifest(STABLE, [newer])
        self.machine.manifest(STABLE, [self.folder], profile="Work")
        self.machine.manifest(INSIDERS, [self.folder], profile="Work")
        self.machine.manifest(INSIDERS, [self.folder], profile="Other")
        plan = plan_setup(self.machine.snapshot())
        chosen = {d.scope: d.target for d in plan.decisions}
        self.assertEqual(chosen, {"Work": self.folder, "Other": newer})

    def test_folders_stable_drops_are_not_shared(self) -> None:
        """Unlisted and obsolete Stable folders are never linked to."""
        unlisted = self.machine.extension(STABLE, "pub.unlisted", "1.0.0")
        doomed = self.machine.extension(STABLE, "pub.doomed", "1.0.0")
        self.machine.manifest(STABLE, [self.folder, doomed])
        self.machine.obsolete(STABLE, doomed)
        self.machine.manifest(INSIDERS, [unlisted, doomed])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(
            actions(plan),
            {unlisted: Action.MISSING, doomed: Action.MISSING},
        )
        self.assertEqual(plan.problems, 2)

    def test_unlisted_links_are_removed_but_not_other_folders(self) -> None:
        """A stale extension link goes; a shared non-extension one stays."""
        stale = self.machine.extension(STABLE, "pub.stale", "1.0.0")
        (self.machine.root(STABLE) / "pub.analyzers").mkdir()
        self.machine.link(stale)
        self.machine.link("pub.analyzers")
        self.machine.manifest(INSIDERS, [])
        plan = plan_setup(self.machine.snapshot())
        self.assertEqual(kinds(plan), [f"UnlinkFolder {stale}"])
        self.assertEqual(
            [finding.subject for finding in plan.findings], ["pub.analyzers"]
        )

    def test_shared_folders_leave_the_deletion_list(self) -> None:
        """VS Code must not delete a link the plan relies on."""
        self.machine.manifest(INSIDERS, [self.folder])
        self.machine.obsolete(INSIDERS, self.folder, "pub.other-1.0.0")
        plan = plan_setup(self.machine.snapshot())
        write = plan.operations[-1]
        assert isinstance(write, WriteFile)
        self.assertEqual(json.loads(write.data), {"pub.other-1.0.0": True})

    def test_user_files(self) -> None:
        """Own and missing files are linked; others are only reported."""
        stable_dir = self.machine.host.user_dir(STABLE)
        insiders_dir = self.machine.host.user_dir(INSIDERS)
        for name in ("settings.json", "keybindings.json", "mcp.json"):
            self.machine.user_file(STABLE, name, "{}")
        (stable_dir / "snippets").mkdir()
        self.machine.user_file(INSIDERS, "settings.json", '{"own": 1}')
        (insiders_dir / "keybindings.json").symlink_to(
            self.machine.home / "elsewhere.json"
        )
        (insiders_dir / "mcp.json").symlink_to(stable_dir / "mcp.json")
        (stable_dir / "mcp.json").unlink()
        plan = plan_setup(self.machine.snapshot())
        statuses = {item.name: item.status for item in plan.items}
        self.assertEqual(
            statuses,
            {
                "settings.json": ItemStatus.INDEPENDENT,
                "keybindings.json": ItemStatus.FOREIGN,
                "snippets": ItemStatus.MISSING,
                "mcp.json": ItemStatus.BROKEN,
            },
        )
        linked = [
            op.name for op in plan.operations if isinstance(op, LinkItem)
        ]
        self.assertEqual(linked, ["settings.json", "snippets"])
        self.assertEqual(plan.problems, 1)

    def test_insiders_without_a_user_directory_is_left_alone(self) -> None:
        """Nothing is created for an Insiders that never ran."""
        self.machine.user_file(STABLE, "settings.json", "{}")
        os.rmdir(self.machine.host.user_dir(INSIDERS))
        plan = plan_setup(self.machine.snapshot())
        self.assertFalse(plan.changed)

    def test_setup_settles(self) -> None:
        """After setup, setup has nothing left to do."""
        old = self.machine.extension(INSIDERS, "pub.tool", "0.5.0")
        self.machine.extension(INSIDERS, "pub.tool", "1.0.0")
        self.machine.manifest(INSIDERS, [old])
        self.machine.manifest(INSIDERS, [self.folder], profile="Work")
        self.machine.user_file(STABLE, "settings.json", "{}")
        self.machine.setup()
        after = plan_setup(self.machine.snapshot())
        self.assertFalse(after.changed, after.operations)
        shared = self.machine.root(INSIDERS) / self.folder
        self.assertTrue(shared.is_symlink())
        self.assertEqual(
            self.machine.read_manifest(INSIDERS)[0]["relativeLocation"],
            self.folder,
        )


class RemoveTests(unittest.TestCase):
    """How remove gives Insiders its own copies."""

    def test_remove_copies_what_is_shared(self) -> None:
        """Links become copies; entries and user files follow."""
        machine = Machine(self)
        folder = machine.extension(STABLE, "pub.tool", "1.0.0")
        machine.manifest(STABLE, [folder])
        machine.manifest(INSIDERS, [folder])
        machine.user_file(STABLE, "settings.json", '{"a": 1}')
        machine.setup()
        plan = plan_remove(machine.snapshot())
        self.assertEqual(
            sorted(type(op).__name__ for op in plan.operations),
            ["RestoreFolder", "RestoreItem"],
        )
        machine.apply(plan)
        copy = machine.root(INSIDERS) / folder
        self.assertFalse(copy.is_symlink())
        self.assertTrue((copy / "package.json").is_file())
        settings = machine.host.user_dir(INSIDERS) / "settings.json"
        self.assertFalse(settings.is_symlink())
        self.assertEqual(settings.read_text(), '{"a": 1}')
        self.assertFalse(plan_remove(machine.snapshot()).changed)

    def test_remove_leaves_foreign_links(self) -> None:
        """Links this tool did not make stay links.

        A link of the same name as a Stable folder used to be replaced by a
        copy of that folder; a user file link was replaced by Stable's file.
        """
        machine = Machine(self)
        folder = machine.extension(STABLE, "pub.tool", "1.0.0")
        machine.manifest(STABLE, [folder])
        elsewhere = machine.home / "checkout"
        elsewhere.mkdir()
        (machine.root(INSIDERS) / folder).symlink_to(elsewhere)
        machine.manifest(INSIDERS, [folder])
        machine.user_file(STABLE, "settings.json", "{}")
        own = machine.home / "insiders.json"
        own.write_text("{}")
        settings = machine.host.user_dir(INSIDERS) / "settings.json"
        settings.symlink_to(own)
        plan = plan_remove(machine.snapshot())
        self.assertFalse(plan.changed, plan.operations)

    def test_remove_points_entries_at_insiders_folders(self) -> None:
        """An entry naming Stable's folder is moved to Insiders' own copy."""
        machine = Machine(self)
        folder = machine.extension(STABLE, "pub.tool", "1.0.0")
        machine.manifest(STABLE, [folder])
        machine.link(folder)
        machine.manifest(
            INSIDERS, [machine.entry(INSIDERS, folder, root=STABLE)]
        )
        plan = plan_remove(machine.snapshot())
        self.assertTrue(
            any(isinstance(op, RestoreFolder) for op in plan.operations)
        )
        machine.apply(plan)
        path = machine.read_manifest(INSIDERS)[0]["location"]
        assert isinstance(path, dict)
        self.assertEqual(path["path"], str(machine.root(INSIDERS) / folder))

    def test_broken_user_file_links_are_removed(self) -> None:
        """A link to a Stable file that is gone is removed."""
        machine = Machine(self)
        stable_file = machine.user_file(STABLE, "mcp.json", "{}")
        target = machine.host.user_dir(INSIDERS) / "mcp.json"
        target.symlink_to(stable_file)
        stable_file.unlink()
        plan = plan_remove(machine.snapshot())
        self.assertEqual(kinds(plan), ["UnlinkItem mcp.json"])
        self.assertFalse(
            any(isinstance(op, RestoreItem) for op in plan.operations)
        )


class CleanTests(unittest.TestCase):
    """Which duplicates clean quarantines."""

    def test_unused_older_builds_go(self) -> None:
        """Only the newest build and the listed ones stay."""
        machine = Machine(self)
        names = [
            machine.extension(STABLE, "pub.tool", version)
            for version in ("1.0.0", "1.1.0", "1.2.0", "2.0.0")
        ]
        machine.manifest(STABLE, [names[1]])
        machine.manifest(STABLE, [names[0]], profile="Work")
        plan = plan_clean(machine.snapshot(), [STABLE])
        self.assertEqual(kinds(plan), [f"Quarantine {names[2]}"])

    def test_folders_insiders_links_to_stay(self) -> None:
        """Stable keeps what Insiders shares, listed by Stable or not."""
        machine = Machine(self)
        old = machine.extension(STABLE, "pub.tool", "1.0.0")
        new = machine.extension(STABLE, "pub.tool", "2.0.0")
        machine.manifest(STABLE, [new])
        machine.link(old)
        machine.manifest(INSIDERS, [old])
        plan = plan_clean(machine.snapshot(), [STABLE, INSIDERS])
        self.assertFalse(plan.changed, plan.operations)

    def test_platforms_and_unknown_folders_are_separate(self) -> None:
        """Builds for different platforms are no duplicates; strangers stay."""
        machine = Machine(self)
        machine.extension(STABLE, "pub.tool", "1.0.0", "darwin-arm64")
        machine.extension(STABLE, "pub.tool", "1.1.0", "linux-x64")
        stranger = machine.root(STABLE) / "pub.tool-0.1.0"
        stranger.mkdir()
        (stranger / "package.json").write_text("{}")
        plan = plan_clean(machine.snapshot(), [STABLE])
        self.assertFalse(plan.changed, plan.operations)

    def test_only_the_named_edition_is_cleaned(self) -> None:
        """``--edition`` limits the plan to that directory."""
        machine = Machine(self)
        for edition in (STABLE, INSIDERS):
            machine.extension(edition, "pub.tool", "1.0.0")
            machine.extension(edition, "pub.tool", "2.0.0")
        plan = plan_clean(machine.snapshot(), [INSIDERS])
        editions = {
            op.edition for op in plan.operations if isinstance(op, Quarantine)
        }
        self.assertEqual(editions, {INSIDERS})


class OperationTests(unittest.TestCase):
    """Operations carry what applying them needs."""

    def test_link_targets_are_stables_folders(self) -> None:
        """A planned link points at Stable's folder of the same name."""
        machine = Machine(self)
        folder = machine.extension(STABLE, "pub.tool", "1.0.0")
        machine.manifest(STABLE, [folder])
        machine.manifest(INSIDERS, [folder])
        (link,) = plan_setup(machine.snapshot()).operations
        assert isinstance(link, LinkFolder)
        self.assertEqual(link.target, machine.root(STABLE) / folder)
        self.assertEqual(link.path, machine.root(INSIDERS) / folder)

    def test_unlink_needs_a_link(self) -> None:
        """Only symlinks are ever planned for removal."""
        machine = Machine(self)
        machine.extension(INSIDERS, "pub.stale", "1.0.0")
        machine.manifest(INSIDERS, [])
        plan = plan_setup(machine.snapshot())
        self.assertFalse(
            any(isinstance(op, UnlinkFolder) for op in plan.operations)
        )


if __name__ == "__main__":
    unittest.main()
