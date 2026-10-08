# Development Configuration and Native Managers

`toolchains/` selects shared compilers and debuggers. `languages/` owns each
language's support packages and configuration. Shell integrations are ordered
by `home/shells/zsh/config/lib/80-languages.zsh` and implemented under
`home/shells/zsh/config/languages/`. Manager state and downloaded runtimes
remain outside the checkout and Nix store.

Each Home Manager consumer must supply `runtimeManagerBackend` (`native` or
`nixpkgs`) and the Boolean `nativeFnmReady` checkpoint. Both reference
configurations use `native`. A Linux configuration is not automatically a NixOS
configuration. `bootstrap/` packages
the explicit `dev-bootstrap` command; activation and shell startup never invoke it.
The `nixpkgs` backend provides exact Node/Python paths where supported; it is
not a complete implementation for every ecosystem manager.

## Scope

`dev-bootstrap` joins native prerequisite provisioning, manager readiness,
additive runtime installation, absent-default initialization, missing-hook
repair and controlled fresh-shell qualification. `devrestore` is a symlink to
the same executable; the legacy flake package/check names alias the same output.
Manager roots, OCaml switch names, cache locations and lock identity are retained.
Neither activation nor shell startup performs provisioning.

The bootstrap covers Node, Python and OCaml, plus the six native toolchain
integrations below. Isolated contract tests exercise empty roots, reruns,
evolved selections, stage failures and the production Zsh adapters. Acceptance
on a clean supported host, native dependency retention, deployed-shell
acceptance and a NixOS target are separate qualification requirements.

Six native toolchain integrations cover Rust, GHC/Cabal, Lean/Lake, Ruby, Java
and Julia. Their initial identities are Rust 1.98.1, GHC 9.14.1, Cabal
3.16.1.0, Lean 4.32.0, Ruby 4.0.6, Java 21.0.12.1 (SDKMAN candidate
`21.0.12+1.1-tem`) and Julia 1.12.6.

Every adapter installs through its native manager at an exact version:
`fnm install` for Node and `pyenv install` with the native python-build for
Python, as for opam and the six toolchain managers. No runtime artifact is
retained in the store, and Nix supplies no FNM or pyenv input; a configuration
retires its remaining Nix FNM package through the `nativeFnmReady` checkpoint.
The installed pyenv must already know the declared CPython release; bootstrap
stops with an upgrade instruction otherwise.
Manager compatibility minimums are interface checks; they do not pin native
packages or certify every release.

## Architecture

| Component | Responsibility |
| --- | --- |
| `runtime-baseline.nix` | Exact initial runtime identities and descriptive defaults |
| `bootstrap/policy.nix` | Literal command arguments, manager CLI floors and timeouts |
| `bootstrap/package.nix` | Generated manifest, wrapper and isolated contract checks |
| `bootstrap/bootstrap.py`, `bootstrap/core/cli.py` | Executable entry, argument handling and structured reporting |
| `bootstrap/core/engine.py`, `setup.py` | Adapter selection, mutation guards, shared lock, setup stages and selection reports |
| `bootstrap/core/manifest.py`, `process.py`, `paths.py` | Manifest validation, the process boundary and filesystem/state boundaries |
| `bootstrap/core/adapters/` | One adapter per ecosystem behind a shared contract: Node through FNM and Python through pyenv from their own upstreams, opam switches on the root's own upstream, and the native managers for Rust, Haskell, Lean, Ruby, JVM and Julia |
| `bootstrap/probe-shell.zsh` | Disposable startup context loading the production language adapters and PATH module |
| `native-managers.nix` | Canonical package-manager routes, manager inventory and native build prerequisites |

Nix evaluation and package builds populate only store outputs and disposable
test roots. The executor uses literal argument arrays; SDKMAN's shell API uses
a fixed Bash program with positional arguments. Installed manager state and
runtime prefixes remain outside the store. Ordinary upgrades and project
selection stay with the native ecosystem managers.

The [bootstrap integration contract](bootstrap/README.md) defines manager
resolution, source-build isolation, shared test boundaries and the model for
the six additional ecosystems. Supported Git pyenv installations take precedence
over host packages consistently in setup, installation and shell checks.
Native builds accept compiler/SDK overrides only from the declared platform
environment, preserving account paths and proxy/certificate transport settings.

## Reproducibility Boundary

Bootstrap reconstructs a declared initial environment and preserves subsequent
native-manager evolution. Recovering that evolved state requires separate
manager inventories/exports; project dependency locks remain project-owned.
The Nix lockfile pins Nix inputs, while native package names do not pin their
future versions. Exact historical recovery of all native libraries and SDKs is
a separate retention requirement, not a guarantee of the initial bootstrap.

Toolchains and ecosystem managers should use canonical native installation
on macOS and Arch/CachyOS where supported;
NixOS uses nixpkgs and the required language adapters. Existing ecosystem
managers remain available. An additional package manager is appropriate only
when a selected platform installation requires it. Current Nix-owned compiler
modules keep their role. Full NixOS coverage and native manager/SDK artifact
retention are outside the qualified baseline. Every
adapter installs from its manager's upstream at an exact version; native
library closures still require qualification.

## Clean-Host Entry

From the checkout, `scripts/dev-bootstrap.sh` uses the system Bash before Nix
is available and delegates to the existing Nix-packaged executor afterwards:

```sh
scripts/dev-bootstrap.sh --check-foundation
scripts/dev-bootstrap.sh --install-foundation plan --json
scripts/dev-bootstrap.sh apply --only node
```

The standalone expression `scripts/development-bootstrap.nix` reads only the
public nixpkgs revision in `flake.lock`; unrelated application inputs
are not required. CI builds the same package through this expression.

The foundation check makes no downloads or configuration changes. It reports
Nix daemon connectivity, the canonical native package-manager executable and
Apple SDK presence. SDK presence is not compiler or license qualification.
Normal plan/verify commands can inspect incomplete native environments;
`apply` retains language-specific prerequisite checks.

Explicit foundation installation supports Apple Silicon macOS.
It invokes only missing foundations: the revision/checksum-pinned official
Homebrew installer (including its headless CLT acquisition), then the official
Nix 2.34.8 multi-user installer. This matches the initially locked Darwin Nix
release and leaves subsequent Nix daemon updates to nix-darwin. Existing
foundations are not upgraded. Installer-script pinning does not freeze
Homebrew's package repositories or Apple's software-update catalog.

Administrative authentication occurs in the foreground when needed; unattended
execution requires available noninteractive sudo privileges. Upstream installers
own their system changes, including Nix's store volume, daemon and shell profile
integration. Installation failure stops before runtime bootstrap. Existing
Homebrew with a missing/broken SDK is reported, not automatically reinstalled.
This entry never activates Darwin/Home Manager or installs desktop applications.
GitHub Actions exercises isolated bootstrap contracts and package builds; that
evidence does not replace an installation on a pristine operating system.

On Arch/CachyOS, use the same entry after the native OS/Nix foundation exists;
automatic foundation installation is deliberately macOS-only.
The entry enables flakes per invocation without changing the lockfile. Its
default operation is `plan`. Nix may acquire/build the bootstrap package even
for planning; `--only` restricts native operations,
not realization of the shared package. Use `--check-foundation` for a zero-download
foundation check. No global Python, uv or extra package manager is needed to start it.

The entry structure is informed by
[wcygan/dotfiles](https://github.com/wcygan/dotfiles/blob/fd0ceebfb4d9af418854fd66e4787bd698a96ee6/bootstrap.sh).
Its macOS GUI installer handoff, Nix-profile mutation workflow and Nix-owned
rustup are not adopted. The existing executor already supplies a pinned Python
runtime, so entering a development shell and adding uv would duplicate that role.

## Runtime Baseline and Recovery

`runtime-baseline.nix` is the shared declaration: Node 24.21.0 and 26.10.0,
Python 3.14.7, and OCaml 5.4.1/5.5.1. Intended defaults are initialized
only when absent during explicit native bootstrap. Existing global selections
and project manifests retain control. Inspect the
declaration and plan without changing manager state:

```sh
nix eval --json --file home/dev/runtime-baseline.nix
nix run .#dev-bootstrap -- plan --json
```

After installing the Nix and native package-manager foundations, the interface
provisions missing prerequisites, restores the baseline and checks selected
environment health. Arch requires a maintained package database. When a terminal
is attached, `scripts/dev-bootstrap.sh apply` runs `sudo -v` once; the executor
itself invokes only noninteractive `sudo -n`, and without cached credentials it
stops before any change and prints the pacman command for the missing packages.
Apple developer tools, SDK selection and license acceptance are prerequisites
when a source build requires them:

```sh
nix run .#dev-bootstrap -- apply
nix run .#dev-bootstrap -- verify --health --json
nix run .#dev-bootstrap -- verify --json
```

After Home Manager activation, the same interface is available as `dev-bootstrap`.
`devrestore` and the `development-recovery` flake package remain compatibility
aliases to this implementation, with the same manager roots and lock.
An omitted operation defaults to `plan`. `--only node`, `--only python` and
`--only ocaml` restrict the operation; repeated selectors combine them. Planning
reports paths and blockers without running managers, downloading or writing.
`present` means a path exists; `verify` establishes its version and canaries.
JSON additionally reports global selections and installed version/switch names.
Planning succeeds even with missing prerequisites; verification returns nonzero
until every selected runtime passes.
Default `verify` checks exact baseline identities and complete build canaries.
`verify --health` checks that each selected native global runtime runs, at any
release: there is no version floor, so downgrades and additional named Python
environments qualify like upgrades. Selections delegated to the host (`system`
for pyenv and rbenv, `fnm default system`) are reported as `external` and not
executed. Health does not repair hooks, invoke managers, create manager state or
launch a shell. Project selection remains controlled by native project
manifests. `apply` reports global selections instead of failing on them, and
verifies that the production adapters and PATH module resolve the expected
native managers and the verified selections in a disposable Zsh context.
The controlled probe uses an interactive Zsh with user startup files disabled,
so real opam hooks initialize. It does not establish acceptance of a deployed
`.zshrc`.

`--runtimes-only` skips native provisioning, initial defaults and effective-shell
qualification, retaining the original additive restoration interface. Both CLI
names support the same options and use `$XDG_STATE_HOME/devrestore/apply.lock`.
The `nixpkgs` backend retains its exact-runtime interface and does not invoke
native provisioning. `--health` requires the native setup adapter.

Apply preflights incomplete prefixes before native package mutation. Native
packages are installed only when missing; Homebrew auto-update, upgrades,
dependent checks and cleanup are disabled for this operation. Pacman tests missing dependencies with `-T`, honoring providers such as
CachyOS's `zlib-ng-compat`, and uses `-S --needed` without refreshing repositories
or upgrading the OS. Native package
installation is not a version lock. The foundation must remain maintained;
see [Homebrew controls](https://docs.brew.sh/Manpage) and
[Arch maintenance](https://wiki.archlinux.org/title/System_maintenance).

The shared lock covers provisioning, runtime installation, initial selections
and shell qualification. Extra versions and existing global defaults survive;
only absent defaults are initialized. Missing Python shims trigger native
`pyenv rehash`; missing opam hooks trigger `init --reinit` with explicit hook
creation and no shell-configuration edits. Existing selections are checked,
never silently reset to the baseline. Existing upgraded baseline prefixes are
accepted by bootstrap health, while exact verification still reports their
identity difference. It refuses incomplete or incompatible installations. Recovery
processes are serialized, but ordinary manager commands do not share that lock;
avoid concurrent installation into the same roots. A failed source build may
leave an incomplete new prefix/switch: inspect it before retrying. Recovery
never removes that state automatically or rolls back native packages.

Node uses native FNM in an isolated staging root. FNM downloads the declared
release from nodejs.org, named explicitly in the policy; inherited mirror and
architecture settings are cleared. FNM does not verify Node's published
checksums, so integrity rests on HTTPS to that upstream, as for the other
managers' downloads. The staged release passes identity and canary checks
before it enters the real root. FNM's automatic first-install default remains
confined to staging, and a failed download leaves nothing in the real root.

Python uses `pyenv install` with the native pyenv's python-build. It downloads
CPython, and any dependency its definition bundles, from their upstreams and
verifies the checksums embedded in the definition. The release must appear in
the native definition list before any build starts, and a working SHA256
verifier is mandatory. Inherited prefix/install flags, make variable overrides,
checksum-cache controls and pyenv hooks are cleared by the source-build
environment. Native `pyenv rehash` refreshes shims after installation.
Verification requires SSL, SQLite, compression (including Zstandard), ctypes,
readline, tkinter and venv. Source compilation uses platform-declared native
compiler paths and build-tool search paths for Python and OCaml; these overrides
are scoped to compilation and do not change interactive C/C++ ownership. The native compiler, libraries and SDK remain host prerequisites rather
than a complete build lock.

The OCaml adapter creates `lcs-ocaml-<version>` switches from the opam root's
own repositories, with required source checksums and automatic OS-package
installation disabled. A fresh root is initialized bare on opam's default
upstream (`https://opam.ocaml.org`) with Zsh hooks, without writing shell
configuration or selecting a global switch. Existing roots keep their
repositories and global/project selections; the bootstrap never registers or
selects repositories. An interrupted creation leaves an incomplete switch that
planning reports for inspection; it is never deleted or reused automatically.
Verification of an existing compiler compiles and runs a small bytecode program. Project dependency locks
and existing switch exports remain separate inputs.

Manager roots honor `FNM_DIR`, `PYENV_ROOT` and `OPAMROOT`; cache and lock state
use XDG cache/state directories. Writable roots inside project checkouts or the
Nix store are rejected. Canonical Git-installed pyenv is an explicit exception:
its own ignored versions directory remains within the manager checkout. Private
recovery subdirectories reject symlink redirects and shared write permissions.

## NixOS Runtime Boundary

With the explicit `nixpkgs` backend, the manifest retains exact store paths for
both Node releases and a Python 3.14.7 environment containing tkinter. It does
not download foreign binaries or substitute nearby versions. Python's controlled
Nix wrapper uses safe-path/user-site exclusion flags; native Python uses isolated
mode. These paths can be verified without native manager installation.

The locked nixpkgs OCaml is 5.5.0, so the declared OCaml versions are reported as
blocked. Daily project selection through NixOS manager adapters and actual
NixOS host acceptance remain separate qualification work. No NixOS host output
is defined. Optional project devShells remain supported, and the C/C++ and Go
ownership is unchanged.

## Native Installation Inventory

Inspect the inventory from the checkout:

```sh
nix eval --json --file home/dev/native-managers.nix
```

Darwin's Homebrew module consumes its formula list. Homebrew owns these
binaries even though nix-darwin declares their installation. Cleanup remains
`none`. Arch's package list covers FNM, opam, pyenv, rbenv and ruby-build; review it
against the configured repositories before native installation:

```sh
pacman -Si fnm opam pyenv rbenv ruby-build
```

FNM on macOS uses [Homebrew](https://github.com/Schniz/fnm#installation). Arch
uses the [official native package](https://archlinux.org/packages/extra/x86_64/fnm/),
also available in the CachyOS repositories. Pacman owns
`/usr/bin/fnm`; downloaded Node versions remain in FNM's data directory.
The inventory describes installation routes and feeds explicit native bootstrap;
it does not supply a release or dependency-closure lock. Other managers are integrated by the shell and are not part of
this package inventory.

## FNM Ownership Transfer

While a configuration sets `nativeFnmReady = false`, the Nix FNM package
bridges the transfer. On macOS, provision and verify `/opt/homebrew/bin/fnm`.
On Arch, provision and verify `/usr/bin/fnm`. Check `--version`,
`list`, and `env --shell zsh` using the absolute native executable, with
temporary XDG state/runtime paths for the environment probe.

Keep the existing FNM data root and Node versions. Bootstrap exposes the
canonical native executable as `$FNM_DIR/fnm`, refusing a conflicting existing
entry. Its disposable probe sets the candidate readiness flag only within that
process. Confirm the deployed shell selects the native executable before
setting that configuration's checkpoint to `true`, building and activating the generation. The checkpoint removes Nix FNM and updates dependency hints;
Node's Nix fallback stays available. Shell initialization never installs a
version or chooses a new global default. Use `fnm default <version>` explicitly
when deliberately changing an existing selection. Bootstrap initializes it
only when absent.

Configuration rollback does not undo native installations or manager state.
Before restoring a generation that removes Nix FNM, its native replacement
must still be present. C/C++ driver selection, native SDKs, project manifests
and optional devShells keep their existing roles.
