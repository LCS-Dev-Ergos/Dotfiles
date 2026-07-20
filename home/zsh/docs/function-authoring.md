# ZSH Function Authoring Policy

Custom functions should be small shell interfaces with explicit output and
state contracts. Their adjacent Shdoc metadata remains the source of truth for
`zfuncs`, completions, and validation.

## Naming and visibility

- Use `snake_case` for function names and `kebab-case` for shell filenames.
- Prefix implementation helpers with `_` and document them with `@internal`.
- Register only commands that are meaningful and available to users. Startup
  helpers and conditionally defined implementations are never public commands.

## Function structure

Public functions should normally begin with `emulate -L zsh` and enable only
the local options they require. Validate arguments before changing state, quote
paths, use `command` for external binaries where aliases could interfere, and
return documented status codes.

```zsh
# -----------------------------------------------------------------------------
# example_command
# @description Performs one clearly defined operation.
# @arg $1 path Input path.
# @option -q | --quiet Suppress informational output.
# @exitcode 1 If validation or processing fails.
# -----------------------------------------------------------------------------
example_command() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail
  _zsh_ui_load || return 1

  # Validate, execute, then render a concise result.
}
```

## Output contract

Choose the output class before choosing its presentation:

1. Data output is intended for pipes or command substitution. Keep stdout
   undecorated and stable; send diagnostics to stderr. Do not invoke Gum.
2. Informational UI is intended for a person at a terminal. Load the shared UI
   layer with `_zsh_ui_load` and use its primitives instead of calling Gum or
   embedding ANSI sequences directly.
3. Delegated output belongs to the backend command. A wrapper may add one
   heading or concise preflight diagnostics, but should not restyle a stream it
   does not own.

The shared layer honors `ZSH_UI_STYLE=auto|plain|ansi|gum` and `NO_COLOR`.
Every Gum presentation must have a native plain/ANSI fallback. Use
`_zsh_ui_log` for individual status lines, `_zsh_ui_section` for lightweight
labels, `_zsh_ui_card` for compact summaries, `_zsh_ui_table` for structured
rows, `_zsh_ui_confirm` for destructive choices, and `_zsh_ui_spinner` only
when hiding command output is acceptable.

Logs and table fields escape terminal control characters centrally. Sanitize
untrusted filesystem or network text with `_zsh_ui_sanitize_text` before using
it in cards or headings, which may intentionally contain presentation codes.

Gum is a coarse-grained renderer, not a logging framework. Spawn it at most
once per cohesive heading, card, table, confirmation, or spinner; never once
per row, file, or log line. Nushell is not a presentation dependency.

Help output and data output must remain useful when redirected. Commands with
informational chatter should provide `--quiet`; quiet mode must suppress
wrapper headings and preflight notices as well as backend progress.

## Validation

Add focused regression coverage for argument validation, exit status, state
changes, plain fallback output, and the Gum process budget where relevant.
Create fixtures with `mktemp`, a private `umask`, checked allocation, and exact
cleanup targets. State-changing functions should reject symlink destinations
when appropriate and publish files through secure sibling temporaries.
Run `tests/run-all.zsh --full` before merging a new public function.
