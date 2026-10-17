# VS Code Sync

`vscode-sync` lets VS Code Insiders share VS Code Stable's extensions, settings,
keybindings, snippets and MCP servers. Where both editions use the same build of an
extension, Insiders' folder becomes a symlink to Stable's, so the extension is
downloaded, updated and stored once. Insiders' user files become links to Stable's.

It is a manual tool for macOS and Linux. Home Manager installs the command; no switch,
hook or health check runs it.

## Commands

| Command | Effect |
| --- | --- |
| `vscode-sync status` | Show what is shared, what is due and what a change would meet. Touches no file. |
| `vscode-sync check` | The same report; exit status 1 when anything is due or needs attention. |
| `vscode-sync setup` | Link what Insiders can share, fix the extension lists and repair what is broken. |
| `vscode-sync remove` | Give Insiders its own copy of every shared folder and user file. |
| `vscode-sync update` | Share what is due, update Stable's extensions with `code`, let Insiders follow, update Insiders' own with `code-insiders`, share again and run `clean`. |
| `vscode-sync clean` | Move older builds that no profile lists into the quarantine. |

`status` and `check` accept `--json`. Every changing command accepts `--dry-run`
(report only, exit status 1 if the run would change something) and `--yes` (do not
ask). `update` also accepts `--skip-clean`, and `clean` accepts
`--edition stable|insiders|both` (default `both`). Exit status 0 is success, 1 means
something is due, 2 is a usage error and 3 any other error, including a download
that failed after everything else was applied.

On a host without Insiders, `status` says so and `update` only updates and cleans
Stable; without `code-insiders` on `PATH`, Insiders still follows Stable but its own
extensions are not updated.

Without Nix the entry script runs directly with Python 3.10 or newer from a repository
checkout, which reads the terminal style from `home/shells/terminal-style`:
`python3 vscode_sync.py status`.

## What Is Shared

Sharing follows Insiders' own extension lists, one per profile: an extension is shared
only where an Insiders profile already lists it, and nothing is installed into
Insiders that it did not have. Each Insiders entry is matched with the build Stable
uses, taken from the Stable profile of the same name and otherwise from the newest
build any Stable profile lists. Stable must still list that folder, and the folder must
not be marked for deletion in Stable's `.obsolete`.

- The same build: Insiders' folder becomes a link to Stable's.
- A newer build in Stable: the entry follows it and the link is made.
- A newer build in Insiders' own folder: Insiders keeps it; it is never downgraded.
- `anthropic.claude-code` and `github.copilot`, with every extension of their families
  such as `github.copilot-chat`, are never shared: they follow each edition's own
  release train. A link to Stable's copy is replaced by a copy.

Every Insiders entry names its folder inside Insiders' extensions directory, even when
that folder is a link. An entry that named Stable's folder would let Insiders delete
it when uninstalling or updating the extension; `setup` rewrites such entries.

`settings.json`, `keybindings.json`, `snippets` and `mcp.json` in Insiders' user
directory become links to Stable's.

## Repairs

`setup`, `update` and `remove` repair what they find instead of leaving it to be
fixed by hand:

- **A folder that is gone**, or a link to a Stable folder that is gone: the entry
  moves to the newest build Insiders still has of that extension. `remove` first
  copies Stable's build when Stable may share it. Without one, the build is
  downloaded again with `code-insiders`, the version the entry named first and the
  latest one of the same channel next. VS Code's command line refuses to reinstall an
  extension a profile still lists, so the download goes into a scratch directory with
  its own user data and is then adopted; no profile is touched by the download itself.
- **A link to a folder Stable no longer lists** becomes Insiders' own copy before
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
  reported and left alone. A link no Insiders profile lists any more is removed.
- Every run plans its changes from a read-only snapshot first and prints them. A
  change needs a yes on a terminal (Gum when the output is styled) or `--yes`.
- Nothing changes while either edition runs or while another run holds the lock.
- Before the first change, every extension list and deletion list of both editions
  and Insiders' own user files are backed up.
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
| `host` | Platform, editions and the locations derived from them. |
| `versions` | Extension version precedence. |
| `inventory` | Extension folders, read without following links. |
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
