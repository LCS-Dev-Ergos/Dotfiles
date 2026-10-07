# Zsh Test Suite Architecture

The Zsh verification suite separates unit, contract, and integration checks across
domain-driven categories below `home/shells/zsh/config/tests/`. A centralized runner
(`tests/run-all.zsh`) coordinates execution between quick shell-only regression passes
and full PTY/Python integration suites.

## Directory Structure

```text
home/shells/zsh/config/tests/
├── helpers.zsh                      # Shared test fixture and temp directory utilities
├── run-all.zsh                      # Central test runner entry point
├── core/                            # Shell startup, reload, and prompt lifecycle
│   ├── test-hyde-retirement.zsh
│   ├── test-prompt-initialization.zsh
│   ├── test-reload.zsh
│   └── test-startup-trace.zsh
├── runtime/                         # PATH ordering, caching, Nix and toolchain selection
│   ├── test-nix-path.zsh
│   ├── test-runtime-path.zsh
│   └── test-toolchain-selection.zsh
├── languages/                       # FNM, opam, Python, Go runtime integrations
│   ├── test-fnm-multishell.zsh
│   ├── test-go-runtime.zsh
│   └── test-language-integration.zsh
├── functions/                       # Public functions, security contracts, zfuncs and completions
│   ├── test-custom-completions.zsh
│   ├── test-function-safety.zsh
│   └── test-zfuncs.zsh
├── tools/                           # CLI scripts, devdoctor, dependencies, and shared UI
│   ├── test-brew-stats.zsh
│   ├── test-dependency-contract.zsh
│   ├── test-dev-doctor.zsh
│   ├── test-fabric-tools.zsh
│   ├── test-script-presentation.zsh
│   └── test-shared-ui.zsh
└── integration/                     # End-to-end PTY, tmux and Python-driven integration tests
    ├── core/                        # Interactive prompt, ZLE, and terminal resize
    │   ├── test-prompt-context.py
    │   ├── test-prompt-resize.py
    │   └── test-zle-lifecycle.py
    └── tools/                       # External tool hooks and background invalidation
        └── test-brew-refresh.py
```

## Domain Categories

- **core**: shell bootstrapping, fast-start profile sourcing, Starship prompt
  caching, canonical reload semantics, and desktop/HyDE isolation.
- **runtime**: interactive and non-interactive PATH precedence, cache
  invalidation across users and directories, Nix system profile exposure, and active
  compiler toolchain selection.
- **languages**: language runtime managers (FNM, opam, pyenv), multi-shell
  session isolation, local switch precedence, and non-destructive compiler probes.
- **functions**: public utility functions, fail-closed input validation, directory
  traversal prevention, `zfuncs` catalog indexing, and Shdoc completion generation.
- **tools**: standalone CLI scripts, developer diagnostics (`devdoctor`),
  dependency contract audits, AI tools (`fabric`), presentation contracts, and shared UI
  primitives.
- **integration/core**: real Starship/ZLE prompt behavior, tmux pane resizing,
  vi-mode keymap dispatching, and repository context rendering through disposable PTY sessions.
- **integration/tools**: Homebrew package mutations, provider refresh hooks, and
  background StatWell/SketchyBar cache invalidation.

## Runner Contract and Options

The unified runner `home/shells/zsh/config/tests/run-all.zsh` coordinates static analysis,
metadata verification, and test execution. It accepts options to adjust depth and scope:

- `--quick` (default) verifies dependency contracts, shell syntax on all maintained files,
  Shdoc metadata, function catalog indexing, and all Zsh unit tests.
- `--full` executes everything in `--quick`, plus Python unittest suites, PTY/tmux prompt
  resize tests, and an isolated fast-start interactive subshell.
- `--category <name>` restricts test execution to a specific domain (`core`, `runtime`,
  `languages`, `functions`, `tools`, or `integration`). When combined with `--full`, only
  the integration tests matching that category run.

## Execution and Isolation Invariants

Every test in the suite must adhere to three foundational guarantees:

1. **Zero Host Mutation**: No test may write to `$HOME`, modify user history, contact
   system daemons, or execute live package updates. All state belongs in a private fixture
   managed by `_zsh_test_temp_dir`.
2. **Fail-Closed Diagnostics**: Probes and assertions must fail immediately upon unexpected
   arguments or missing dependencies. Diagnostic tools must never create state on disk
   during read-only checks.
3. **Execution Performance**: Shell unit tests run in sub-second batches without spawning
   unnecessary subprocesses. PTY integration tests are isolated into `integration/` so that
   the default quick pass remains instantaneous.

## Inspection and Verification

Run the complete fast verification suite:

```zsh
home/shells/zsh/config/tests/run-all.zsh --quick
```

Run a specific category:

```zsh
home/shells/zsh/config/tests/run-all.zsh --quick --category runtime
home/shells/zsh/config/tests/run-all.zsh --category integration
```

Run the complete verification suite including PTY integration and smoke tests:

```zsh
home/shells/zsh/config/tests/run-all.zsh --full
```
