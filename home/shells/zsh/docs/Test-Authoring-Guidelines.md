# Zsh Test Authoring Policy

Regression and integration tests verify shell modules, public functions, and CLI
tools without mutating the host environment. Each test executes in an isolated
subshell or disposable fixture, produces predictable exit codes, and documents
the invariants it asserts.

## Naming and Organization

- Place Zsh unit and contract tests in `test-<name>.zsh` within their domain
  directory below `home/shells/zsh/config/tests/`: `core/`, `runtime/`,
  `languages/`, `functions/`, or `tools/`.
- Place Python-driven PTY and integration tests below
  `home/shells/zsh/config/tests/integration/` in `core/` or `tools/`.
- Shared fixture generation and cleanup routines live in `tests/helpers.zsh`.
  Do not duplicate temp-directory or symlink-resolution logic across individual tests.

## Test Structure

Every test script begins with standard shell options and a fixed 80-column banner
specifying the module under test and its primary invariants. Resolve the
configuration directory from the script's depth and initialize an isolated fixture
root with immediate signal and exit traps:

```zsh
#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ EXAMPLE TOPIC TEST ++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies functions/example.zsh: input validation, cache invalidation on
# state change, and fail-closed error handling under unexpected arguments.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir example-topic)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP
```

- `emulate -L zsh` restores clean Zsh behavior without user aliases or non-standard options.
- `setopt err_return pipefail` guarantees immediate error propagation across pipeline stages.
- `umask 077` secures generated test files and directories to the test process alone.
- `_zsh_test_temp_dir` provides a normalized, canonical temporary root (`/private/tmp`
  on macOS) to avoid path comparison mismatches against `:A`-resolved values.

## Isolation and Fixtures

Tests must never touch the user's live `$HOME`, shell history, active tmux sessions,
or deployed configuration. Redirect every environment variable explicitly to the fixture root:

```zsh
export HOME="$fixture_root/home"
export XDG_CACHE_HOME="$fixture_root/cache"
export XDG_DATA_HOME="$fixture_root/data"
export XDG_STATE_HOME="$fixture_root/state"
export TMPDIR="$fixture_root/tmp"
export TMPPREFIX="$TMPDIR/zsh"
export ZSH_CONFIG_DIR="$test_root"
export ZSH_UI_STYLE=plain
```

Health probes, diagnostics, and environment queries under test must remain
strictly read-only. Assert that probes do not produce side effects on disk, such as
creating an absent `GOPATH` or leaving uncommitted temporary caches behind. External
network requests and live package installations are prohibited.

## Mocking and Subprocesses

When testing integrations with external binaries, generate executable mocks inside
`$fixture_root/bin` and prepend that directory to `$PATH`:

```zsh
command mkdir -p "$fixture_root/bin"
print -rl -- '#!/bin/sh' 'echo "mock output"' > "$fixture_root/bin/sample-cmd"
command chmod 700 "$fixture_root/bin/sample-cmd"
```

- Mock executables must be minimal, deterministic, and self-contained.
- When verifying transactional rollbacks or delegation arguments, write calls to
  a shared log file inside the fixture root (`$fixture_root/calls.log`) and assert
  both exit status and the absence of partial or corrupted state files.

## Layout and Comments

Structure the script in sequential, logically separated blocks. Separate setup,
mocking, sourcing, command execution, and assertions with blank lines. Do not
concatenate unrelated statements or multiple `export` commands onto a single line.

Comments should be concise, high-signal, and explain non-obvious shell constructs:

- **Mock rationale**: document what the stub simulates and why specific markers or
  exit statuses are emitted.
- **Zsh parameter expansions**: clarify advanced subscript or pattern flags such as
  `${(@M)...}` or `${path[(Ie)...]}`.
- **Cache signatures**: explain structural assumptions when parsing headers or
  metadata lines (such as `sed -n '2p'`).
- **Invariants**: state why a particular failure condition or rollback is tested.

End every shell test with a single standard status report:

```zsh
print -r -- 'PASS: concise summary of verified behavior'

# ============================================================================ #
# End of tests/<category>/test-<name>.zsh
```

## Assertion Patterns and Diagnostics

Tests fail closed. Report unexpected outcomes to stderr with `print -u2`, include the
actual value received where helpful, and return status 1 immediately:

```zsh
[[ "$result" == *'expected_marker'* ]] || {
  print -u2 "FAIL: description of assertion failure: got ${(qqq)result}"
  return 1
}
```

Verify numeric exit codes with arithmetic evaluations (`(( rc == 2 )) || { ... }`).
Ensure temporary or scratch files are cleaned up even when tests terminate early.

## Validation

Run the relevant category before committing changes:

```zsh
home/shells/zsh/config/tests/run-all.zsh --quick --category <category>
```

Run the complete verification suite before merging:

```zsh
home/shells/zsh/config/tests/run-all.zsh --quick
home/shells/zsh/config/tests/run-all.zsh --full
```
