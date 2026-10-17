# Zsh Function Authoring Policy

Custom functions should be small shell interfaces with explicit output and
state contracts. Their adjacent Shdoc metadata remains the source of truth for
`zfuncs`, completions, and validation.

## Naming and Visibility

- Use `snake_case` for function names and `kebab-case` for shell filenames.
- Prefix implementation helpers with `_` and document them with `@internal`.
- Register only commands that are meaningful and available to users. Startup
  helpers and conditionally defined implementations are never public commands.

## Function Structure

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

## Output Contract

Choose the output class before choosing its presentation:

1. Data output is intended for pipes or command substitution. Keep stdout
   undecorated and stable; send diagnostics to stderr. Do not invoke Gum.
2. Informational UI is intended for a person at a terminal. Load the shared UI
   layer with `_zsh_ui_load` and use its primitives instead of calling Gum or
   embedding ANSI sequences directly.
3. Delegated output belongs to the backend command. A wrapper may add one
   heading or concise preflight diagnostics, but should not restyle a stream it
   does not own.

The shared layer honors `ZSH_UI_STYLE=auto|plain|ansi|gum` and `NO_COLOR`;
[Terminal Style](../../terminal-style/Terminal-Style.md) describes the look
and every component.
Use `_zsh_ui_log` for individual event lines, `_zsh_ui_heading` for a
command's title, `_zsh_ui_app_header` for the masthead of a report such as
dev-doctor (the tool name as a badge, context on the right),
`_zsh_ui_section` for section titles (a note, such as a count, ends the
rule), `_zsh_ui_card` for compact summaries (`key<TAB>value` lines become an
aligned list), `_zsh_ui_table` for structured rows (`--align` for numeric
columns, `--status` for state columns, `--marker` to lead rows with a state
marker), `_zsh_ui_summary` to close a report
with its counts and next step, `_zsh_ui_callout` for a notice that must not be
missed, `_zsh_ui_marker` and `_zsh_ui_status_glyph` for one-cell state
markers, `_zsh_ui_confirm` and `_zsh_ui_choose` for decisions, and
`_zsh_ui_spinner` only when hiding command output is acceptable.
`_zsh_ui_short_path` gives the display form of a path: `~` for the home
directory and short Nix store hashes in styled output, the full path in plain
output.

Static output is drawn by the shell in every mode, with the terminal's ANSI
colors: the header in a rounded frame with a badge, section titles followed
by a dimmed rule, borderless tables one indent in with muted column labels,
and a rule above a summary, inside a two-column margin. Styled tables fit the
terminal width by shortening their widest cells; plain output is never
truncated, so captured reports stay complete. Gum is reserved for confirmations, choices and spinners, the places
where it does something a printed line cannot; never spawn it for static
output, per row, per file, or per log line.

Logs, headings, sections, table fields, and card titles escape terminal
control characters centrally. Sanitize untrusted filesystem or network text
with `_zsh_ui_sanitize_text` before placing it in card body lines, which may
intentionally contain presentation codes. Nushell is not a presentation
dependency.

Help output and data output must remain useful when redirected. Commands with
informational chatter should provide `--quiet`; quiet mode must suppress
wrapper headings and preflight notices as well as backend progress.

## Validation

Add focused regression coverage for argument validation, exit status, state
changes, plain fallback output, and the absence of Gum processes for static
output where relevant.
Create fixtures with `mktemp`, a private `umask`, checked allocation, and exact
cleanup targets. State-changing functions should reject symlink destinations
when appropriate and publish files through secure sibling temporaries.
Run `tests/run-all.zsh --full` before merging a new public function.
