# VS Code Host Settings

`vscode-host-settings` keeps the host-bound values of VS Code's user `settings.json`
correct on the machine it runs on. One settings file is shared between macOS, Linux and
Windows, but values such as the location of `clangd`, `cmake` or a JDK are only valid
where they were written. The tool resolves them for the current machine and writes
them back.

It is a manual tool. Home Manager installs the command; no switch, hook or health
check runs it.

## Commands

| Command | Effect |
| --- | --- |
| `vscode-host-settings resolve` | Print what every managed key resolves to here. Touches no file. |
| `vscode-host-settings apply --dry-run` | Report what `apply` would change. Exit status 1 if anything would, 3 on an error. |
| `vscode-host-settings apply` | Write the resolved values; the backup taken for the run is removed on success. |

`apply` accepts `--settings FILE` (repeatable), `--edition insiders`, `--diff` and
`--dry-run`. Without `--settings` the default user settings file of the platform is
used (`~/Library/Application Support/Code/User`, `$XDG_CONFIG_HOME/Code/User` or
`%APPDATA%\Code\User`). Two names for the same file, such as an Insiders symlink, are
processed once. Usage errors exit with status 2.

On a machine without Nix the entry script runs directly with Python 3.10 or newer and
nothing else: `python3 vscode_host_settings.py apply --dry-run`.

## Layout

`vscode_host_settings.py` is the entry point; the implementation is the `core` package
next to it, one concern per module:

| Module | Concern |
| --- | --- |
| `jsonc` | Strict JSONC reader that keeps the position of every node, and structural comparison. |
| `text` | Text edits on the source and the line ending and indentation they must match. |
| `host` | Platform, user, environment and the locations derived from them. |
| `resolvers` | How each kind of value is found: executables, libraries, JDKs, paths. |
| `manifest` | What is managed and which resolver finds it. |
| `plan` | The edits of a run and their verification; writes nothing. |
| `storage` | Reading, backups and the atomic replacement of the file. |
| `report` | Terminal output. |
| `cli` | Argument parsing and exit status. |

Locations are pure paths of the host's own flavor (POSIX or Windows), so either kind
of host can be described and tested on the other; only `Host.concrete` turns one into
a path the filesystem is asked about, and it refuses a foreign flavor.

## What It Manages

The manifest is `LEAVES` and `NESTED` in `core/manifest.py`.

- **Top-level keys** whose whole value is a path: the tool locations (`clangd.path`,
  `cmake.cmakePath`, `clang-format.executable`, the shell and Nix tools,
  `C_Cpp.default.compilerPath`), `lldb.library`, the Java homes, `vsrocq.path`, the
  Godot editor and the Java shared-index cache.
- **Nested strings** inside a container that must already exist: the
  `JavaSE-21` and `JavaSE-25` runtime paths, and the `--query-driver` argument of
  `clangd.arguments`.

Tools are looked up in the Nix profiles first (per-user profile, `~/.nix-profile`,
the Nix state profile, the Home Manager gcroot) and then on absolute `PATH` entries;
the working directory is never searched. On Windows only `.exe` files count. A JDK is
the newest SDKMAN release of the wanted major version. Nothing found on disk is ever
executed.

### The clangd Driver Allow-List

`--query-driver` lets clangd run the compiler drivers named in a project's
`compile_commands.json`, so it is a security boundary, not a convenience. The
allow-list is generated from exact files in the Nix profiles and `/usr/bin`, never from
`PATH`, and a file name that could widen the match (comma or glob character) is left
out. When no driver is found, the key is reported as unresolved instead of being set
to an empty list.

Because the list differs per machine while `clangd.arguments` is synced, the shared
argument is rewritten to `--query-driver=${config:hostLocal.clangdQueryDriver}`
(clangd expands `${config:...}` in its arguments), and the per-machine list lives in
the `hostLocal.clangdQueryDriver` key. VS Code reports that key as an unknown setting;
the warning is expected.

## Guarantees

- Only the managed keys are written. Everything else in the file, comments, key order,
  indentation, line endings and a byte order mark included, stays as it was.
- A value is written only after its target was found. A tool that is missing is
  reported and its key is left alone; it is never replaced by a guess.
- The edited text is parsed again and compared with the original before anything is
  written. A difference outside the managed keys aborts the run.
- A file that is not valid JSONC, not UTF-8, larger than 8 MiB, or has duplicated or
  mistyped managed keys is refused untouched.
- The write is atomic (temporary file in the same directory, flushed, then renamed,
  and on POSIX the directory flushed too) and refused if the file changed since it was
  read. A symlink such as the Insiders one is followed, so the link stays a link. The
  file is read back afterwards; on a mismatch the original is restored.
- Before every write the previous file is copied to
  `$XDG_STATE_HOME/vscode-host-settings/backups` (`%LOCALAPPDATA%` on Windows),
  readable by its owner only. The copy exists only for the duration of the run: it is
  removed once the new file has been read back and matches. A failed run leaves it in
  place and the error names it; at most 20 such backups are kept. A backup that cannot
  be removed, a failed prune or a failure to restrict permissions is reported as a
  warning. A run that changes nothing writes nothing and makes no backup.

## Keys That Are Not In The File Yet

Keys VS Code does not sync (machine-scoped settings, and everything listed in
`settingsSync.ignoredSettings`) are absent on a freshly synced machine. The tool adds
them in one marked block at the end of the file:

```jsonc
// >>> vscode-host-settings: generated for this host, refresh with `vscode-host-settings apply` >>>
"clangd.path": "/home/user/.nix-profile/bin/clangd",
// <<< vscode-host-settings <<<
```

The block is owned by the tool and rewritten on each `apply`; a key in it whose target
disappears is removed. A key that already exists elsewhere in the file is updated where
it is.

Every managed top-level key is also appended to `settingsSync.ignoredSettings`, so
Settings Sync stops carrying one machine's paths to the others. An existing
`-key` entry in that list is respected: the tool reports it and leaves the key synced.

## Host-Bound Values It Does Not Manage

`apply` ends its report with a list of strings that still name a user home or profile
directory and are not in the manifest. They are reported, not edited, because each
lives in a setting that is shared between machines and whose consumer cannot be
pointed at a per-machine key. Writing a different absolute path on each machine would
make Settings Sync flip the value back and forth.

## Tests

`nix build .#vscode-host-settings -L` runs the unit tests in `tests/` as part of the
build and checks that the installed command reports the package version; the tests use
temporary directories and hand-built hosts and never read the real home directory.
Without Nix, from this directory: `python3 -m unittest discover -s tests -t .`.

`tests/test_style.py` enforces the source conventions, tests included: every module,
class and function has a docstring, lines fit 80 columns, and the only comments are section
banners (title on the left, dashes up to exactly column 80) and `noqa` markers. The
repository check runner (`scripts/checks/run-all.sh`) lints and format-checks the
sources with Ruff.
