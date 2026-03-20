# VS Code Sync Python Migration Plan

## Summary

This document proposes a targeted migration from the current shell-heavy VS Code sync workflow to a hybrid architecture:

- thin shell wrappers for user ergonomics and dotfiles integration
- a Python core for scanning, planning, validation, cleanup, and reporting

The goal is not a full rewrite on day one. The safest path is an incremental migration that preserves the current command surface while moving the fragile logic into a more testable and maintainable runtime.

## Why Migrate

The current implementation works, but it now solves a problem that is larger than a typical shell script:

- extension discovery across Stable and Insiders
- exclusion rules for edition-specific extensions
- symlink repair and drift detection
- duplicate cleanup with manifest-aware reference protection
- dry-run and delete modes
- CLI orchestration for `code` and `code-insiders`
- path-safety and temporary-directory handling

Shell is still a good fit for small wrappers and CLI invocation, but it becomes expensive to maintain when the core logic requires:

- structured data manipulation
- JSON parsing
- multi-step planning
- stateful safety checks
- deterministic testing

## Migration Goals

1. Preserve the existing user-facing commands.
2. Reduce fragile shell logic and quoting/trap complexity.
3. Make cleanup behavior easier to reason about and test.
4. Improve performance by scanning once and planning in memory.
5. Make future features easier to add, especially richer reporting and smarter policies.

## Non-Goals

1. Do not change the canonical shared extension root design.
2. Do not remove shell wrappers entirely.
3. Do not introduce a hard dependency on third-party Python packages.
4. Do not force a big-bang rewrite.

## Recommended Architecture

### Shell Responsibilities

Keep shell responsible for:

- autoloading and aliases in zsh
- ergonomic wrapper commands such as `vscode_sync_update`
- locating `code` and `code-insiders`
- passing user flags and environment to Python
- fallback UX if Python is unavailable

### Python Responsibilities

Move Python to own:

- extension root scanning
- manifest parsing
- exclusion policy evaluation
- duplicate and stale-reference detection
- symlink plan generation
- cleanup plan generation
- validation and path safety
- structured dry-run output
- apply mode execution

## Proposed Target Layout

This layout keeps the migration local to the current VS Code script area:

```text
zsh/.config/zsh/scripts/vscode/
  PYTHON_MIGRATION_PLAN.md
  sync.sh
  extension_cleaner.sh
  _common.sh
  sync/
    _core.sh
    commands.sh
    extensions.sh
  py/
    __init__.py
    cli.py
    config.py
    models.py
    scanner.py
    manifests.py
    policies.py
    planner.py
    applier.py
    reporter.py
    fs_utils.py
    tests/
      test_scanner.py
      test_manifests.py
      test_planner.py
      test_cleanup.py
      test_symlinks.py
      fixtures/
```

## Proposed Command Model

The shell commands should remain stable:

- `vscode_sync_status`
- `vscode_sync_check`
- `vscode_sync_setup`
- `vscode_sync_update`
- `vscode_clean_extensions`

The wrappers should call a Python CLI with explicit subcommands:

```text
python3 .../vscode/py/cli.py status
python3 .../vscode/py/cli.py check
python3 .../vscode/py/cli.py setup
python3 .../vscode/py/cli.py update
python3 .../vscode/py/cli.py clean
```

Suggested Python flags:

- `--stable-dir`
- `--insiders-dir`
- `--exclude-file`
- `--dry-run`
- `--json`
- `--apply`
- `--strategy newest|oldest`
- `--respect-references`

## Data Model

Python should use small explicit models instead of ad hoc shell records.

Suggested entities:

- `ExtensionInstall`
  - `name`
  - `core`
  - `version`
  - `path`
  - `is_symlink`
  - `symlink_target`
  - `mtime`
  - `edition`

- `ReferenceEntry`
  - `folder_name`
  - `manifest_path`
  - `source_kind`

- `CleanupDecision`
  - `extension`
  - `action`
  - `reason`
  - `protected_by_reference`
  - `shadowed_by`

- `SymlinkDecision`
  - `target_name`
  - `action`
  - `reason`

- `UpdatePlan`
  - `shared_updates`
  - `insiders_native_updates`
  - `cleanup_actions`
  - `symlink_actions`
  - `warnings`

## Migration Strategy

### Phase 0: Freeze Behavior and Capture Baseline

Before moving logic, capture the current behavior.

Tasks:

- record the current shell command contract
- create fixture directories for duplicate versions, broken symlinks, unmanaged real directories, and excluded extensions
- save a few representative dry-run outputs as golden references
- document current exclusions and assumptions

Acceptance criteria:

- current shell behavior is reproducible in fixtures
- baseline scenarios are documented

### Phase 1: Introduce Python Scanner and Manifest Parser

Build Python modules for read-only analysis first.

Tasks:

- implement extension directory scanning with `pathlib`
- implement folder-name parsing
- implement JSON manifest parsing using the standard library
- implement reference collection scoped to Stable or Insiders
- implement path canonicalization and safety helpers

Do not change shell behavior yet.

Acceptance criteria:

- Python can print the same discovered installs as shell
- Python can list references from the same manifest fixtures
- no mutation yet

### Phase 2: Introduce a Read-Only Planner

Add a Python planner that produces a structured plan for:

- duplicate cleanup
- stale reference filtering
- expected Insiders symlinks
- broken symlink detection
- unmanaged real directory detection

Tasks:

- create a deterministic in-memory planner
- add `--json` output for debugging and tests
- compare planner output against fixture expectations

Acceptance criteria:

- planner explains what would be deleted, skipped, or linked
- fixture tests cover the old-version-still-referenced case

### Phase 3: Migrate the Cleaner First

The cleaner is the best first mutation target because it has the highest complexity-to-value ratio.

Tasks:

- implement `clean --dry-run`
- implement `clean --apply`
- preserve current strategy semantics
- preserve current safety rules
- preserve current confirmation behavior in the shell wrapper

Wrapper behavior:

- shell continues to expose `vscode_clean_extensions`
- shell delegates to Python for planning and apply

Acceptance criteria:

- Python cleaner matches shell dry-run results on fixtures
- Python cleaner correctly treats stale refs as deletable
- delete mode only touches paths under the selected root

### Phase 4: Migrate Status, Check, and Setup

After cleanup is stable, move symlink analysis and repair.

Tasks:

- implement expected Insiders symlink computation
- detect missing symlinks, broken symlinks, and unmanaged real dirs
- implement a repair plan
- expose `status`, `check`, and `setup`

Acceptance criteria:

- Python reports the same drift detected by shell
- setup can repair broken symlinks and remove unmanaged leftovers
- exclusions remain respected

### Phase 5: Migrate Update Orchestration

The update workflow should remain hybrid, but the plan should come from Python.

Tasks:

- let Python compute:
  - which shared updates run against `~/.vscode/extensions`
  - which excluded Insiders-native extensions must be updated separately
  - what cleanup and relink steps follow
- shell wrapper remains responsible for invoking `code` and `code-insiders`

Suggested flow:

1. Python builds the update plan.
2. Shell executes the actual VS Code CLI commands.
3. Python executes cleanup and symlink repair.
4. Shell prints a concise summary.

Acceptance criteria:

- one command still drives the whole workflow
- dry-run remains available
- edition-specific exclusions are preserved

### Phase 6: Retire Redundant Shell Logic

Once the Python path is proven stable, shell scripts should be simplified.

Tasks:

- remove duplicated scanning and planning logic from shell
- keep only bootstrapping, environment, and wrapper UX
- preserve compatibility aliases

Acceptance criteria:

- shell becomes a thin wrapper layer
- there is only one authoritative planner

## Safety Requirements

The Python implementation must preserve or improve all current guardrails.

Required guarantees:

1. Canonicalize paths before any delete operation.
2. Refuse to mutate paths outside the selected extension root.
3. Support dry-run as the default for destructive subcommands.
4. Keep edition-specific exclusions explicit and testable.
5. Separate planning from apply wherever possible.
6. Emit reasons for each skipped or protected item.

## Performance Strategy

Python should improve performance mostly by simplifying the algorithm:

- scan each root once
- parse manifests once per run
- group installs in memory by `core`
- compute newest, oldest, and stale-reference decisions without repeated file scans
- avoid shell pipelines and repeated `cut`, `grep`, and `sort` over intermediate files

This is likely enough for the current dataset size. More advanced optimization is optional.

## Testing Strategy

### Unit Tests

Add Python unit tests for:

- folder-name parsing
- version comparison
- manifest parsing
- stale-reference filtering
- duplicate grouping
- exclusion handling
- path-safety checks

### Fixture Tests

Add filesystem fixtures for:

- duplicate versions with no references
- duplicate versions where both old and new are referenced
- excluded Insiders-native extensions
- broken symlink in Insiders
- unmanaged real directory in Insiders
- missing expected symlink

### Integration Tests

Add integration tests that run the Python CLI against fixture roots and verify:

- JSON plan output
- dry-run text output
- apply behavior
- no mutation outside target roots

## Rollout Plan

Use a staged rollout with a fallback path.

1. Land Python read-only modules and tests.
2. Add optional shell wrappers that can call Python behind a feature flag.
3. Compare shell and Python dry-runs on real data for a period.
4. Switch cleaner to Python by default.
5. Switch status and setup to Python by default.
6. Switch update planning to Python by default.
7. Remove redundant shell planning code after confidence is high.

Suggested feature flag:

```text
VSCODE_SYNC_USE_PYTHON=1
```

This allows quick rollback to the shell implementation during migration.

## Rollback Strategy

Rollback should be trivial until the final phase.

- keep legacy shell implementations during the transition
- route wrappers based on a feature flag
- keep output formats similar enough that regressions are easy to spot
- prefer additive changes before deletions

## Expected Benefits

### Maintainability

- fewer shell edge cases
- clearer separation between plan and execution
- easier reasoning about state and policy

### Robustness

- native JSON parsing
- safer path handling
- fewer quoting and trap hazards
- more deterministic logic

### Performance

- fewer repeated filesystem passes
- fewer temporary files
- less process spawning

### Extensibility

Future features become much easier, such as:

- `--json` output for tooling
- richer diagnostics
- policy files for exclusions
- explainable cleanup decisions
- snapshot or backup metadata

## Trade-Offs

This migration also has real costs:

- introduces a Python dependency
- adds another runtime to your dotfiles toolchain
- requires tests and packaging discipline
- creates a temporary period where shell and Python coexist

These trade-offs are acceptable if the goal is to reduce long-term fragility and make the workflow easier to evolve.

## Recommended First Deliverable

The best first deliverable is:

1. a Python read-only scanner
2. a Python manifest parser
3. a Python cleanup planner with fixture tests
4. a shell wrapper for `vscode_clean_extensions` behind a feature flag

This slice is small enough to be safe, but valuable enough to immediately reduce maintenance pressure in the most complex part of the system.

## Final Recommendation

Use a hybrid design.

- Keep shell for wrappers and CLI ergonomics.
- Move planning, cleanup, validation, and reporting into Python.
- Migrate incrementally, starting with the cleaner.

This approach should reduce fragile code, improve testability, and give you a much cleaner foundation without disrupting the commands you already use every day.
