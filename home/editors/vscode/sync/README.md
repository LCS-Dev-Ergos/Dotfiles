# VS Code Sync

`vscode-sync` lets the other VS Code installations of a host share the extensions of
VS Code Stable: VS Code Insiders, and VS Code Server, which a remote client (Remote -
SSH, Remote - Tunnels) installs on the host it connects to. Where a consumer uses the
same build of an extension as Stable, its folder becomes a symlink to Stable's, so the
extension is downloaded, updated and stored once. Insiders also shares Stable's
settings, keybindings, snippets and MCP servers.

It is a manual tool for macOS and Linux. Home Manager installs the command; no switch,
hook or health check runs it.

## Commands

| Command | Effect |
| --- | --- |
| `vscode-sync status` | Show what is shared, what is due and what a change would meet. Touches no file. |
| `vscode-sync check` | The same report; exit status 1 when anything is due or needs attention. |
| `vscode-sync setup` | Link what each consumer can share, fix the extension lists and repair what is broken. |
| `vscode-sync remove` | Give each consumer its own copy of every shared folder and user file. |
| `vscode-sync update` | Share what is due, update Stable's extensions with `code`, let the consumers follow, update each consumer's own with its command line, share again and run `clean`. |
| `vscode-sync clean` | Move older builds that no profile lists into the quarantine. |

`status`, `check`, `setup`, `remove` and `update` work on every consumer installed on
the host; `--target insiders|server|server-insiders`, repeatable, picks some. A
changing command shows the plans of all of them, asks once, backs up once and applies
each plan in a transaction of its own. `status` and `check` accept `--json`, which
prints one report per consumer as a JSON array. Every changing command accepts
`--dry-run` (report only, exit status 1 if the run would change something) and
`--yes` (do not ask). `update` also accepts `--skip-clean`, and `clean` accepts
`--edition all|stable|insiders|server|server-insiders` (default `all`, every
extensions directory on the host). Exit status 0 is success, 1 means something is
due, 2 is a usage error and 3 any other error, including a download that failed
after everything else was applied.

On a host without any consumer, `status` says Insiders is not installed and `update`
only updates and cleans Stable. A consumer without its command line still follows
Stable, but its own extensions are not updated.

Without Nix the entry script runs directly with Python 3.10 or newer from a repository
checkout, which reads the terminal style from `home/shells/terminal-style`:
`python3 vscode_sync.py status`.

## What Is Shared

Sharing follows each consumer's own extension lists, one per profile: an extension is
shared only where one of its profiles already lists it, and nothing is installed into
a consumer that it did not have. Each entry is matched with the build Stable
uses, taken from the Stable profile of the same name and otherwise from the newest
build any Stable profile lists. Stable must still list that folder, and the folder must
not be marked for deletion in Stable's `.obsolete`.

- The same build: the consumer's folder becomes a link to Stable's.
- A newer build in Stable: the entry follows it and the link is made.
- A newer build in the consumer's own folder: it is kept; a consumer is never
  downgraded.
- `anthropic.claude-code` and `github.copilot`, with every extension of their families
  such as `github.copilot-chat`, are never shared: they follow each edition's own
  release train. A link to Stable's copy is replaced by a copy.

Every entry names its folder inside the consumer's extensions directory, even when
that folder is a link. An entry that named Stable's folder would let the consumer delete
it when uninstalling or updating the extension; `setup` rewrites such entries.

`settings.json`, `keybindings.json`, `snippets` and `mcp.json` in Insiders' user
directory become links to Stable's.

## VS Code Server

A client installs VS Code Server below `~/.vscode-server` (Stable clients) or
`~/.vscode-server-insiders` (Insiders clients), on macOS and Linux alike: extensions in
`extensions`, profiles in `data/User`, and one directory per server build in
`cli/servers/<Quality>-<commit>/server` (Remote - Tunnels and recent Remote - SSH) or
`bin/<commit>` (older Remote - SSH). Its extension lists follow the same model as a
desktop edition's, so it shares Stable's builds the same way, with three differences:

- **The server's version limits what is shared.** The server build follows the
  version of the client, not of the host's Stable. A Stable build is shared only if its
  `engines.vscode` allows the newest server build installed; otherwise the server keeps
  its own. A requirement with a date suffix, such as `^1.106.0-20251020`, is only
  taken as met from the next minor version on. A server without any build installed is
  left alone: what runs on it is unknown until a client connects again.
- **Its own command line does the rest.** Downloads for repairs and the update of the
  server's own builds use `bin/code-server` of the newest server build, which picks
  builds for the server's version and platform.
- **Only extensions are shared.** A server's settings come from the client.

A server runs while a client is connected, and nothing changes then. Its processes
are the programs of a server build; the tunnel service next to them is not counted.

## Repairs

`setup`, `update` and `remove` repair what they find instead of leaving it to be
fixed by hand:

- **A folder that is gone**, or a link to a Stable folder that is gone: the entry
  moves to the newest build the consumer still has of that extension. `remove` first
  copies Stable's build when Stable may share it. Without one, the build is
  downloaded again with the consumer's command line, the version the entry named
  first and the latest one of the same channel next. VS Code's command line refuses
  to reinstall an extension a profile still lists, so the download goes into a
  scratch directory with its own data directory and is then adopted; no profile is
  touched by the download itself.
- **A link to a folder Stable no longer lists** becomes the consumer's own copy before
  Stable deletes the folder.
- **A user file link to a Stable file that is gone** is removed.
- **An interrupted run** is undone by the next changing run, from its journal.

A download that fails leaves its entries as they were, the rest of the run is still
applied, and the run ends with exit status 3; the next run tries again.

## Guarantees

- Stable is only changed by VS Code's own `code` command during `update` and by
  `clean`, which moves unused duplicates out of the extensions directory.
- A link counts as the tool's when it points at a folder directly inside Stable's
  extensions directory. Only such links are replaced or removed; any other link is
  reported and left alone. A link no profile of the consumer lists any more is removed.
- Every run plans its changes from a read-only snapshot first and prints them. A
  change needs a yes on a terminal (Gum when the output is styled) or `--yes`.
- Nothing changes while Stable or a consumer the run works on runs, or while another
  run holds the lock.
- Before the first change, every extension list and deletion list of Stable and the
  consumers, and Insiders' own user files, are backed up.
- Changes are applied as a transaction. Before each step, a record that can undo it is
  flushed to the run's journal, and whatever the step replaces is moved into the run's
  workspace. A failure undoes every step, newest first; afterwards the plan is worked
  out again, and a run that would still change something is rolled back too.
- Undoing checks the filesystem before touching it, so it is correct whether a step
  completed, stopped half way or never began. A file that something else rewrote
  after the run is left as it is, and an original whose place was taken since is moved
  into the quarantine; the report names both.
- Extension lists and `.obsolete` are replaced atomically, and only if they did not
  change since they were read; a symlinked file stays a link.
- An entry whose identifier is not `publisher.name`, or whose folder is not a plain
  name inside the extensions directory, is kept but never acted on, so nothing read
  from a list reaches a command line as an option or a path outside the directory.
- A journal line that names a path the step could not have touched, such as a
  relative path or a copy outside the workspace, is refused rather than undone.

## State Directory

Everything the tool keeps lives below `$XDG_STATE_HOME/vscode-sync` (by default
`~/.local/state/vscode-sync`, on macOS too), readable by its owner only:

| Path | Content |
| --- | --- |
| `lock` | Held for the whole of a changing run. |
| `runs/` | One workspace per running change: `journal.jsonl` and what the run moved aside. A successful run removes it; the next run undoes and removes one an interruption left. |
| `backups/` | What a run may change, copied before it changes anything; the newest 5 runs are kept, and a file that did not change since the previous backup is a hard link, not another copy. |
| `downloads/` | Builds being downloaded for a repair; removed when the run ends, or by the next one. |
| `quarantine/` | Folders `clean` moved aside, by edition, and originals a recovery could not put back; the newest 5 runs are kept. |

VS Code's own `state.vscdb` is not backed up: the tool never writes it, and VS Code
keeps its own `state.vscdb.backup` next to it.

The earlier Zsh implementation kept its backups in `~/.local/share/vscode-sync-backups`.
This tool never reads or removes that directory; delete it once nothing in it is needed.

## Layout

`vscode_sync.py` is the entry point; the implementation is the `core` package next to
it, one concern per module:

| Module | Concern |
| --- | --- |
| `host` | Platform, editions (desktop and server) and the locations derived from them. |
| `versions` | Extension version precedence and `engines.vscode` requirements. |
| `inventory` | Extension folders, read without following links, and installed server builds. |
| `jsondata` | Narrowing of parsed JSON. |
| `manifest` | Extension lists, profiles and `.obsolete`. |
| `plan` | The changes and repairs of a run, worked out from a snapshot; writes nothing. |
| `storage` | The state directory, backups, atomic writes, moves and retention. |
| `transaction` | Applying a plan, its journal, undoing it and recovering, and the quarantine. |
| `safety` | Lock, running editions and confirmation. |
| `update` | VS Code's own `--update-extensions` and `--install-extension`. |
| `report` | Terminal and JSON output. |
| `cli` | Argument parsing, the order of a run and exit status. |

## Tests

`nix build .#vscode-sync -L` runs the unit tests in `tests/` as part of the build and
checks that the installed command reports the package version. The tests build
temporary homes with fake editions and fake VS Code command lines and never read the
real home directory. Without Nix, from this directory:
`python3 -m unittest discover -s tests -t .`.

`tests/test_style.py` enforces the source conventions, tests included: every module,
class and function has a docstring, lines fit 80 columns, and the only comments are
section banners (title on the left, dashes up to exactly column 80) and `noqa` markers.
The repository check runner (`scripts/checks/run-all.sh`) lints and format-checks the
sources with Ruff.
