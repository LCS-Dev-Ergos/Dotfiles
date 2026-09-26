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
    ├── conf.d/             Environment-specific integration (HyDE)
    ├── completions/        Compinit-compatible `_name` files
    ├── scripts/            Lazy command modules and Python backends
    ├── others/             Standalone minimal/server configurations
    ├── prompt.zsh          Intentional HyDE prompt opt-out
    └── user.zsh            HyDE preferences
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
home-manager switch --flake '.#lcs-dev@lcs-legion-arch'
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
details live in `docs/zsh-dependencies.md` beside this configuration. The
module itself installs only what nothing else needs: gawk and shdoc.

## Startup architecture

### Development environment health

`devdoctor` reports the configured runtime managers and development tools.
The source is `scripts/dev-doctor.zsh`; `~/.cache/zsh/lazy-scripts.zsh` contains
generated loader stubs and must not be edited. The registry lives in
`packages/runtime-managers.tsv` beside the Home Manager module.

```zsh
devdoctor --only cc,cxx,clang,gcc,cmake,ccache,coursier,erlang
devdoctor --all --json
```

The optional thirteenth registry column, `runtime_cmd`, declares a local
startup probe. `version` reuses the existing version command; `-` leaves the
check at manager level. Other values are commands split into arguments,
without shell evaluation. Legacy twelve-column registries still load.

The optional fourteenth column, `group`, places the row in a report section:
`platform`, `systems`, `jvm`, `scripting`, `functional`, `science`, `apps` or
`other` (the default), shown in that order with rows sorted by label. The
styled report is a title bar plus one line per runtime with a colored state
marker; plain output (`ZSH_UI_STYLE=plain`, or a pipe) stays a single
untruncated table with a `GROUP` column, and `--json` adds a `group` field.
Python, Ruby, Java and Scala are started separately from their managers;
Scala reports its default Scala version using the offline version command.
Erlang reports the OTP release from a running VM.

The report includes selected `CC`/`CXX` commands (including launcher arguments),
Clang, GCC, CMake, ccache, Perl, .NET SDK, Bun, Android adb and Flutter. Flutter
reads cached version metadata and starts its bundled Dart VM: the Flutter
launcher itself can download artifacts even for a version request. Android
checks adb startup, not SDK platforms, licenses or emulator readiness.

A failed runtime startup is `broken` (exit 2). A timeout or missing version
output is `unknown` (exit 1). Empty managers and unactivated session managers
do not start their runtime shims. System fallbacks and package binaries behind
a correctly selected manager are expected; displaced managers and competing
unmanaged binaries still produce PATH warnings. `--updates` remains the
explicit remote tier. Local probe timeout defaults to five seconds and can be
adjusted with `DEVDOCTOR_TIMEOUT`.

`OK` means the declared probes succeeded. It does not certify arbitrary
projects, compilation, linking, every .NET global tool, Perl module, or
optional runtime extension. C/C++ compile/link/runtime coverage belongs to
the flake's `llvm-darwin-toolchain` check; `get_toolchain_info` and
`get_toolchain_sdk_support` provide detailed compiler and header diagnostics.

### Loading modules

The normal loader sources `lib/*.zsh` in lexical order, then `functions/*.zsh`,
and activates the prompt last. Modules are sourced at top level, never from a
function, so their plain `typeset` declarations stay global. A function file
opts into deferred loading with a header marker:

```zsh
# zsh-load: deferred
```

`ZSH_FAST_START=1` keeps the same loop but sources only the core listed in
`_ZSH_FAST_START_MODULES` (initialization, history, vi mode, aliases,
variables, PATH), skips the function bundles, and sets a static prompt. On
HyDE, `20-zinit.zsh` and `30-prompt.zsh` step aside through their own guards,
and the loop sources `conf.d/hyde/shell.zsh` in the plugin slot when HyDE owns
the plugins.

Current modules:

| Module                    | Responsibility                                                      |
| ------------------------- | ------------------------------------------------------------------- |
| `00-initialization.zsh`   | Shell options, defer engine, VS Code integration, macOS rc handling |
| `runtime-helpers.zsh`     | Colors, platform, mtime, permission checks, atomic cache writes     |
| `10-history.zsh`          | Shared, deduplicated history                                        |
| `20-zinit.zsh`            | Zinit, plugins, periodic compinit                                   |
| `30-prompt.zsh`           | Prompt definitions; activation follows final PATH assembly          |
| `40-vi-mode.zsh`          | Vi keymaps and cursor behavior                                      |
| `50-tools.zsh`            | Atuin, fzf, zoxide, direnv (cached init), Yazi, Kitty, OrbStack     |
| `60-aliases.zsh`          | Aliases and compilation shortcuts only                              |
| `70-ai-tools.zsh`         | Fabric and credential-scoped AI command wrappers                    |
| `75-variables.zsh`        | Language/application variables; no global compiler flags            |
| `80-languages.zsh`        | Language managers, lazy runtimes, change-driven opam env hook       |
| `85-completions.zsh`      | Cached generated completions                                        |
| `90-path.zsh`             | Deterministic PATH rebuild with signed 24-hour cache                |
| `94-lazy-loader-core.zsh` | Secure, auto-invalidating script stub generator                     |
| `95-lazy-scripts.zsh`     | On-demand commands from `scripts/*.zsh`                             |
| `96-lazy-cpp-tools.zsh`   | On-demand competitive-programming tools                             |

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

| Command               | Source                       | Purpose                                              |
| --------------------- | ---------------------------- | ---------------------------------------------------- |
| `extract`             | `functions/files.zsh`        | Extract common archive formats                       |
| `count`               | `functions/files.zsh`        | Count files, directories, links, and hidden entries  |
| `dirsize`             | `functions/files.zsh`        | Inspect directory sizes with the Python backend      |
| `mkcd`, `bak`, `up`   | `functions/core.zsh`         | Navigation and safe file backup helpers              |
| `note`, `bm`          | `functions/productivity.zsh` | Private notes and directory bookmarks                |
| `cleanup`, `zshcache` | `functions/productivity.zsh` | Cache cleanup and compinit rebuild                   |
| `fabric-pattern`      | `lib/70-ai-tools.zsh`        | Run Fabric patterns without global wrapper functions |
| `zfuncs`              | `functions/zfuncs.zsh`       | List and validate documented public functions        |
| `h`                   | `functions/cli-tools.zsh`    | Colorized command help through bat                   |
| `hlp`                 | `lib/50-tools.zsh`           | Tldr with man fallback                               |

### Network and Documents

| Command                    | Source                  | Purpose                                             |
| -------------------------- | ----------------------- | --------------------------------------------------- |
| `weather`, `myip`          | `functions/network.zsh` | Remote weather and public-IP information            |
| `portscan`, `serve`        | `functions/network.zsh` | Port probe and guarded local HTTP server            |
| `shorten`, `cheat`         | `functions/network.zsh` | is.gd and cheat.sh clients with shared URL encoding |
| `qr`                       | `functions/network.zsh` | Local QR via `qrencode`, explicit remote fallback   |
| `pdfcompress`, `pdfrotate` | `functions/pdf.zsh`     | PDF compression and rotation                        |
| `remove_pdf_watermarks`    | `functions/pdf.zsh`     | Structural watermark analysis/removal               |
| `remove_pdf_metadata*`     | `functions/pdf.zsh`     | qpdf/exiftool metadata cleanup                      |

### Development and Operations

| Command                                | Source                                 | Purpose                                               |
| -------------------------------------- | -------------------------------------- | ----------------------------------------------------- |
| `toolchain`, `get_toolchain_info`      | `scripts/toolchain-information.zsh`    | Show active compiler resolution                       |
| `use_llvm`, `use_gnu`, `use_system`    | `scripts/toolchain-selection.zsh`      | Reversible per-session toolchain selection            |
| `fnm_clean`, `zsh_profile`, `zshdeps`  | `functions/development-tools.zsh`      | Maintain fnm, profile startup, inspect dependencies   |
| `brew_stats`                           | `functions/package-management.zsh`     | Report installed Homebrew package sizes               |
| `security_scan`, `secscan`             | `scripts/security-scan.zsh`            | Structural, YARA, and ClamAV file scanning            |
| `vscode_sync_*`                        | `scripts/vscode-sync.zsh`              | Setup, update, check, status, and remove VS Code sync |
| `vscode_clean_extensions`              | `scripts/vscode-extension-cleaner.zsh` | Quarantine duplicate extensions                       |
| `utm_ubuntu_start`, `utm_ubuntu_login` | `scripts/utm-ubuntu.zsh`               | Start/login to the UTM Ubuntu VM                      |

### Blog Workflow

`scripts/blog-auto-updates.zsh` is a compatibility loader. Shared primitives
live in `scripts/blog/_common.zsh`, commands in `scripts/blog/commands.zsh`,
and canonical Python backends in `scripts/blog/python/`.

| Command                                                    | Purpose                                      |
| ---------------------------------------------------------- | -------------------------------------------- |
| `blog_sync_posts`                                          | Guarded backup plus Obsidian→Hugo mirror     |
| `blog_detect_changes`                                      | Git or hash-based change detection           |
| `blog_update_frontmatter`, `blog_process_images`           | Invoke canonical Python transforms           |
| `blog_build_hugo`, `blog_commit_changes`, `blog_push_main` | Build and publish the main branch            |
| `blog_deploy_hostinger`                                    | Subtree deployment with `--force-with-lease` |
| `blog_run_all`                                             | Locked end-to-end workflow                   |
| `blog_status`, `blog_help`                                 | Diagnostics and usage                        |

The sync refuses an empty Markdown source, creates a pre-sync backup before
`rsync --delete`, sends logs to stderr so command substitutions remain clean,
and uses an atomic mkdir lock to prevent concurrent full runs.

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
- 1Password values are cached in non-exported shell variables and exposed only
  to the intended child command (`claude`, `gemini`, or `opencode`).
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
`use_system` to restore its original state. Project-specific flags belong in
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

Shared presentation helpers use `ZSH_UI_STYLE=auto|plain|ansi|gum` and honor
`NO_COLOR`. Headings, sections, cards, tables, and logs are drawn natively in
every mode; Gum is reserved for confirmations and spinners. `zfuncs` also
accepts `ZFUNCS_STYLE` as a command-specific override. New functions follow the
[function authoring policy](../docs/function-authoring.md), including stable
data output, plain capture layouts, and Gum only for interactions.
