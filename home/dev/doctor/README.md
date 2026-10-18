# Dev Doctor

Two read-only commands for the development environment, installed by Home
Manager on macOS and Linux:

- `dev-doctor` reports, for every runtime manager, language and tool this
  configuration sets up, whether it is installed, which version is active,
  whether it starts, where its binary comes from and what on PATH competes
  with it. `devdoctor` is an alias, the name of the earlier Zsh version.
- `toolchain` explains the C/C++ compilers (`info`), tests which SDK headers
  the active compiler reaches (`sdk`), and prints the shell code that selects
  a compiler pair for one shell (`env`), which the Zsh functions `use_llvm`,
  `use_gnu` and `use_system` evaluate.

`dev-bootstrap` provisions runtimes and verifies them in depth; `dev-doctor`
reports what the current shell resolves, quickly and without changing
anything, and `--deep` adds the bootstrap's own health check. The flake's
`llvm-darwin-toolchain` check (`cc-toolchain-check`) proves that the macOS
compilers compile, link and run; `dev-doctor` only reads its verdict.

## dev-doctor

```sh
dev-doctor                          # Every installed runtime
dev-doctor --only cc,cxx,clang,gcc  # Some, by id
dev-doctor --all --json             # Absent ones too, for programs
dev-doctor --updates                # Also ask managers for new releases
dev-doctor --deep                   # Also run dev-bootstrap verify --health
```

| Option | Effect |
| --- | --- |
| `-u`, `--updates` | Ask the managers with a native, machine-readable update check (Homebrew, once for every formula, and `rustup check`) and add an Updates section with each one's answer: what is outdated among the rows, how many other Homebrew packages are, or that it failed. A complete answer is cached; one with a failed source is asked again next time. |
| `--refresh` | Ignore the cache; implies `--updates`. |
| `--only IDS` | Check only these comma-separated ids; an unknown id is a usage error. |
| `--all` | Include runtimes that are not installed. |
| `--deep` | Run `dev-bootstrap verify --health` and add its rows. |
| `--json` | Print `managers`, `conflicts` and, with `--updates` and `--deep`, `updates` and `deep` as JSON. |

Exit status: 0 when every check passed, 1 when one is inconclusive or PATH
needs attention, 2 when something is broken or the command line is wrong.

### States

| State | Meaning |
| --- | --- |
| `ok` | Installed, versioned and, where a startup check is declared, started. Not a build test. |
| `outdated` | Healthy, with an update the manager reports; the detail is the command that updates it. |
| `dormant` | A per-shell manager (fnm, conda) this shell has not activated; its runtime is not started. |
| `unused` | The manager keeps no versions; its binary comes from elsewhere. |
| `shadowed` | The manager keeps versions, but PATH resolves the binary somewhere else. |
| `unknown` | A probe timed out or printed no version. |
| `broken` | The runtime or its root is missing, or it fails to start. |
| `absent` | Not installed; shown with `--all`. |

A manager whose runtime is a proxy (rustup's `rustc`, elan's `lean`) is not
started when it keeps no version or is dormant, since the proxy could
install one. Every probe also runs with `RUSTUP_AUTO_INSTALL=0` and .NET's
first-run banner and telemetry turned off. Lean's version is read from the
home directory, since elan installs the toolchain a `lean-toolchain` file
below the current directory names as soon as `lean` runs there. Flutter's
launcher, which can download artifacts even for `--version`, never runs: its
cached version is read and its bundled Dart VM started. SDKMAN's Java and
Gradle versions come from their `current` links, so no JVM starts.

The C and C++ rows follow `CC` and `CXX`, launcher arguments and quoted
paths included, without evaluating them. The Nix row compares the `nix` on
PATH, the daemon it reaches and the release the configuration's locked
nixpkgs carries, which Home Manager writes to
`$XDG_CONFIG_HOME/dev-doctor/nix-release`: a client older than the daemon,
or a daemon older than that release, is broken and names the fix. On macOS
the toolchain row shows `cc-toolchain-check --status`, which goes stale when
Xcode, the Command Line Tools or macOS change.

### PATH Conflicts

Reported under their own heading: entries that do not exist, shim
directories without shims, shims that come after a package manager's
directory (`lib/90-path.zsh` puts them first), and npm's global prefix
inside a managed Node version, where a version change deletes every global
tool. A binary several origins provide is listed but does not change the
exit status, since that is how a machine with version managers normally
looks; one a manager already answers for, or one the system ships behind a
chosen toolchain, is not listed.

### Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `DEVDOCTOR_TIMEOUT` | 5 | Seconds per local probe. |
| `DEVDOCTOR_JOBS` | every check | Checks at once, at most 16. |
| `DEVDOCTOR_NET_TIMEOUT` | 30 | Seconds per update check (Homebrew gets twice that). |
| `DEVDOCTOR_UPDATE_TTL` | 21600 | Seconds the update cache stays fresh. |

A value that is not a positive number is a usage error. The update cache is
`$XDG_CACHE_HOME/dev-doctor/updates.json`, readable by its owner only and
replaced atomically; a damaged one is ignored.

### Deep Health

`--deep` runs `dev-bootstrap verify --health --json`, which starts every
global selection of the ecosystems the bootstrap manages, loads the
extensions that link host libraries and runs a small program with each. The
report (schema 1, stable for frontends) adds one row per runtime: a
`conflict` counts as broken, `blocked` or `missing` as inconclusive. A
missing `dev-bootstrap` or a check that runs out of time (900 seconds) is
inconclusive; one that fails or prints something else is broken. No
bootstrap code is imported.

### Registry

`core/registry.py` declares every row: how to tell it is installed (a command
on PATH, a path inside its root, or a function), how to read its version,
the binary PATH should resolve to it, its roots and the variable that moves
them, how to list the versions its manager keeps, the Homebrew formula and
command for updates, whether a shell activates it, and its startup check.
Rows that need more than one command name a function of the same module. The
registry is code in the store, not a file read at run time, so nothing a
check executes can come from a file another program could rewrite.

## toolchain

```sh
toolchain               # same as toolchain info
toolchain info --debug  # also what each wrapper reports
toolchain sdk --all     # every header, not only the divergent ones
use_llvm; use_gnu; use_system
```

`info` lists `cc`, `c++`, `gcc`, `g++`, `clang`, `clang++` and every
versioned name on PATH (`gcc-16`, `clang-23`), each with the compiler it
really is behind links and ccache's masquerade directory, its vendor and
version, read from its own banner. A `gcc` that is Clang, as on macOS without
GNU first on PATH, is a warning. `TOOLCHAIN_INFO_DEBUG=1` is the same as
`--debug`.

`sdk` checks whether the active compiler (`CC`, else `cc`) and `/usr/bin/cc`
can include fifteen headers that runtimes built from source need (zlib,
bzip2, xz, SQLite, readline, libffi, expat, libxml2, curl, Kerberos, Tcl,
libpcap, iconv, curses) and lists the ones they disagree on. A header the
active compiler misses but the system one reaches means a runtime built with
it silently loses a feature. On macOS the Homebrew formula that ships each
missing header is named. A missing header does not prove a library needs
installing: Apple's `ffi.h`, for example, needs the SDK's `usr/include/ffi`
search path, which CPython's configure supplies.

### Selection

`toolchain env llvm|gnu|system [--state STATE]` prints shell code; the
`use_*` functions evaluate it with what the previous switch left in the
shell's unexported `_TOOLCHAIN_STATE`. Nothing is printed unless the
selection is complete, so a failure leaves the shell as it was.

- A pair is a C and a C++ compiler from the same directory, both started
  and both of the family asked for: Clang for `llvm`, a GNU compiler (whose
  banner credits the Free Software Foundation) for `gnu`. In a directory the
  highest versioned pair wins over the plain names.
- On macOS the first such pair on PATH wins: the Nix host drivers, built
  against the host SDK, come first by design; Homebrew's GCC keg is the last
  resort for `gnu`. On Linux the distribution's compilers win, since only
  they search its headers; versioned LLVM directories (`/usr/lib/llvm-18/bin`)
  come first and PATH is the last resort.
- `CC` and `CXX` become absolute paths; `TOOLCHAIN_ACTIVE` names the
  selection. PATH gains the pair's directory only when it lacks it, and
  loses only a directory a switch added.
- The first switch away from the system remembers `CC` and `CXX`; `system`
  restores them, unsetting one that was unset. No other variable is touched.

## Guarantees

- Nothing installs, downloads or writes outside a private temporary
  directory, except the update cache.
- Every child process gets literal arguments, an empty standard input, a
  session of its own and a timeout that ends its whole process group,
  including what a shim or launcher started; none goes through a shell.
- One check that fails or raises becomes an `unknown` row; the others are
  still reported.
- Probe output never reaches the terminal unfiltered, and JSON is written by
  the standard encoder, so control characters cannot break either.
- Shell code names only `PATH`, `CC`, `CXX`, `TOOLCHAIN_ACTIVE` and
  `_TOOLCHAIN_STATE`, with every value quoted.

## Layout

`dev_doctor.py` and `toolchain.py` are the entry points; the implementation
is the `core` package next to them.

| Module | Concern |
| --- | --- |
| `host` | Platform, environment, PATH lookups and where a binary comes from. |
| `process` | Running children: no shell, empty input, timeouts that end the group. |
| `versions` | The version a banner reports, and their order. |
| `compilers` | Reading `CC`, identifying compilers, `info`'s survey. |
| `registry` | What dev-doctor checks. |
| `doctor` | The checks, PATH conflicts and update signals. |
| `deep` | dev-bootstrap's health report. |
| `sdk` | Header reachability. |
| `selection` | Choosing a pair and the shell code that applies it. |
| `report` | Terminal and JSON output. |
| `cli` | Both command lines and their exit status. |

## Tests

`nix build .#dev-doctor -L` runs the unit tests in `tests/` and checks that
both commands report the package version. The tests build temporary homes
with fake programs on PATH and never start a real compiler or manager; one
evaluates `toolchain env`'s output in a real zsh. Without Nix, from this
directory: `python3 -m unittest discover -s tests -t .`.
`tests/test_style.py` enforces the source conventions shared with the other
Python tools: docstrings everywhere, 80 columns, and no comments but section
banners and `noqa` markers.
