# Starship Context and Prompt Resizing

The Starship prompt keeps two lines: every piece of information on the first,
the input on the second. The first line starts with identity, containers,
directory and Git state; after a thin `│`, shown only when there is anything
behind it, come jobs, elapsed command time, environments, Docker/Kubernetes,
toolchains and low battery. The second line holds command failures and the
input character. There is no clock and no right prompt (`right_format` is
empty and Zsh's RPROMPT stays unset, which also saves a Starship process per
prompt).

Directly in kitty the context is right-aligned instead, with `$fill` taking
the place of the bar. Home Manager generates that variant as
`starship-kitty.toml` from the same TOML, and `30-prompt.zsh` selects it only
where kitty itself repairs resizing; see [Resizing](#resizing).

## Reading the prompt

- The first line stays focused on the working location, branch and pending
  changes. Merge/rebase progress and conflicts remain visible on this side.
  Detached worktrees show the commit instead of a misleading attached branch.
- Git uses native file counts: `+2` staged, `!3` modified, `?1` untracked,
  `»1` renamed, `−1` deleted, `≠1` type changed, `≡1` stashed, `×1` conflicted.
  `↑2 ↓1` shows divergence from the tracked branch. A file can contribute to
  both staged and modified counts. Clean repositories have no status clutter.
- Python reports the interpreter a project actually uses, without starting
  Python through a pyenv shim (about 200 ms per prompt). Home Manager puts
  `scripts/python-version.sh` first in `python_binary`: it reads the version
  from an active virtualenv or the nearest project `.venv` (the one `uv run`
  uses, activated or not; `$HOME/.venv` does not count), otherwise runs the
  pyenv-selected interpreter directly (`PYENV_VERSION`, nearest
  `.python-version`, global version file), otherwise `python` from PATH.
  Generic `.venv`, `venv` and `env` names are replaced by the parent project
  name. Notebooks also trigger Python detection.
- Language versions sit in the context and disappear when unavailable instead
  of leaving empty icons. Bun is detected from its own lock/config files.
  C/C++ deliberately show project markers only: querying the local compiler
  wrapper added about 50 ms. These two icons do not certify compiler availability.
- A failed pipeline shows its individual exit codes, e.g. `[1 | 0]`, even
  when its last command succeeds. Successful pipelines remain quiet. The
  input arrow still reflects the shell's overall exit status, so it can be
  green beside a failed early stage when `pipefail` is off.
- The context shows the number even for one background job, elapsed time
  after two seconds, and battery only at 30% or below. Nix and Conda retain
  their environment names. Docker continues showing non-default targets even
  outside a project; it reads context locally without contacting the daemon.

The former `custom.git_status` remains disabled as an opt-in fallback. To
restore its line metrics, disable `git_status` and enable `custom.git_status`;
`$custom` is still in the left layout. The default no longer starts that Zsh
script or runs its `git diff --numstat` on every dirty prompt.

The design borrows conditional information and compact grouping from
[No Empty Icons](https://starship.rs/presets/no-empty-icons),
[No Runtime Versions](https://starship.rs/presets/no-runtime-versions), and
[Bracketed Segments](https://starship.rs/presets/bracketed-segments), while
retaining the thin frame and Tokyo Night palette. Module behavior is documented
in the official [Starship configuration reference](https://starship.rs/config/).

[Geometry](https://github.com/geometry-zsh/geometry) is a Zsh theme, and
[Jetpack](https://starship.rs/presets/jetpack) takes inspiration from it and
Spaceship. The useful overlap here is contextual information, clear command
status and compact Git state. Jetpack also includes a clock and Git line
metrics, and hides `main`/`master`; those choices are not used here, and
`$fill` only appears in the kitty variant. Keep the existing chevron/vi-mode semantics and palette.
Geometry's asynchronous renderer and extra information on empty Enter would
require new shell behavior and are not part of this refinement.

## Prompt and vi lifecycle

`lib/30-prompt.zsh` and `lib/40-vi-mode.zsh` share Zsh's native
`add-zle-hook-widget` dispatcher. Existing line-init, line-finish and keymap
widgets are preserved, and repeated registration does not duplicate them.
Starship's init runs with its keymap widget temporarily isolated, then joins
the shared hook list. This prevents its generated wrapper from calling itself
after repeated initialization; the previous widget is restored even on failure.

- A new line already starts in `main`, linked to `viins`. Avoiding a redundant
  `zle -K viins` removes a keymap event and a second Starship redraw per line.
- Transient spacing uses explicit state rather than redefining `_tp_precmd`.
  It leaves the caller's SIGINT trap intact; Ctrl+C still uses the send-break
  widget. Its pending descriptor is unregistered and closed before a reload.
- Cursor changes are emitted only on a suitable terminal and when the shape
  changes. Accepting a command restores the terminal default before execution.
  Existing vi bindings and the VS Code injection compatibility guard remain.
- Ctrl+O reports clipboard failures instead of claiming the directory was copied.

These changes use shell builtins and existing Zsh functions. There is no custom
resize handler, background rendering process, polling or runtime Python code.
See the official [Zsh hook documentation](https://zsh.sourceforge.io/Doc/Release/User-Contributions.html#Manipulating-Hook-Functions)
and [special widgets](https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html#Special-Widgets).

## Resizing

A terminal (or multiplexer) that shrinks re-wraps every line wider than its
new width. ZLE then redraws the prompt from where it believes the prompt
starts, which no longer matches the screen: rows of the old first line stay
behind as duplicate headers. It happens to any two-line prompt whose first
line is wider than the new width, whatever draws it (Powerlevel10k and
Oh My Posh document the same limit), and `TRAPWINCH` with `zle reset-prompt`
runs too late to help. A custom renderer that tracked the header itself was
explored and dropped as too fragile.

Two facts make a single information line workable anyway:

- **Nothing is padded to the terminal width.** `$fill` turns the first line
  into width-long text that re-wraps on every shrink. Without it the line is
  as long as its content, typically 40 to 90 cells, so resizes that stay at
  least that wide leave no trace. Narrower than the line itself, the old
  duplicates remain possible.
- **kitty repairs the rest.** With its shell integration marking the prompt
  (`at_prompt` in `kitten @ ls`), kitty erases the prompt on resize and lets
  ZLE redraw it. There, and only there, `starship-kitty.toml` right-aligns the
  context with `$fill`. `_zsh_prompt_redrawn_by_kitty` requires
  `TERM=xterm-kitty`, loaded `_ksi_*` functions, no `no-prompt-mark`, and no
  multiplexer: tmux, herdr and zellij panes inherit kitty's variables but are
  re-wrapped by the multiplexer, and herdr panes run with
  `TERM=xterm-256color`. VS Code and other terminals get the TOML's layout.

Measured on 2026-09-25 (Zsh 5.9.2, Starship 1.26.0, tmux 3.7c, kitty 0.49.1):

| Layout and terminal                            | Result                                 |
| ---------------------------------------------- | -------------------------------------- |
| `$fill` layout, tmux                           | duplicates at almost every shrink      |
| `$fill` layout, kitty without prompt marking   | 11 of 12 resize steps fail             |
| `$fill` layout, kitty with shell integration   | 12 of 12 pass, down to 33 columns      |
| One-line layout, tmux                          | passes down to its line width (46 + 2) |
| One-line layout, kitty without prompt marking  | passes down to its line width (51)     |

The kitty runs resized a real window through `kitten @ set-font-size`
(173 → 101 → 196 → 81 → 173 → 62 → 41 → 33 → 226 → 41 → 122 → 173 columns),
counting headers in the screen and scrollback with `kitten @ get-text`.

Run the integration test explicitly, or through the full Zsh suite:

```sh
python3 home/zsh/config/tests/python/test-prompt-resize.py
PYTHONDONTWRITEBYTECODE=1 python3 home/zsh/config/tests/python/test-prompt-context.py
PYTHONDONTWRITEBYTECODE=1 python3 home/zsh/config/tests/python/test-zle-lifecycle.py
zsh home/zsh/config/tests/run-all.zsh --full
```

It uses a private tmux socket, temporary HOME/config/cache and an empty working
directory. It skips if tmux, Starship or Zsh is unavailable. This is a tmux/ZLE
regression test, not visual acceptance for every terminal. The default run
resizes 100 → 60 → 110 → the information line's width plus two → 100 columns,
24 → 12 → 24 rows, then splits and removes a pane; it passes. The opt-in
stress run adds a shrink to 35 columns, narrower than the fixture's line, and
is expected to fail at exactly that step (everything after it still passes):

```sh
ZSH_PROMPT_RESIZE_STRESS=1 python3 home/zsh/config/tests/python/test-prompt-resize.py
```

## Performance check (2026-09-25)

`zsh_profile both` measured installed startup at 0.64 s and
`_init_starship_prompt` at 1.49 ms in zprof. This is one warm run of the
installed Zsh configuration, before the lifecycle changes above. The
command exits before displaying an interactive prompt and does not measure
rendering or repeated resize hooks. Passing STARSHIP_CONFIG to the parent
shell is not a valid candidate comparison: the startup variables module
resets it to the managed path. The rendering benchmark below passes the
candidate directly to Starship instead.

A separate warm comparison ran `starship prompt` and `starship prompt --right`
sequentially at 100 columns, including subprocess startup, with 3 warmups and
20 samples per configuration/directory in alternating order. The baseline
was the native-right layout at the start of this refinement, with the custom
Git script and clock still enabled.

| Working directory         | Previous median / p95 | Current median / p95 |
| ------------------------- | --------------------- | -------------------- |
| Empty temporary directory | 22.29 / 23.33 ms      | 21.83 / 22.41 ms     |
| Dotfiles working tree     | 64.31 / 76.25 ms      | 39.91 / 42.59 ms     |
| Temporary C++ project     | 22.62 / 24.13 ms      | 21.90 / 22.89 ms     |
| Temporary C project       | 74.37 / 100.76 ms     | 21.80 / 77.46 ms     |

These are local warmed measurements, not a cold-start benchmark or a bound
for large repositories. Git no longer invokes the custom shell/diff pair;
C/C++ markers require no compiler subprocess. Bun queries its version only
in a matching project, like the other runtime modules. Python is used only
by the tests.

A second comparison isolates the changes to `30-prompt` and `40-vi-mode`.
Temporary loaders select the full repository configuration with either the
previous or current versions of those two modules; both use the same current
Starship theme. Loaded function source paths were checked. The normal home,
installed plugins and warm caches are used, without changing installed files.

| Measurement (10 alternating samples after 2 warmups) | Before median | After median |
| ---------------------------------------------------- | ------------- | ------------ |
| Interactive startup, exiting before prompt drawing   | 192.38 ms     | 195.09 ms    |
| First input ready, `zsh_profile trace` in a PTY      | 289.45 ms     | 243.91 ms    |

The startup ranges overlap (128.59–266.61 vs 131.70–263.32 ms), so these samples
do not establish a startup regression. Input-ready ranges are 232.61–348.86
and 188.19–308.01 ms: the local median improves by about 46 ms. The paired
`zsh_profile both` run reports 0.13 s startup for each; zprof attributes 1.47 ms
before and 1.69 ms after to `_init_starship_prompt`. Hook setup thus adds a
small initialization cost, while eliminating the extra prompt draw saves work
when entering the editor. These are warm local samples, not performance guarantees.

The context suite exercises Git counts/stash/conflicts, divergence and detached
worktrees, pipeline statuses, Python environments, C/C++ detection without
compiler execution, Bun detection, missing runtimes and conditional job/duration
indicators. The tmux test also sends a real pipeline through the Zsh hooks.

The lifecycle suite uses real ZLE in a private tmux server to check existing
hooks, repeated initialization, vi transitions, Ctrl+C and clipboard failure.
The initialization regression also checks trap preservation, pending descriptor
cleanup and widget restoration after a failed engine load.

The full Zsh suite passes all 8 verification groups, including 9 context and
3 lifecycle cases; Ruff checks all three Python test files successfully, and
every Python function has a docstring. Nix evaluation of the Darwin Home Manager
Starship settings also succeeds. No full Nix build or switch was performed.

The TOML is deployed by Home Manager at both Starship configuration paths.
To preview the repository version in an existing interactive shell:

```sh
export STARSHIP_CONFIG="$HOME/Dotfiles/home/starship/starship.toml"
```

The next prompt uses it. This previews only the theme, not the lifecycle modules.
Use Ctrl+L once to clear existing display artifacts.
The normal Nix build/switch deploys all changes permanently; a fresh shell then
uses the managed path. The shared Starship layout also changes for other
shells using this TOML; the integration test here covers Zsh only.

## Performance check: one line and the Python probe (2026-09-25)

Warm medians of 15 alternating samples after 3 warmups, at 120 columns,
counting what Zsh starts per prompt: the deployed layout ran `starship prompt`
and `starship prompt --right`, the new one runs `starship prompt` only, with
the generated configuration (Python probe included). The machine was under
load (load average about 11), so compare the columns rather than the
absolute values.

| Working directory                    | Deployed (two processes) | One line, probe |
| ------------------------------------ | ------------------------ | --------------- |
| `/Volumes/LCS.Data/Atrium` (uv, Git) | 307.1 ms                 | 30.7 ms         |
| Dotfiles working tree                | 43.9 ms                  | 34.9 ms         |
| `/tmp`                               | 22.6 ms                  | 12.1 ms         |

In Atrium, `starship timings` attributed about 230 ms to `python` alone: the
pyenv shim runs `pyenv exec` with the pyenv-virtualenv hooks before Python
starts. The probe answers there in about 5 ms, and reports the project's
Python 3.11 `.venv` rather than the global 3.14 the shim resolved to.

