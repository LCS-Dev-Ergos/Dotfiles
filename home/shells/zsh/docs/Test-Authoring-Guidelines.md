# Zsh Test Authoring Guidelines

This document defines the conventions, formatting standards, and isolation invariants for authoring tests within the Zsh test suite (`home/shells/zsh/config/tests/`).

---

## 1. Core Principles

- **Zero Host Mutation**: Tests must execute in total isolation. Never touch the user's real `$HOME`, `$XDG_*` directories, active shell history, or global configuration.
- **Fail-Closed & Deterministic**: Tests must fail immediately on unexpected states and produce reproducible results regardless of the host environment.
- **Fast & Lightweight**: Mock external commands, long-running processes, and network requests. No test should execute live package management or remote network calls.
- **Read-Only Invariants**: Health probes and diagnostics under test must remain strictly read-only and avoid creating state paths on disk.

---

## 2. File Structure & Header Standard

Every test script must begin with a standardized 80-column header box, followed by shell options and fixture initialization.

```zsh
#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++++++ <NAME> TEST +++++++++++++++++++++++++++++++++++ #
# ============================================================================ #
# Verifies <summary of functionality, modules sourced, and core invariants>.
# Maximum width: 79-80 columns. Concise and high-signal.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

typeset test_root="${0:A:h:h}"
source "$test_root/tests/helpers.zsh" || return 1
typeset fixture_root
fixture_root="$(_zsh_test_temp_dir <fixture-label>)" || return 1
trap '
  command rm -rf -- "$fixture_root"
' EXIT
trap 'exit 130' INT TERM HUP
```

### Essential Shell Options

- `emulate -L zsh`: Restores standard Zsh behavior locally without user aliases or non-standard options.
- `setopt err_return pipefail`: Ensures errors propagate immediately through command pipelines.
- `umask 077`: Restricts all generated fixture files and directories to the test process only.

---

## 3. Environment Isolation & Mocking Policy

### 3.1 Environment Redirection

All path variables must be redirected explicitly to the fixture root:

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

### 3.2 Mocking Binaries

Place mock executables in `$fixture_root/bin` and prepend it to `$PATH`:

- Always set permissions to `700` (`command chmod 700 "$fixture_root/bin/<cmd>"`).
- Keep mock scripts minimal and deterministic.
- Assert side-effect absence after executing the mock (e.g. `[[ ! -e "$GOPATH" ]]`).

---

## 4. Code Layout & Formatting Standards

### 4.1 Vertical Spacing (Newlines)

Do not cluster unrelated commands into single unbroken code walls. Separate distinct logical phases with blank lines:

1. **Environment & directory setup**
2. **Mock binary generation**
3. **Module sourcing**
4. **Execution of the command under test**
5. **Assertions and verifications**

### 4.2 Variable Declarations & Exports

- **Do not cram multiple exports onto one line**:
  ```zsh
  # BAD:
  export HOME="$fixture_root/home" XDG_CACHE_HOME="$fixture_root/cache" PLATFORM=test

  # GOOD:
  export HOME="$fixture_root/home"
  export XDG_CACHE_HOME="$fixture_root/cache"
  export PLATFORM=test
  ```
- Use `typeset` for local and test-scoped variables.

---

## 5. Commenting Policy (High-Signal, Non-Verbose)

Comments must explain **why** something is done or describe **non-obvious shell constructs**, avoiding redundant restatements of trivial commands.

### Mandatory Comment Scenarios

1. **Mock Behavior**: Explain what the mock emulates and why specific inputs/markers are returned.
   ```zsh
   # Mock fnm: lists version, records default mutations, and emits multishell env exports.
   ```
2. **Cryptic Parameter Expansion & Subscripts**: Clarify advanced Zsh flags.
   ```zsh
   # Re-sourcing 80-languages.zsh must not duplicate the opam precmd hook.
   typeset -a opam_hooks=("${(@M)precmd_functions:#_zsh_opam_env_hook}")
   ```
3. **Cache Invalidation & Signatures**: Explain file format assumptions.
   ```zsh
   # Line 2 of path.cache holds the cache signature; changing USER must invalidate it.
   typeset old_signature="$(sed -n '2p' "$XDG_CACHE_HOME/zsh/path.cache")"
   ```
4. **Safety & Transactional Rollbacks**: Explain failure recovery semantics.
   ```zsh
   # Failed output must not be evaluated or suppress the next prompt retry.
   ```

---

## 6. Assertion Patterns & Diagnostics

### 6.1 Standard Assertion Pattern

Format error reporting with `print -u2` and return code `1` across multiple lines:

```zsh
[[ "$result" == *'expected_marker'* ]] || {
  print -u2 "FAIL: description of what failed: got ${(qqq)result}"
  return 1
}
```

### 6.2 Success Message & Footer

End every test script with a single standard `PASS:` line and the file terminator:

```zsh
print -r -- 'PASS: <concise summary of verified capabilities>'

# ============================================================================ #
# End of tests/<filename>.zsh
```
