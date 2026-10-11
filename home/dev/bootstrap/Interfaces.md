# Bootstrap Interfaces

Three interfaces are frozen for frontends and new ecosystems: the adapter
contract, version 1, the JSON report, schema 1, and the progress events,
schema 1. Removing or renaming a
member, changing its type or meaning, or adding a member every adapter must
implement raises the version. Adding an optional report field, an action, a
row state reported only under a new option, an event, or an adapter hook with
a default does not.
The [README](README.md) explains the architecture these interfaces belong to.

## Adapter Contract, Version 1

An ecosystem is one subclass of `core.adapters.base.Adapter`, registered in
`core/adapters/__init__.py` in an order that lists every requirement before
its dependents. The engine and setup stages call only the members below and
never branch on a language. `ToolchainAdapter` (`core/adapters/toolchain.py`)
implements most of them for managers that install exact toolchains into their
own root; a subclass then supplies `binary`, `install_arguments`,
`default_arguments`, `read_selection` and `exercise`.

### Metadata

Class attributes, read without an instance. The four selection fields appear
in every report's `catalog`.

| Attribute | Type | Meaning |
| --- | --- | --- |
| `language` | `str` | The ecosystem's `--only` value and report key. |
| `manager_name` | `str` | The native manager, reported as each row's `owner`. |
| `runtime_directory` | `str` or `None` | Directory below the runtime root with one entry per installation, if any. |
| `compiles` | `bool` | Missing runtimes build from source and need the platform SDK. |
| `sourced_manager` | `bool` | The manager is a script to source (SDKMAN), not an executable. |
| `requires` | `tuple[str, ...]` | Ecosystems that must be selected in the same run. |
| `default_selected` | `bool` | Whether a run without `--only` includes the ecosystem. |
| `platforms` | `tuple[str, ...]` | Nix system strings where the adapter is available. |
| `consents` | `tuple[str, ...]` | Terms an `apply` must name with `--accept`. |

### Required Members

| Member | Contract |
| --- | --- |
| `resolve_roots()` | Map the exported root variables to absolute paths, the runtime root first. Honors the environment; never inside a checkout or the store. |
| `manager_candidates()` | Canonical manager locations in order, or `None` to search `PATH`. |
| `readiness()` | Check that the manager runs and is recent enough. Called once per `apply`, after acquisition. |
| `baseline()` | One row per declared identity with its expected executable `path`. Reads the filesystem only. |
| `install(row)` | Install exactly that row through the manager. Never changes a global selection. Updates `row["path"]` when the installed location differs from the planned one. |
| `identity(row, path)` | The release the runtime reports about itself. |
| `canary(row, path, *, complete)` | Run a small local program; `complete=False` is the release-agnostic health check. Never resolves packages or downloads. |
| `selection()` | The manager's global selection as recorded on disk, or `None`. Never runs the manager. |
| `selected_runtime()` | The executable the global selection designates, or `None` when the host owns it (`system`). |
| `initialize_default()` | Set the declared default only when `selection()` is `None`. |

### Members With Defaults

| Member | Default | Override when |
| --- | --- | --- |
| `title`, `component_titles` | The language key; no component names | The ecosystem or its components have a conventional spelling (`OCaml`, `GHC`). |
| `source_build`, `cost` | A download; no size class | The manager compiles the runtime; a first apply has been measured (`small`, `medium` or `large`, as the README defines them). |
| `declared(data)` | Always declared | The manifest may omit the ecosystem. |
| `home` | The runtime root | The manager lives elsewhere (`CARGO_HOME`, `JULIAUP_HOME`). |
| `environment()` | The resolved roots | Children need more variables. |
| `mutable_directories()` | Roots and `runtime_directory` | More directories are written. |
| `manager_packages()` | The declared native package and installer prerequisites | Never, usually. |
| `acquire()` | Nothing | The manager comes from a verified installer. |
| `prefix(row)` | Two levels above `path` | The installation directory is elsewhere; `None` when the manager keeps no per-release directory. |
| `incomplete(row)` | Generic inspection message | A specific cause can be named. |
| `owned_prefix(row)` | `prefix(row)` when strictly inside the root | Never. |
| `discard(prefix)` | Remove the directory, refusing a symlink | The manager also keeps records of it (`opam switch remove`, `rustup toolchain uninstall`). |
| `preflight(missing)` | Nothing | A missing runtime can be known unbuildable before any change. |
| `unbuildable(missing)` | No release | Read-only: the manager knows which releases it can build (python-build); `plan --preflight` reports the others. |
| `check_runtime(path)` | Nothing | A path must be rejected before it runs. |
| `remediation(row)` | `None` | The runtime is compiled against host libraries; return the rebuild argv. It is reported, never run. |
| `installed()` | Entries of `runtime_directory` | The manager records installations elsewhere. |
| `check_selected(path)` | Exists and lies outside the store | Selections need the same checks as runtimes. |
| `repair_hooks()` | Nothing | Shims or shell hooks can be recreated without reselecting. |

### Guarantees

- `plan` and `baseline` read the filesystem and the installation journal
  only; they never run a manager, an installer or a downloader.
- Installation is additive. A prefix that exists without its executable is a
  `conflict`, unless the installation journal shows an interrupted install
  of bootstrap's own created it; that one alone may be discarded.
- Exact verification checks the declared identity and the complete canary;
  health accepts any release the global selection names.
- Every child process goes through `core.process.run`: literal arguments, a
  scoped environment, its own process group and a timeout.

## Retirement

`prune` is outside the adapter contract: an ecosystem is pruned only when
`core/prune/__init__.py` registers a retirer for its adapter, and one without
a retirer is never touched. The manifest's `retired` attribute set mirrors the
declarations: each list holds the releases its attribute path used to
declare (`node.versions`, `nativeToolchains.rust.version`,
`nativeToolchains.jvm.candidate`), and `validate.nix` rejects a list at an
undeclared path or one naming a release that path declares again.

A retirer (`core.prune.base.Retirer`) supplies `paths()`, each component's
declaration path; `prefix(release, component)`, where an installed release
lives; and `uninstall(retirement)` and `reselect(retirement)`, through the
manager. `inspect(retirement)` adds the steps that carry dependents over, or
the blockers that keep the release. Planning reads the filesystem only; a
removal that leaves the prefix behind fails.

## Report JSON, Schema 1

`--format json`, or its alias `--json`, prints one object; the default text
report renders the same object for people and is not an interface. `plan`
exits 0 whenever it can report; `apply` and
`verify` exit 0 when every runtime row is `ok` or `external`, and 1 otherwise.
`prune` exits 0 when it only lists; with `--yes`, 0 when every retired row is
`removed`, and 1 otherwise. `report` exits 0 when it shows what was asked.
An operational error exits 2 with a message on stderr and no report; an
interruption exits 128 plus the signal number.

### Top Level

| Field | Present | Content |
| --- | --- | --- |
| `schema` | Always | `1`. |
| `action` | Always | `plan`, `apply`, `verify` or `prune`; `report` for the list of runs. |
| `platform` | Always | Nix system string. |
| `backend` | Always | `native` or `nixpkgs`. |
| `defaults` | Always | Declared default release per ecosystem. |
| `catalog` | Always | One entry per registered adapter, selected or not. |
| `observed` | Always | `globalSelections` and `installed`, per selected ecosystem, as recorded on disk. |
| `runtimes` | Always | Rows: the declared baseline, or the global selections with `verify --health`. |
| `setup` | Native setup | `stages`, `nativeManagers` (`language`, `state`, `path` or `reason`), `packageManager`, `privilegedPackages`. |
| `selections` | `apply` | Global selection rows, verified for health, which never fail the command. |
| `verification` | `verify --health` | `health`. |
| `selection` | Always | `source`: `only`, `all`, `file` (with `path`, the saved selection) or `default`. |
| `retired` | `prune` | Retired rows, below. |
| `preflight` | `plan --preflight` | What `apply` would install and what would stop it, below. |
| `run` | `apply` and `prune --yes`, once the run took the lock | The run's record, below. |

A run that fails or is interrupted prints no report, but keeps one: the
top-level fields above without `setup`, `selections` and `retired`, with
`runtimes` and `observed` planned again after it stopped, and `run` with its
`error`. `report --last` and `report --run ID` print a kept report as it was
written. `report` alone prints the list of runs: `schema`, `action`
(`report`), `directory` and `runs`, newest first, each with `id`, `path`,
`state` (`ok`, `failed`, `interrupted`, or `incomplete` while it has no
report) and, from its report, `command`, `started`, `duration` and `exit`.

### Run

| Field | Present | Content |
| --- | --- | --- |
| `id` | Always | The run directory's name: its UTC start, `20261011T101500Z`, with `-2` and on for runs started in the same second. |
| `command` | Always | `apply` or `prune --yes`. |
| `path` | Always | The run directory. |
| `started` | Always | ISO 8601 UTC time. |
| `duration` | Always | Seconds, to a tenth. |
| `exit` | Always | The command's exit status. |
| `outcome` | Always | `ok` (exit 0), `failed` or `interrupted` (exit above 128). |
| `logs` | Always | Log path per ecosystem or stage that ran a child. |
| `error` | The run stopped | `message`, as printed on stderr; `stage`, for an apply with the native setup; `log`, the log of the work that failed, when it ran a child. |

### Catalog Entry

`language`, `title` (how the ecosystem reads for people), `manager`,
`requires`, `defaultSelected`, `platforms`, `consents`, `available`
(declared and supported here), `cost` and `selected`. `cost` holds `build`,
`source` or `download`, and `size`, `small`, `medium` or `large`, when the
ecosystem has been measured. A multi-component ecosystem adds
`componentTitles`, each component's name for people.

### Runtime Row

| Field | Present | Content |
| --- | --- | --- |
| `language` | Always | Ecosystem. |
| `version` | Always | Declared identity (the default release for a health row). |
| `path` | Always | Expected or selected executable; empty when unknown. |
| `owner` | Always | Manager name, or `nixpkgs`. |
| `state` | Always | See below. |
| `component` | Multi-component ecosystems | `ghc`, `cabal` or `hls`. |
| `reason` | `blocked`, `conflict`, `external` and interrupted `missing` rows | Why, in one sentence. |
| `remediation` | Some `conflict` rows | Shell-quoted manager command that rebuilds the runtime. |
| `interrupted` | Some `missing` rows | `true`: an interrupted install left the prefix, and `apply` replaces it. |
| `actualVersion` | Health | The release the selection reported. |
| `isolated` | `nixpkgs` rows | Whether a Python interpreter supports `-I`. |

| State | Meaning |
| --- | --- |
| `missing` | Not installed; `apply` installs it. |
| `present` | The executable exists; not yet verified (plan). |
| `ok` | Verified: exact identity and complete canary, or health. |
| `conflict` | Present but failing verification, or an incomplete prefix bootstrap did not start; needs a person. |
| `blocked` | Cannot proceed here: missing manager, NixOS without the nixpkgs backend, unusable selection. |
| `external` | The global selection delegates to the host (`system`); not executed. |

### Preflight

`plan --preflight` adds read-only queries to the plan: the native package
query (`pacman -T`, `brew list`), the SDK probe and the releases a manager
can build. Nothing is created, installed or elevated. It needs the native
setup, so the `nixpkgs` backend and `--runtimes-only` refuse it.

| Field | Present | Content |
| --- | --- | --- |
| `packageManager` | Always | `path`, and `state`: `present`, or `missing` when apply could install nothing. |
| `missing` | Always | The native packages apply would install, sorted. |
| `privileged` | Always | Whether installing them needs administrator rights. |
| `command` | Always | The install command apply would run, led by the privilege tool when needed; empty when nothing is missing or there is no package manager. |
| `sdk` | A missing runtime builds against the platform SDK | `present` or `missing`. |
| `ecosystems` | Always | Per selected ecosystem: `language`, `manager` (`present` or `missing`), the `packages` it needs, the `missing` ones, and `unbuildable` releases when its manager cannot build them. |

### Runs and Logs

A run directory is created, mode 0700, once `apply` or `prune --yes` holds the
lock; a run refused before that (a missing consent, a held lock) writes
nothing. It holds `<ecosystem>.log` for the work of one ecosystem and
`<stage>.log` for a stage's work outside any (`prerequisites`, which installs
the native packages, and `shell`). Each child appears as `$ argv`, its
standard output and error as they were written, and `[exit N after S s]`, or
`[stopped]` when the run ended it. `events.jsonl` and `report.json` follow.
Files are mode 0600. Only directories named like a run are counted; the ten
newest stay and the rest are removed when a run starts.

## Progress Events, Schema 1

`apply --events PATH` and `prune --yes --events PATH` write one JSON object
per line to PATH, a file or a FIFO, flushed as each happens; the run
directory's `events.jsonl` holds the same lines. Every event has `time` (ISO
8601 UTC) and `event`. A `-start` event is followed by its `-finish`, which
repeats the identifying fields and adds `outcome` (`ok`, `failed` or
`interrupted`) and `duration` in seconds; steps nest in the order below.

| Event | Fields | Emitted |
| --- | --- | --- |
| `run-start` | `schema` (1), `run`, `command`, `directory` | When the run takes the lock. |
| `stage-start`, `stage-finish` | `stage` | Around each setup stage: `prerequisites`, `readiness`, `runtimes`, `defaults`, `shell`. |
| `packages-start`, `packages-finish` | `packages`, `command`, `privileged` (start only) | Around the native package installation, when packages are missing. |
| `ecosystem-start`, `ecosystem-finish` | `language`; `runtimes` (each `version`, and `component` when it has one) and `log` (start only) | Around installing an ecosystem's missing runtimes. |
| `removal-start`, `removal-finish` | `language`, `version`, `component` when it has one | Around removing one retired release. |
| `run-finish` | `outcome`, `exit`, `duration`, `report` when the run took the lock | Last, always, also for a run refused before the lock. |

### Retired Row

| Field | Present | Content |
| --- | --- | --- |
| `language` | Always | Ecosystem. |
| `version` | Always | The retired release, as declared (an SDKMAN identifier for Java). |
| `path` | Always | Where it is installed: what removal deletes. |
| `owner` | Always | Manager name. |
| `successor` | Always | The declared release that replaces it. |
| `state` | Always | `retire`, `blocked`, `removed` or `failed`. |
| `steps` | Always | What removal does, in order; the last step removes the release. |
| `component` | Multi-component ecosystems | `ghc`, `cabal` or `hls`. |
| `reason` | `blocked` and `failed` rows | What keeps it installed. |
| `notes` | Some rows | What prune cannot inspect, such as a project's own environment. |

| State | Meaning |
| --- | --- |
| `retire` | Installed and removable; `prune --yes` removes it. |
| `blocked` | Something prune cannot carry over depends on it; it stays. |
| `removed` | Every step ran and the release is gone. |
| `failed` | A step failed; the release stays and `reason` says why. |
