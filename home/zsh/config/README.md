# Zsh configuration

Modular Zsh configuration for macOS and Linux/Arch, deployed by Home Manager.
The default interactive startup defers expensive integrations and activates the
prompt only after deterministic PATH assembly. Filesystem and cache operations
are validated before executable shell code is sourced.

## Bootstrap and installation

The repository uses this layout:

```text
Dotfiles/home/zsh/
├── default.nix             Home Manager ownership and platform policy
├── zshenv-bootstrap        reproducible ~/.zshenv bootstrap
├── zprofile                login-shell environment
├── zshrc                   interactive loader
├── p10k.zsh                Powerlevel10k configuration
├── Brewfile                generated macOS dependency view
├── packages/               canonical dependency registry and Arch view
├── docs/                   focused operational documentation
└── config/                 deployed as ~/.config/zsh
    ├── .zshenv             environment shared by all shell types
    ├── lib/                ordered startup modules
    ├── functions/          interactive command bundles
    ├── conf.d/             environment-specific integration (HyDE)
    ├── completions/        compinit-compatible `_name` files
    ├── scripts/            lazy command modules and Python backends
    ├── others/             standalone minimal/server configurations
    ├── prompt.zsh          intentional HyDE prompt opt-out
    └── user.zsh            HyDE preferences
```

### Naming convention

Shell sources, scripts, fixtures, and documentation use descriptive
`kebab-case` filenames. Abbreviations are limited to established technical or
product names such as Zsh, CLI, AI, PDF, C++, FZF, VS Code, and OCI. A leading
underscore marks a private module; completion files retain Zsh's `_command`
contract. Python modules and `test_*.py` files use `snake_case`, as required by
Python imports and test discovery. Standard dotfiles and generated artifacts
keep the names imposed by their respective tools.

Provision the macOS host from the repository root with:

```zsh
sudo darwin-rebuild switch --flake .#LCSMacBook-Pro --impure
```

For the standalone Linux Home Manager output, use:

```zsh
home-manager switch --flake '.#lcs-dev@lcs-legion-arch'
```

Home Manager installs `~/.zshenv` from `zshenv-bootstrap`, links `zprofile`,
`zshrc`, and `p10k.zsh` to their writable repository sources, and deploys the
complete `config/` tree at `~/.config/zsh`. The bootstrap loads Cargo, sets the
static Homebrew environment without running `brew shellenv` in every process,
and then sources `~/.config/zsh/.zshenv`.

On macOS, nix-darwin deliberately leaves `programs.zsh.enable` disabled while
Homebrew owns the login-shell binary and Home Manager owns its configuration.
The repository `.zshenv` loads the standard multi-user Nix environment only
when no system initializer has already done so. On Linux, Home Manager installs
the Zsh binary as well as managing the same shared configuration.

Supported dependencies are declared once in
`packages/zsh-dependencies.tsv`. The generated `Brewfile` and Arch package list
provide reproducible platform inventories; installation and trust details live
in `docs/zsh-dependencies.md` beside this configuration.

## Startup architecture

The normal loader sources `lib/*.zsh` in lexical order, then `functions/*.zsh`.
A function file opts into deferred loading with a header marker:

```zsh
# zsh-load: deferred
```

Current modules:

| Module                    | Responsibility                                                      |
| ------------------------- | ------------------------------------------------------------------- |
| `00-initialization.zsh`   | shell options, defer engine, VS Code integration, cache maintenance |
| `runtime-helpers.zsh`     | colors, platform, mtime, permission checks, atomic cache writes     |
| `10-history.zsh`          | shared, deduplicated history                                        |
| `20-zinit.zsh`            | Zinit, plugins, periodic compinit                                   |
| `30-prompt.zsh`           | prompt definitions; activation follows final PATH assembly          |
| `40-vi-mode.zsh`          | vi keymaps and cursor behavior                                      |
| `50-tools.zsh`            | Atuin, fzf, zoxide, direnv, Yazi, Kitty, OrbStack, man/tldr         |
| `60-aliases.zsh`          | aliases and compilation shortcuts only                              |
| `70-ai-tools.zsh`         | Fabric and credential-scoped AI command wrappers                    |
| `75-variables.zsh`        | language/application variables; no global compiler flags            |
| `80-languages.zsh`        | language managers and lazy runtime initialization                   |
| `85-completions.zsh`      | cached generated completions                                        |
| `90-path.zsh`             | deterministic PATH rebuild with signed 24-hour cache                |
| `94-lazy-loader-core.zsh` | secure, auto-invalidating script stub generator                     |
| `95-lazy-scripts.zsh`     | on-demand commands from `scripts/*.zsh`                             |
| `96-lazy-cpp-tools.zsh`   | on-demand competitive-programming tools                             |

`ZSH_FAST_START=1` loads only the minimal core. Other useful toggles include
`ZSH_DEFER_COMPLETIONS`, `ZSH_LAZY_SCRIPTS`, `ZSH_LAZY_CPP_TOOLS`,
`ZSH_CUSTOM_COMPLETIONS`, and `ZSH_CACHE_AUTO`.

Public shdoc metadata also generates completion specifications for custom
commands. Generation is deferred and cached securely; pressing Tab only calls
the in-memory `_arguments` completer. Existing specialized completions always
take precedence over the generated baseline.

## Command index

### Files, navigation, and productivity

| Command               | Source                       | Purpose                                              |
| --------------------- | ---------------------------- | ---------------------------------------------------- |
| `extract`             | `functions/files.zsh`        | extract common archive formats                       |
| `count`               | `functions/files.zsh`        | count files, directories, links, and hidden entries  |
| `dirsize`             | `functions/files.zsh`        | inspect directory sizes with the Python backend      |
| `mkcd`, `bak`, `up`   | `functions/core.zsh`         | navigation and safe file backup helpers              |
| `note`, `bm`          | `functions/productivity.zsh` | private notes and directory bookmarks                |
| `cleanup`, `zshcache` | `functions/productivity.zsh` | cache cleanup/rebuild and bytecode compilation       |
| `fabric-pattern`      | `lib/70-ai-tools.zsh`        | run Fabric patterns without global wrapper functions |
| `zfuncs`              | `functions/zfuncs.zsh`       | list and validate documented public functions        |
| `h`                   | `functions/cli-tools.zsh`    | colorized command help through bat                   |
| `hlp`                 | `lib/50-tools.zsh`           | tldr with man fallback                               |

### Network and documents

| Command                    | Source                  | Purpose                                             |
| -------------------------- | ----------------------- | --------------------------------------------------- |
| `weather`, `myip`          | `functions/network.zsh` | remote weather and public-IP information            |
| `portscan`, `serve`        | `functions/network.zsh` | port probe and guarded local HTTP server            |
| `shorten`, `cheat`         | `functions/network.zsh` | is.gd and cheat.sh clients with shared URL encoding |
| `qr`                       | `functions/network.zsh` | local QR via `qrencode`, explicit remote fallback   |
| `pdfcompress`, `pdfrotate` | `functions/pdf.zsh`     | PDF compression and rotation                        |
| `remove_pdf_watermarks`    | `functions/pdf.zsh`     | structural watermark analysis/removal               |
| `remove_pdf_metadata*`     | `functions/pdf.zsh`     | qpdf/exiftool metadata cleanup                      |

### Development and operations

| Command                                | Source                                 | Purpose                                               |
| -------------------------------------- | -------------------------------------- | ----------------------------------------------------- |
| `toolchain`, `get_toolchain_info`      | `scripts/toolchain-information.zsh`    | show active compiler resolution                       |
| `use_llvm`, `use_gnu`, `use_system`    | `scripts/toolchain-selection.zsh`      | reversible per-session toolchain selection            |
| `fnm_clean`, `zsh_profile`, `zshdeps`  | `functions/development-tools.zsh`      | maintain fnm, profile startup, inspect dependencies   |
| `security_scan`, `secscan`             | `scripts/security-scan.zsh`            | structural, YARA, and ClamAV file scanning            |
| `vscode_sync_*`                        | `scripts/vscode-sync.zsh`              | setup, update, check, status, and remove VS Code sync |
| `vscode_clean_extensions`              | `scripts/vscode-extension-cleaner.zsh` | quarantine duplicate extensions                       |
| `utm_ubuntu_start`, `utm_ubuntu_login` | `scripts/utm-ubuntu.zsh`               | start/login to the UTM Ubuntu VM                      |

### Blog workflow

`scripts/blog-auto-updates.zsh` is a compatibility loader. Shared primitives
live in `scripts/blog/_common.zsh`, commands in `scripts/blog/commands.zsh`,
and canonical Python backends in `scripts/blog/python/`.

| Command                                                    | Purpose                                      |
| ---------------------------------------------------------- | -------------------------------------------- |
| `blog_sync_posts`                                          | guarded backup plus Obsidian→Hugo mirror     |
| `blog_detect_changes`                                      | Git or hash-based change detection           |
| `blog_update_frontmatter`, `blog_process_images`           | invoke canonical Python transforms           |
| `blog_build_hugo`, `blog_commit_changes`, `blog_push_main` | build and publish the main branch            |
| `blog_deploy_hostinger`                                    | subtree deployment with `--force-with-lease` |
| `blog_run_all`                                             | locked end-to-end workflow                   |
| `blog_status`, `blog_help`                                 | diagnostics and usage                        |

The sync refuses an empty Markdown source, creates a pre-sync backup before
`rsync --delete`, sends logs to stderr so command substitutions remain clean,
and uses an atomic mkdir lock to prevent concurrent full runs.

## Security decisions

- Cache/config files are sourced only when owned by the current user, readable,
  non-symlinks, and not group/world-writable.
- Cache writes use user-only temporary files followed by atomic rename.
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

## Toolchain policy

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

## Startup profiling

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

## Output styling

Shared presentation helpers use `ZSH_UI_STYLE=auto|plain|ansi|gum` and honor
`NO_COLOR`. Gum is reserved for one-shot headings, cards, confirmations, and
static tables; repeated logs and sections stay shell-native. `zfuncs` also
accepts `ZFUNCS_STYLE` as a command-specific override. New functions follow the
[function authoring policy](../../docs/function-authoring.md), including stable
data output, mandatory native fallbacks, and a strict Gum process budget.
