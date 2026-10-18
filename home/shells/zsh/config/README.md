# Zsh Configuration

Modular Zsh configuration for macOS and Linux/Arch, deployed by Home Manager.
The default interactive startup defers expensive integrations and activates the
prompt only after deterministic PATH assembly. Filesystem and cache operations
are validated before executable shell code is sourced.

## Bootstrap and Installation

The repository uses this layout:

```text
Dotfiles/home/shells/zsh/
├── default.nix             Home Manager ownership and platform policy
├── zshenv-bootstrap        Reproducible ~/.zshenv bootstrap
├── zprofile                Login-shell environment
├── zshrc                   Interactive loader
├── p10k.zsh                Powerlevel10k configuration
├── Brewfile                Generated macOS dependency view
├── packages/               Canonical dependency registry and Arch view
├── docs/                   Focused operational documentation
└── config/                 Deployed as ~/.config/zsh
    ├── .zshenv             Environment shared by all shell types
    ├── lib/                Ordered startup modules
    ├── functions/          Interactive command bundles
    ├── conf.d/linux/       Shared Linux environment
    ├── completions/        Compinit-compatible `_name` files
    ├── scripts/            Lazy command modules and Python backends
    └── others/             Standalone minimal/server configurations
```

### Naming Convention

Shell sources, scripts, fixtures, and documentation use descriptive
`kebab-case` filenames. Abbreviations are limited to established technical or
product names such as Zsh, CLI, AI, PDF, C++, FZF, VS Code, and OCI. A leading
underscore marks a private module; completion files retain Zsh's `_command`
contract. Python modules and `test_*.py` files use `snake_case`, as required by
Python imports and test discovery. Standard dotfiles and generated artifacts
keep the names imposed by their respective tools.

Provision the macOS host from the repository root with:

```zsh
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro
```

For the standalone Linux Home Manager output, use:

```zsh
nix build '.#homeConfigurations."lcs-dev@LCS.Dev-Legion-Cachy".activationPackage' --no-link
home-manager switch --flake '.#lcs-dev@LCS.Dev-Legion-Cachy'
```

Home Manager deploys `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.p10k.zsh`, and
the complete `~/.config/zsh` tree from the Nix store. The bootstrap loads Cargo,
sets the static Homebrew environment without running `brew shellenv` in every
process, and then sources `~/.config/zsh/.zshenv`. Durable configuration edits
require a switch and therefore follow generation rollback.

On macOS, nix-darwin deliberately leaves `programs.zsh.enable` disabled; it
owns the login-shell binary through `users.users.<name>.shell`, and Home
Manager owns the configuration.
The repository `.zshenv` loads the standard multi-user Nix environment only
when no system initializer has already done so. On Linux, Home Manager installs
the Zsh binary as well as managing the same shared configuration.

Supported dependencies are declared once in
`packages/zsh-dependencies.tsv`. The generated `Brewfile` and Arch package list
provide reproducible platform inventories, and its `nix` column is checked
against the Home Manager packages at build time; installation and trust
details live in `docs/Zsh-Dependencies.md` beside this configuration. The
module itself installs only what nothing else needs: gawk and shdoc.

## Startup Architecture

### Development Environment Health

`dev-doctor` (formerly `devdoctor`, which remains as an alias) reports the
runtime managers and development tools this configuration sets up, and
`toolchain` explains and selects the C/C++ compilers. Both are a Python
package in `home/dev/doctor`, whose README documents them; the shell only
keeps the `use_llvm`, `use_gnu` and `use_system` functions, which evaluate
what `toolchain env` prints, and the `get_toolchain_info` and
`get_toolchain_sdk_support` names, in `functions/development-tools.zsh`.

### Loading Modules

The normal loader sources `lib/*.zsh` in lexical order, then `functions/*.zsh`,
and activates the prompt last. Modules are sourced at top level, never from a
function, so their plain `typeset` declarations stay global. A function file
opts into deferred loading with a header marker:

```zsh
# zsh-load: deferred
```

`ZSH_FAST_START=1` keeps the same loop but sources only the core listed in
`_ZSH_FAST_START_MODULES` (initialization, history, vi mode, aliases,
variables, PATH), skips the function bundles, and sets a static prompt.
Plugins and the prompt belong to the shared shell on every desktop. Linux
environment defaults load from `conf.d/linux/env.zsh` without a distribution
probe; graphical environment variables belong to the session manager.

The original `conf.d/hyde/`, `user.zsh` and `prompt.zsh` are retained only in
the checkout and excluded from the deployed Zsh source. Startup does not read
`~/.hyde.zshrc` or `~/.user.zsh`. Inherited HyDE plugin/prompt flags cannot
disable shared modules; Linux startup clears those flags and the exact retired
`$XDG_DATA_HOME/hypr/hyprland.conf` value, preserving custom compositor paths.

Current modules:

| Module | Responsibility |
| --- | --- |
| `00-initialization.zsh` | Shell options, defer engine, VS Code integration, macOS rc handling |
| `runtime-helpers.zsh` | Colors, platform, mtime, permission checks, atomic cache writes |
| `10-history.zsh` | Shared, deduplicated history |
| `20-zinit.zsh` | Zinit, plugins, periodic compinit |
| `30-prompt.zsh` | Prompt definitions; activation follows final PATH assembly |
| `40-vi-mode.zsh` | Vi keymaps and cursor behavior |
| `50-tools.zsh` | Atuin, fzf, zoxide, direnv (cached init), Yazi, Kitty, OrbStack |
| `60-aliases.zsh` | Aliases and compilation shortcuts only |
| `70-ai-tools.zsh` | Fabric and credential-scoped AI command wrappers |
| `75-variables.zsh` | Language/application variables; no global compiler flags |
| `80-languages.zsh` | Language managers, lazy runtimes, change-driven opam env hook |
| `85-completions.zsh` | Cached generated completions |
| `90-path.zsh` | Deterministic PATH rebuild with signed 24-hour cache |
| `94-lazy-loader-core.zsh` | Secure, auto-invalidating script stub generator |
| `95-lazy-scripts.zsh` | On-demand commands from `scripts/*.zsh` |
| `96-lazy-cpp-tools.zsh` | On-demand competitive-programming tools |

`ZSH_FAST_START=1` loads only the minimal core. Other useful toggles include
`ZSH_DEFER_COMPLETIONS`, `ZSH_LAZY_SCRIPTS`, `ZSH_LAZY_CPP_TOOLS`, and
`ZSH_CUSTOM_COMPLETIONS`.

Every cache under `$XDG_CACHE_HOME/zsh` carries the key of what produced it
(tool executable, scanned files, fpath directories, the PATH template), so a
switch or an upgrade invalidates exactly the affected entries; no cache is
wiped wholesale at startup. `zshcache --rebuild` remains the manual reset.

Public shdoc metadata also generates completion specifications for custom
commands. Generation is deferred and cached securely; pressing Tab only calls
the in-memory `_arguments` completer. Existing specialized completions always
take precedence over the generated baseline.

## Command Index

### Files, Navigation, and Productivity

| Command | Source | Purpose |
| --- | --- | --- |
| `extract` | `functions/files.zsh` | Extract common archive formats |
| `count` | `functions/files.zsh` | Count files, directories, links, and hidden entries |
| `dirsize` | `functions/files.zsh` | Inspect directory sizes with the Python backend |
| `mkcd`, `bak`, `up` | `functions/core.zsh` | Navigation and safe file backup helpers |
| `note`, `bm` | `functions/productivity.zsh` | Private notes and directory bookmarks |
| `cleanup`, `zshcache` | `functions/productivity.zsh` | Cache cleanup and compinit rebuild |
| `fabric-pattern` | `lib/70-ai-tools.zsh` | Run Fabric patterns without global wrapper functions |
| `zfuncs` | `functions/zfuncs.zsh` | List and validate documented public functions |
| `h` | `functions/cli-tools.zsh` | Colorized command help through bat |
| `hlp` | `lib/50-tools.zsh` | Tldr with man fallback |

### Network and Documents

| Command | Source | Purpose |
| --- | --- | --- |
| `weather`, `myip` | `functions/network.zsh` | Remote weather and public-IP information |
| `portscan`, `serve` | `functions/network.zsh` | Port probe and guarded local HTTP server |
| `shorten`, `cheat` | `functions/network.zsh` | is.gd and cheat.sh clients with shared URL encoding |
| `qr` | `functions/network.zsh` | Local QR via `qrencode`, explicit remote fallback |
| `pdf-tools` | home/cli/pdf-tools | PDF pages, compression, passwords, metadata, bookmarks, watermarks, DjVu |

### Development and Operations

| Command | Source | Purpose |
| --- | --- | --- |
| `get_toolchain_info`, `get_toolchain_sdk_support` | `functions/development-tools.zsh` | `toolchain info` and `toolchain sdk` (home/dev/doctor) |
| `use_llvm`, `use_gnu`, `use_system` | `functions/development-tools.zsh` | Reversible per-shell compiler selection through `toolchain env` |
| `fnm_clean`, `zsh_profile`, `zshdeps` | `functions/development-tools.zsh` | Maintain fnm, profile startup, inspect dependencies |
| `brew_stats` | `functions/package-management.zsh` | `brew-stats` (home/cli/brew-stats): installed Homebrew package sizes |
| `security-scan`, `secscan` | home/cli/security-scan | Structural, YARA, and ClamAV file scanning |
| `utm_ubuntu_start`, `utm_ubuntu_login` | `scripts/utm-ubuntu.zsh` | Start/login to the UTM Ubuntu VM |

### Blog

| Command | Source | Purpose |
| --- | --- | --- |
| `blog` | `functions/productivity.zsh` | `blog` (home/apps/blog): copy posts and images from the Obsidian vault into the Hugo site, build, commit and push; GitHub Pages deploys on push |

## Security Decisions

- Cache/config files are sourced only when owned by the current user, readable,
  non-symlinks, and not group/world-writable. Home Manager's generated session
  variables are the sole exception: their profile link must resolve into the
  immutable Nix store before `.zshenv` sources them.
- Cache writes use user-only temporary files followed by atomic rename.
- Tool init scripts (Starship, Atuin, fzf, zoxide, direnv) and the
  completions ngrok and ng print are cached by `_zsh_cached_init`, keyed to
  the symlink-resolved executable, and pass the same ownership and permission
  checks before being sourced.
- 1Password values are read through `ai-secret`, cached in non-exported shell
  variables and exposed only to the intended child command (`gemini` or
  `opencode`). Claude Code fetches its MCP headers itself through
  `ai-secret headers`, so no key enters its environment. `ai-secret` prefers
  the 1Password Environment `AI-Secrets`, which the desktop app serves through
  a named pipe at `$XDG_STATE_HOME/ai-secrets/secrets.env` (one authorization
  until 1Password locks, nothing on disk), and falls back to `op read`.
- Fabric refuses pattern names that collide with commands/builtins and publishes
  generated notes only after a successful run.
- Zinit and its plugins intentionally track their upstream default revisions.
  This is a convenience/supply-chain tradeoff rather than a reproducible pin;
  review `zinit update` output before accepting plugin updates. Pin commits in
  `20-zinit.zsh` if deterministic third-party code becomes a requirement.
- `shorten` sends URLs to is.gd. `qr` stays local when `qrencode` is installed
  and warns before falling back to qrenco.de; never send credentials remotely.

## Toolchain Policy

Startup never exports `CPATH`, `LDFLAGS`, `CPPFLAGS`, `LD`, or `AR` globally.
Use `use_llvm` or `use_gnu` when a shell needs an explicit toolchain, and
`use_system` to restore `CC` and `CXX`. Project-specific flags belong in
the build system or `.envrc`. Terminal-launched Emacs receives the libgccjit
library path only for that process.

## Conventions

- Two-space indentation for new shell code; legacy files are normalized when
  touched substantially.
- Function declarations use `name() { ... }`.
- Diagnostics and logs go to stderr; stdout is reserved for command results.
- Public commands implement `-h`/`--help`; new exceptions require a docstring.
- Multi-file modules use a guard that verifies their public functions still
  exist, because lazy stubs can replace function names after a reload.
- Standalone/minimal configs carry a synchronization date in their header.

## Validation

Run the fast Zsh contract checks:

```zsh
~/.config/zsh/tests/run-all.zsh --quick
```

Run the complete suite, including Python regressions and startup smoke tests:

```zsh
~/.config/zsh/tests/run-all.zsh --full
```

The runner exits non-zero when any step fails and can be used locally or in CI.
It also validates required tools and checks that platform package manifests
still match the canonical dependency registry.

## Startup Profiling

Use the milestone tracer when total startup time and `zprof` do not tell the
whole story:

```zsh
zsh_profile trace
ZSH_PROFILE_FAST_START=1 zsh_profile trace
```

The report starts before the child shell launches and ends when its first input
line is ready. It separates `.zshenv`, individual modules, function bundles,
`precmd`, and ZLE setup. This makes time spent before `.zshrc` visible too,
including work performed by the installed `~/.zshenv`.

`zsh_profile time` measures total startup, while `zsh_profile zprof` reports
function-level costs. `zsh_profile both` runs those two reports sequentially.
All profiling is opt-in; normal startup only performs inexpensive condition
checks and does not launch profiler subprocesses.

For automation, set `ZSH_STARTUP_TRACE=1` and
`ZSH_STARTUP_TRACE_FILE=/path/report.tsv`. The trace is written atomically with
mode `600`. `ZSH_STARTUP_TRACE_FINISH=precmd` provides a deterministic fallback
when no terminal is attached; interactive profiling uses the first ZLE
`line-init` boundary instead.

## Output Styling

Shared presentation helpers (the
[terminal style](../../terminal-style/Terminal-Style.md), which
`scripts/_shared-helpers.zsh` loads) use
`ZSH_UI_STYLE=auto|plain|ansi|gum` and honor `NO_COLOR`. Headings, sections,
cards, tables, summaries and logs are drawn natively in every mode, with a
rounded frame for headers only; Gum is reserved for confirmations, choices and
spinners. `zfuncs` also
accepts `ZFUNCS_STYLE` as a command-specific override. New functions follow the
[function authoring policy](../docs/Function-Authoring.md), including stable
data output, plain capture layouts, and Gum only for interactions.
