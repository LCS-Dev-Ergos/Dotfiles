# Starship Context and Prompt Resizing

The Starship prompt keeps two lines: every piece of information on the first,
the input on the second. The first line starts with identity, containers,
directory and Git state; after a thin `│`, shown only when there is anything
behind it, come jobs, elapsed command time, environments, Docker/Kubernetes
and toolchains. The second line holds command failures and the input
character. There is no clock, no battery (the kitty tab bar shows it) and no
right prompt (`right_format` is empty and Zsh's RPROMPT stays unset, which
also saves a Starship process per prompt). The layout is the same in every
terminal and multiplexer.

## Reading The Prompt

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
- The context shows the number even for one background job and elapsed time
  after two seconds. Nix and Conda retain their environment names. Docker
  shows its context only in a project with a Dockerfile or Compose file:
  OrbStack makes its own context the current one, which would otherwise
  appear on every prompt. It reads the context locally without contacting
  the daemon.

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
metrics, hides `main`/`master` and right-aligns with `$fill`; those choices
are not used here. Keep the existing chevron/vi-mode semantics and palette.
Geometry's asynchronous renderer and extra information on empty Enter would
require new shell behavior and are not part of this refinement.

## Prompt and Vi Lifecycle

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

What keeps a single information line workable is that nothing is padded to
the terminal width. `$fill` turns the first line into width-long text that
re-wraps on every shrink. Without it the line is as long as its content,
typically 40 to 90 cells, so resizes that stay at least that wide leave no
trace. Narrower than the line itself, the old duplicates remain possible.

kitty's shell integration can erase the prompt on resize and let ZLE redraw
it, which made a right-aligned `$fill` variant safe directly in kitty. It was
dropped: the right-aligned context added nothing, and one layout behaves the
same in kitty, tmux, herdr and VS Code.

With Zsh 5.9.2, Starship 1.26.0, tmux 3.7c and kitty 0.49.1:

| Layout and terminal | Result |
| --- | --- |
| `$fill` layout, tmux | duplicates at almost every shrink |
| `$fill` layout, kitty without prompt marking | 11 of 12 resize steps fail |
| `$fill` layout, kitty with shell integration | 12 of 12 pass, down to 33 columns |
| One-line layout, tmux | passes down to its line width (46 + 2) |
| One-line layout, kitty without prompt marking | passes down to its line width (51) |

The kitty runs resized a real window through `kitten @ set-font-size`
(173 → 101 → 196 → 81 → 173 → 62 → 41 → 33 → 226 → 41 → 122 → 173 columns),
counting headers in the screen and scrollback with `kitten @ get-text`.

Run the integration test explicitly, or through the full Zsh suite:

```sh
python3 home/shells/zsh/config/tests/integration/core/test-prompt-resize.py
PYTHONDONTWRITEBYTECODE=1 python3 home/shells/zsh/config/tests/integration/core/test-prompt-context.py
PYTHONDONTWRITEBYTECODE=1 python3 home/shells/zsh/config/tests/integration/core/test-zle-lifecycle.py
zsh home/shells/zsh/config/tests/run-all.zsh --full
```

It uses a private tmux socket, temporary HOME/config/cache and an empty working
directory. It skips if tmux, Starship or Zsh is unavailable. This is a tmux/ZLE
regression test, not visual acceptance for every terminal. The default run
resizes 100 → 60 → 110 → the information line's width plus two → 100 columns,
24 → 12 → 24 rows, then splits and removes a pane; it passes. The opt-in
stress run adds a shrink to 35 columns, narrower than the fixture's line, and
is expected to fail at exactly that step (everything after it still passes):

```sh
ZSH_PROMPT_RESIZE_STRESS=1 python3 home/shells/zsh/config/tests/integration/core/test-prompt-resize.py
```

## Performance

Each prompt starts one `starship prompt` process: the right prompt is empty
and Zsh's RPROMPT stays unset. Git no longer invokes a custom shell and diff
pair, and C/C++ markers require no compiler subprocess. Bun queries its
version only in a matching project, like the other runtime modules. Python is
used only by the tests.

In a project with a pyenv-managed interpreter, the pyenv shim runs
`pyenv exec` with the pyenv-virtualenv hooks before Python starts, which
dominates the Python module's cost. The generated configuration's probe avoids
the shim and reports the project's `.venv` rather than the global Python the
shim resolves to.

Hook setup adds a small initialization cost to `_init_starship_prompt`, while
removing the extra prompt draw saves work when entering the editor.
`zsh_profile both` reports startup and zprof attribution, `zsh_profile trace`
in a PTY measures the time until input is ready, and `starship timings`
attributes cost to individual modules. Compare warm, alternating samples taken
on the same machine; single runs and cold starts are not comparable.

## Tests and Preview

The context suite exercises Git counts/stash/conflicts, divergence and detached
worktrees, pipeline statuses, Python environments, C/C++ detection without
compiler execution, Bun detection, missing runtimes and conditional job/duration
indicators. The tmux test also sends a real pipeline through the Zsh hooks.

The lifecycle suite uses real ZLE in a private tmux server to check existing
hooks, repeated initialization, vi transitions, Ctrl+C and clipboard failure.
The initialization regression also checks trap preservation, pending descriptor
cleanup and widget restoration after a failed engine load.

The TOML is deployed by Home Manager at both Starship configuration paths.
To preview the repository version in an existing interactive shell:

```sh
export STARSHIP_CONFIG="$HOME/Dotfiles/home/shells/starship/starship.toml"
```

The next prompt uses it. This previews only the theme, not the lifecycle modules.
Use Ctrl+L once to clear existing display artifacts.
The normal Nix build/switch deploys all changes permanently; a fresh shell then
uses the managed path. The shared Starship layout also changes for other
shells using this TOML; the integration test here covers Zsh only.
