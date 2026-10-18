"""Copying posts and images from the vault into the site."""

import unittest

from core import config, content
from core.config import ToolError
from tests.support import Blog


class ConvertTests(unittest.TestCase):
    """Rewriting Obsidian image embeds for Hugo."""

    def test_embeds_labels_and_links(self) -> None:
        """Labels become alternative text, sizes give way to the stem."""
        cases = [
            ("![[a b.png]]", "![a b](/images/a%20b.png)"),
            ("![[c.png|Load over time]]", "![Load over time](/images/c.png)"),
            ("![[c.PNG|300]]", "![c](/images/c.PNG)"),
            ("![[c.png|300x200]]", "![c](/images/c.png)"),
            ("see [[c.png]]", "see [c](/images/c.png)"),
            ("[[Other note]], ![[note.md]]", "[[Other note]], ![[note.md]]"),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(content.convert(source)[0], expected)

    def test_names_and_refusals(self) -> None:
        """A folder or a hidden name in an embed is left as written."""
        text, names, refused = content.convert(
            "![[a.png]] ![[sub/b.png]] ![[.c.png]] ![[a.png]]"
        )
        self.assertEqual(names, ["a.png", "a.png"])
        self.assertEqual(refused, ["sub/b.png", ".c.png"])
        self.assertIn("![[sub/b.png]]", text)


class SyncTests(unittest.TestCase):
    """Planning and applying a sync."""

    def setUp(self) -> None:
        """A vault with two posts and an image."""
        self.blog = Blog(self)
        self.blog.post("first.md", "![[chart.png]]\n")
        self.blog.post("second.md")
        self.blog.image("chart.png")
        self.settings = config.load(self.blog.config)

    def sync(self) -> content.Plan:
        """Plan and apply a sync; the plan."""
        result = content.plan(self.settings)
        content.apply(result, self.settings, self.blog.state)
        return result

    def test_posts_and_images_arrive_converted(self) -> None:
        """Posts are rewritten, images copied; a second run changes nothing."""
        result = self.sync()
        self.assertEqual(result.count("add", "posts"), 2)
        self.assertEqual(result.count("add", "images"), 1)
        first = (self.settings.content / "first.md").read_text()
        self.assertIn("![chart](/images/chart.png)", first)
        self.assertEqual(
            (self.settings.static / "chart.png").read_bytes(), b"\x89PNG"
        )
        self.assertEqual(content.plan(self.settings).changes, [])

    def test_removed_posts_go_and_their_copies_stay(self) -> None:
        """A post gone from the vault goes from the site, kept in a backup."""
        self.sync()
        (self.blog.posts / "second.md").unlink()
        self.blog.post("first.md", "Changed.\n")
        (self.settings.content / ".DS_Store").write_text("finder")
        result = self.sync()
        kinds = sorted((c.kind, str(c.path)) for c in result.changes)
        self.assertEqual(
            kinds, [("remove", "second.md"), ("update", "first.md")]
        )
        self.assertFalse((self.settings.content / "second.md").exists())
        self.assertTrue((self.settings.content / ".DS_Store").exists())
        (backup,) = (self.blog.state / "backups").iterdir()
        self.assertIn("chart", (backup / "posts" / "first.md").read_text())
        self.assertTrue((backup / "posts" / "second.md").exists())

    def test_backups_are_pruned(self) -> None:
        """Only the configured number of runs is kept."""
        self.blog.write_config("backups = 2\n")
        self.settings = config.load(self.blog.config)
        self.sync()
        for number in range(4):
            self.blog.post("first.md", f"Version {number}.\n")
            self.sync()
        self.assertEqual(len(list((self.blog.state / "backups").iterdir())), 2)

    def test_a_missing_image_blocks_everything(self) -> None:
        """Nothing is written while a post shows an image the vault lacks."""
        self.blog.post("third.md", "![[gone.png]]\n")
        result = content.plan(self.settings)
        self.assertEqual(len(result.problems), 1)
        self.assertIn("gone.png, which is missing", result.problems[0])
        with self.assertRaisesRegex(ToolError, "Nothing was synced"):
            content.apply(result, self.settings, self.blog.state)
        self.assertFalse(self.settings.content.exists())

    def test_links_in_the_vault_are_never_followed(self) -> None:
        """A link to a file outside the vault is skipped and reported."""
        secret = self.blog.root / "secret.md"
        secret.write_text("private")
        (self.blog.posts / "leak.md").symlink_to(secret)
        (self.blog.images / "chart.png").unlink()
        (self.blog.images / "chart.png").symlink_to(secret)
        result = content.plan(self.settings)
        self.assertEqual(result.skipped, ["leak.md"])
        self.assertIn("chart.png is a link or not a file", result.problems)
        self.assertNotIn(
            "leak.md", [str(change.path) for change in result.changes]
        )

    def test_an_empty_vault_is_refused(self) -> None:
        """An unmounted or unsynced vault cannot empty the site."""
        self.sync()
        for post in self.blog.posts.iterdir():
            post.unlink()
        with self.assertRaisesRegex(ToolError, "refusing to empty the site"):
            content.plan(self.settings)
        self.assertEqual(len(list(self.settings.content.iterdir())), 2)

    def test_a_linked_site_folder_is_not_written_through(self) -> None:
        """A site folder that links elsewhere stops the sync."""
        outside = self.blog.root / "outside"
        outside.mkdir()
        self.blog.post("deep/inner.md")
        self.settings.content.mkdir(parents=True)
        (self.settings.content / "deep").symlink_to(outside)
        result = content.plan(self.settings)
        self.assertIn(
            "posts/deep in the site is a link out of it", result.problems
        )
        with self.assertRaises(ToolError):
            content.apply(result, self.settings, self.blog.state)
        self.assertEqual(list(outside.iterdir()), [])

    def test_overlapping_folders_are_refused(self) -> None:
        """A vault inside the site would be copied into itself."""
        self.blog.write_config()
        text = self.blog.config.read_text().replace(
            str(self.blog.posts), str(self.blog.site / "content")
        )
        self.blog.config.write_text(text)
        self.settings = config.load(self.blog.config)
        with self.assertRaisesRegex(ToolError, "overlap"):
            content.plan(self.settings)

    def test_the_site_must_be_hugo(self) -> None:
        """A wrong site folder is caught before anything is read."""
        (self.blog.site / "hugo.toml").unlink()
        with self.assertRaisesRegex(ToolError, "is not a Hugo site"):
            content.plan(self.settings)


if __name__ == "__main__":
    unittest.main()
