# Bootstrap Interfaces

Two interfaces are frozen for frontends and new ecosystems: the adapter
contract, version 1, and the JSON report, schema 1. Removing or renaming a
member, changing its type or meaning, or adding a member every adapter must
implement raises the version. Adding an optional report field, a row state
reported only under a new option, or an adapter hook with a default does not.
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

## Report JSON, Schema 1

`--json` prints one object. `plan` exits 0 whenever it can report; `apply` and
`verify` exit 0 when every runtime row is `ok` or `external`, and 1 otherwise.
An operational error exits 2 with a message on stderr and no report; an
interruption exits 128 plus the signal number.

### Top Level

| Field | Present | Content |
| --- | --- | --- |
| `schema` | Always | `1`. |
| `action` | Always | `plan`, `apply` or `verify`. |
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

### Catalog Entry

`language`, `manager`, `requires`, `defaultSelected`, `platforms`,
`consents`, `available` (declared and supported here) and `selected`.

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
