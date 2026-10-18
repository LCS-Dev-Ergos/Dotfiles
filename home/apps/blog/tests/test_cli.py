"""The command line: settings, status, sync, build and publish."""

import fcntl
import unittest

from core import repository
from tests.support import Blog


class SettingsTests(unittest.TestCase):
    """Reading the configuration file."""

    def setUp(self) -> None:
        """A blog to point the settings at."""
        self.blog = Blog(self)

    def test_bad_settings_are_named(self) -> None:
        """A missing file fails; a wrong setting is a usage error."""
        self.blog.config.unlink()
        status, _, err = self.blog.run("status")
        self.assertEqual(status, 1)
        self.assertIn("No configuration at", err)
        for extra, message in (
            ("colour = 1\n", "Unknown setting in"),
            ("backups = true\n", "backups in"),
            ('branch = "--force"\n', "branch in"),
        ):
            with self.subTest(extra=extra):
                self.blog.write_config(extra)
                status, _, err = self.blog.run("status")
                self.assertEqual(status, 2)
                self.assertIn(message, err)
        self.blog.config.write_text('site = "site"\nposts = "p"\nimages = "i"')
        status, _, err = self.blog.run("status")
        self.assertEqual(status, 2)
        self.assertIn("must be an absolute path", err)


class CommandTests(unittest.TestCase):
    """Status, sync and build."""

    def setUp(self) -> None:
        """A vault with one post."""
        self.blog = Blog(self)
        self.blog.post("hello.md")

    def test_status_shows_the_pending_changes(self) -> None:
        """The settings, the repository and what a sync would do."""
        status, out, _ = self.blog.run("status")
        self.assertEqual(status, 0)
        self.assertIn("hugo v0.150.0 fake", out)
        self.assertIn("Branch       main", out)
        self.assertIn("add     posts/hello.md", out)

    def test_dry_run_writes_nothing(self) -> None:
        """The plan is shown and the site is untouched."""
        status, out, _ = self.blog.run("sync", "--dry-run")
        self.assertEqual(status, 0)
        self.assertIn("Dry run: nothing was written", out)
        self.assertFalse((self.blog.site / "content" / "posts").exists())
        status, out, _ = self.blog.run("sync")
        self.assertEqual(status, 0)
        self.assertIn("Synced 1 post", out)

    def test_one_sync_at_a_time(self) -> None:
        """A held lock stops a second sync."""
        lock = self.blog.state / "blog" / "lock"
        lock.parent.mkdir(parents=True)
        with lock.open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            status, _, err = self.blog.run("sync")
        self.assertEqual(status, 1)
        self.assertIn("Another blog sync or publish is running", err)

    def test_build_reports_pages_and_errors(self) -> None:
        """Hugo's own error line explains a failed build."""
        status, out, _ = self.blog.run("build")
        self.assertEqual(status, 0)
        self.assertIn("Built 2 pages", out)
        status, _, err = self.blog.run("build", env={"FAIL_HUGO": "1"})
        self.assertEqual(status, 1)
        self.assertIn("hugo failed: ERROR render of page failed", err)


class PublishTests(unittest.TestCase):
    """Committing and pushing."""

    def setUp(self) -> None:
        """A vault with one post and an image."""
        self.blog = Blog(self)
        self.blog.post("hello.md", "![[shot.png]]\n")
        self.blog.image("shot.png")

    def test_publish_commits_only_the_site_folders(self) -> None:
        """Other staged work stays staged; the remote gets the commit."""
        notes = self.blog.repo / "notes.txt"
        notes.write_text("draft")
        self.blog.git("add", "notes.txt")
        status, out, _ = self.blog.run("publish", "-m", "Add hello")
        self.assertEqual(status, 0, out)
        self.assertIn("Pushed 1 commit to origin/main", out)
        files = self.blog.git("show", "--name-only", "--format=", "HEAD")
        self.assertEqual(
            sorted(files.split()),
            ["site/content/posts/hello.md", "site/static/images/shot.png"],
        )
        self.assertIn("A  notes.txt", self.blog.git("status", "--short"))
        remote = self.blog.git_at(self.blog.remote, "log", "-1", "--format=%s")
        self.assertEqual(remote.strip(), "Add hello")
        status, out, _ = self.blog.run("publish")
        self.assertEqual(status, 0)
        self.assertIn("Nothing to publish", out)

    def test_no_folder_commits_nothing(self) -> None:
        """An empty list of folders never becomes the whole repository."""
        (self.blog.repo / "notes.txt").write_text("draft")
        committed = repository.commit(
            self.blog.repo, [], "Nothing", self.blog.environ
        )
        self.assertFalse(committed)
        self.assertIn("?? notes.txt", self.blog.git("status", "--short"))

    def test_a_refused_push_keeps_the_commit(self) -> None:
        """The error says how to recover; the commit stays local."""
        self.blog.git("remote", "set-url", "origin", "/nonexistent/remote")
        status, _, err = self.blog.run("publish", "--no-build")
        self.assertEqual(status, 1)
        self.assertIn("the commit is kept", err)
        self.assertIn("Blog update", self.blog.git("log", "-1", "--format=%s"))

    def test_a_failed_build_publishes_nothing(self) -> None:
        """The posts are synced, but nothing is committed or pushed."""
        status, _, err = self.blog.run("publish", env={"FAIL_HUGO": "1"})
        self.assertEqual(status, 1)
        self.assertIn("hugo failed", err)
        log = self.blog.git("log", "--format=%s")
        self.assertEqual(log.split("\n")[0], "Start")

    def test_publish_without_build_or_hugo(self) -> None:
        """--no-build does not need Hugo; the message says what changed."""
        (self.blog.root / "bin" / "hugo").unlink()
        status, out, _ = self.blog.run("publish", "--no-build")
        self.assertEqual(status, 0, out)
        subject = self.blog.git("log", "-1", "--format=%s")
        self.assertRegex(subject, r"^Blog update .*: 1 post, 1 image\.$")

    def test_publish_works_on_the_configured_branch(self) -> None:
        """Another checked-out branch is refused before any change."""
        self.blog.git("switch", "--quiet", "-c", "draft")
        status, _, err = self.blog.run("publish")
        self.assertEqual(status, 1)
        self.assertIn("is on draft; publish works on main", err)
        self.assertFalse((self.blog.site / "content" / "posts").exists())


if __name__ == "__main__":
    unittest.main()
