"""The ``blog`` command line: status, sync, build and publish.

Exit status: 0 on success, 1 when a step fails, 2 for a usage error or an
invalid configuration, and 130 when interrupted.
"""

import argparse
import fcntl
import os
import sys
from collections.abc import Generator, Mapping, Sequence
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

import terminal_style as ui
from terminal_style import Cell, Column, Row

from . import PROG, __version__, config, content, repository
from .config import Config, ToolError
from .content import Plan, plural
from .output import name, say, show

_DESCRIPTION = (
    "Publish a Hugo blog written in an Obsidian vault: copy the posts, and "
    "the images they show, from the vault into the site, build the site to "
    "check it, then commit the posts and images and push them. The hosting "
    "builds and deploys the site on push. The configuration file names the "
    "site and the vault's folders."
)

_EPILOG = f"""\
Examples:
  {PROG} status
  {PROG} sync --dry-run
  {PROG} publish
  {PROG} publish --no-build --message "Fix a typo"

Run {PROG} COMMAND --help for a command's options.
"""

_TONES = {"add": "ok", "update": "pending", "remove": "warn"}


# Parser -----------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    """The subcommands and their options."""
    parser = ui.ArgumentParser(
        prog=PROG,
        description=_DESCRIPTION,
        epilog=_EPILOG,
        version=f"{PROG} {__version__}",
    )
    commands = parser.add_subparsers(
        dest="command", metavar="COMMAND", title="Commands", required=True
    )
    status = _command(
        commands,
        "status",
        "Show the settings, the tools and what a publish would change",
    )
    _config(status)
    sync = _command(
        commands, "sync", "Copy the posts and their images into the site"
    )
    _config(sync)
    _dry_run(sync)
    check = _command(
        commands, "build", "Build the site into a temporary folder to check it"
    )
    _config(check)
    publish = _command(
        commands,
        "publish",
        "Sync, build, commit the posts and images, and push them",
    )
    _config(publish)
    _dry_run(publish)
    publish.add_argument(
        "--no-build",
        dest="build",
        action="store_false",
        help="Skip the check build; the hosting still builds the site",
    )
    publish.add_argument(
        "-m",
        "--message",
        metavar="TEXT",
        help="The commit message (default: the date and what changed)",
    )
    return parser


def _command(commands, name_: str, text: str) -> argparse.ArgumentParser:
    """A subcommand whose help and description are the same sentence."""
    return commands.add_parser(name_, help=text, description=f"{text}.")


def _config(parser: argparse.ArgumentParser) -> None:
    """--config."""
    parser.add_argument(
        "--config",
        type=Path,
        metavar="FILE",
        help="The settings (default: $XDG_CONFIG_HOME/blog/config.toml)",
    )


def _dry_run(parser: argparse.ArgumentParser) -> None:
    """--dry-run."""
    parser.add_argument(
        "-n",
        "--dry-run",
        action="store_true",
        help="Show what would change without writing anything",
    )


# Running ----------------------------------------------------------------------


def main(
    argv: Sequence[str] | None = None,
    environ: Mapping[str, str] | None = None,
    style: ui.Style | None = None,
) -> int:
    """Run the command line; the exit status."""
    args = build_parser().parse_args(argv)
    env = dict(os.environ if environ is None else environ)
    style = style or ui.Style.detect()
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(errors="backslashreplace")
    handler = _HANDLERS[args.command]
    try:
        return handler(args, env, style)
    except ToolError as error:
        say(style, "error", str(error))
        return error.status
    except OSError as error:
        place = f"{error.filename}: " if error.filename else ""
        say(style, "error", f"{place}{error.strerror or error}")
        return 1
    except KeyboardInterrupt:
        say(style, "error", "Interrupted; every file is whole, old or new")
        return 130


def _settings(args: argparse.Namespace, env: Mapping[str, str]) -> Config:
    """The configuration a command names, or the default one."""
    return config.load(args.config or config.default_path(env))


@contextmanager
def _locked(env: Mapping[str, str]) -> Generator[None]:
    """Hold the lock that keeps two syncs from writing the site at once.

    The kernel releases it when the process ends, so a crash leaves no
    stale lock behind.

    Raises:
        ToolError: If another sync or publish holds it.
    """
    folder = config.state_path(env)
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (folder / "lock").open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ToolError(
                "Another blog sync or publish is running"
            ) from error
        yield


def _status(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Show the settings, the tools, the repository and pending changes."""
    path = args.config or config.default_path(env)
    settings = config.load(path)
    fields: list[tuple[str, Cell | str]] = [
        ("Settings", Cell(str(path), path=True)),
        ("Site", _folder(settings.site)),
        ("Posts", _folder(settings.posts)),
        ("Images", _folder(settings.images)),
        ("Publishes", f"{settings.branch} to {settings.remote}"),
        ("Hugo", repository.hugo_version(env)),
    ]
    try:
        repo = repository.toplevel(settings.site, env)
    except ToolError as error:
        fields.append(("Repository", Cell(str(error), ui.TONES["error"])))
    else:
        fields.append(("Repository", Cell(str(repo), path=True)))
        fields.append(("Branch", repository.branch(repo, env) or "detached"))
        waiting = repository.ahead(repo, env)
        if waiting is not None:
            fields.append(("Not pushed", plural(waiting, "commit")))
        paths = _managed(settings, repo)
        uncommitted = repository.pending(repo, paths, env)
        fields.append(("Uncommitted", plural(uncommitted, "file")))
    show(ui.card(style, PROG, fields))
    print()
    try:
        result = content.plan(settings)
    except ToolError as error:
        show(ui.callout(style, "error", str(error)))
        return 1
    show(_changes(result, style))
    return 1 if result.problems else 0


def _folder(path: Path) -> Cell:
    """A configured folder, in red when it does not exist."""
    if path.is_dir():
        return Cell(str(path), path=True)
    return Cell(f"{path} (missing)", ui.TONES["error"], path=True)


def _changes(result: Plan, style: ui.Style) -> list[str]:
    """What a sync would do, its problems and what it leaves out."""
    lines = ui.section(
        style, "Changes", f"{plural(result.posts, 'post')} in the vault"
    )
    if result.changes:
        rows = [
            Row(
                [change.kind, f"{change.area}/{change.path}"],
                _TONES[change.kind],
            )
            for change in result.changes
        ]
        columns = [Column("Change"), Column("File", shrink=20)]
        lines += ui.table(style, columns, rows)
    else:
        lines.append(_quiet(style, "The site matches the vault"))
    if result.problems:
        title = f"{plural(len(result.problems), 'problem')} block a sync"
        lines += ["", *ui.callout(style, "error", title, result.problems)]
    if result.skipped:
        title = "Links and special files in the vault are never published"
        lines += ["", *ui.callout(style, "warn", title, result.skipped)]
    return lines


def _quiet(style: ui.Style, text: str) -> str:
    """A quiet line one indent in, under a section."""
    indent = " " * (ui.GUTTER + ui.INDENT) if style.styled else ""
    return f"{indent}{style.paint(ui.MUTED, ui.sanitize(text))}"


def _managed(settings: Config, repo: Path) -> list[str]:
    """The folders blog writes, relative to the repository.

    Raises:
        ToolError: If one lies outside it.
    """
    paths = []
    for folder in (settings.content, settings.static):
        relative = os.path.relpath(folder.resolve(), repo.resolve())
        if relative == ".." or relative.startswith(f"..{os.sep}"):
            raise ToolError(f"{folder} is outside the repository {repo}")
        paths.append(relative)
    return paths


def _sync(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Copy the posts and their images into the site."""
    settings = _settings(args, env)
    with _locked(env):
        result = content.plan(settings)
        show(_changes(result, style))
        if args.dry_run:
            say(style, "info", "Dry run: nothing was written")
            return 1 if result.problems else 0
        _apply(result, settings, env, style)
    return 0


def _apply(
    result: Plan, settings: Config, env: Mapping[str, str], style: ui.Style
) -> None:
    """Carry out a sync and say what it did."""
    backup = content.apply(result, settings, config.state_path(env))
    if not result.changes:
        return
    details = [_summary(result)]
    if backup is not None:
        details.append(f"replaced files kept in {name(backup, style)}")
    say(style, "ok", "Synced " + " · ".join(details))


def _summary(result: Plan) -> str:
    """``2 posts, 1 image``: what a sync changes."""
    counts = [
        (sum(change.area == area for change in result.changes), noun)
        for area, noun in (("posts", "post"), ("images", "image"))
    ]
    return ", ".join(plural(count, noun) for count, noun in counts if count)


def _build(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Build the site into a temporary folder."""
    settings = _settings(args, env)
    pages = repository.build(settings.site, env)
    say(style, "ok", f"Built {plural(pages, 'page')} into a temporary folder")
    return 0


def _publish(
    args: argparse.Namespace, env: dict[str, str], style: ui.Style
) -> int:
    """Sync, build, commit the posts and images, and push them."""
    settings = _settings(args, env)
    repo = repository.toplevel(settings.site, env)
    current = repository.branch(repo, env)
    if current != settings.branch:
        raise ToolError(
            f"{repo} is on {current or 'a detached HEAD'}; publish works on "
            f"{settings.branch}"
        )
    paths = _managed(settings, repo)
    with _locked(env):
        result = content.plan(settings)
        show(_changes(result, style))
        if args.dry_run:
            waiting = repository.ahead(repo, env)
            if waiting:
                say(style, "info", f"{plural(waiting, 'commit')} not pushed")
            say(style, "info", "Dry run: nothing was written or pushed")
            return 1 if result.problems else 0
        _apply(result, settings, env, style)
        if args.build:
            pages = repository.build(settings.site, env)
            say(style, "ok", f"Built {plural(pages, 'page')}")
        message = args.message or _message(result)
        existing = [p for p in paths if (repo / p).exists()]
        committed = repository.commit(repo, existing, message, env)
        waiting = repository.ahead(repo, env)
        if not committed and waiting == 0:
            say(style, "info", "Nothing to publish: the site is up to date")
            return 0
        if committed:
            say(style, "ok", f"Committed: {message}")
        repository.push(repo, settings.remote, settings.branch, env)
    target = f"{settings.remote}/{settings.branch}"
    if waiting:
        say(style, "ok", f"Pushed {plural(waiting, 'commit')} to {target}")
    else:
        say(style, "ok", f"Pushed {target}")
    return 0


def _message(result: Plan) -> str:
    """The default commit message: the date and what changed."""
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    summary = _summary(result) or "earlier site changes"
    return f"Blog update {stamp}: {summary}."


_HANDLERS = {
    "status": _status,
    "sync": _sync,
    "build": _build,
    "publish": _publish,
}
