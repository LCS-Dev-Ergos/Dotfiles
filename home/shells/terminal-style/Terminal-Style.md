# Terminal Style

Every command-line tool in this repository shares one look, defined once in
this directory: [`terminal-style.zsh`](terminal-style.zsh) for Zsh, and
[`terminal_style.py`](terminal_style.py), which mirrors its tokens, for
Python. Tools bundle a copy at build time: the Zsh configuration carries it as
`scripts/_terminal-style.zsh`, which `_shared-helpers.zsh` loads; cpp-tools as
`lib/terminal-style.zsh`; Python tools such as the development bootstrap next
to their package. A repository checkout reads the files here.

The [tests](tests) cover both implementations and fail when their tokens,
margins or Gum themes differ; `nix build .#terminal-style` runs them.

```text
╭──────────────────────────────────────────────────────────────────────╮
│  DEVDOCTOR   Development Environment                   macOS · arm64 │
│              4 runtimes in 1 group                  2026-10-11 10:14 │
╰──────────────────────────────────────────────────────────────────────╯

  Scripting ──────────────────────────────────────────────────────── 4
    ● Bun    bun    1.4.2   nix
    ◐ Conda  conda  26.3.2  —     dormant
      not activated here; runtime probe skipped
    ● Lua    lua    5.5.1   brew
    ● Perl   perl   5.44.0  brew

  PATH conflicts ─────────────────────────────────────────────────── 1
    ▲ shim priority  ~/.rbenv/shims  resolved after /opt/homebrew/bin

  ────────────────────────────────────────────────────────────────────
  ● 3 ok   ◐ 1 dormant    dev-doctor --updates checks for new releases
```

## Principles

- **One frame, for the header.** The masthead or title sits in a rounded
  frame; nothing else is boxed. Tables are borderless, and a section is a
  title followed by a rule.
- **One content column.** The frame is drawn in a two-column margin, so its
  inside starts and ends where the content below does: section titles, the
  badge and the summary share the left edge; counts, context and the next
  step share the right one. What a section holds sits one indent further in.
- **Color carries meaning.** Blue draws structure (the frame, section titles
  and their dimmed rules), cyan identifies the tool and anything typed,
  green, yellow and red belong to states, and two greys hold secondary text.
  Nothing is colored for decoration.
- **Every state is a shape, a color and a word.** A reader without color,
  or who cannot tell red from green, loses nothing.
- **Quiet when healthy, specific when not.** Healthy rows stay muted and may
  shorten their detail. A row that needs attention says why, where and how to
  fix it, and its reason continues under the row rather than lose its end.
- **Counts where they orient.** A section's rule ends in what it holds when
  the report has several sections to scan; a count the masthead already
  states is not repeated.
- **Plain output is complete.** With `NO_COLOR`, a pipe or a dumb terminal,
  output is never colored, framed or truncated, so a captured report can be
  read and copied in full.

## Tokens

| Role | SGR | Use |
| --- | --- | --- |
| `strong` | `1` | Titles, callout headings. |
| `accent` | `36` | Commands to type, definition terms, info signs. |
| `badge` | `1;7;36` | The tool name or page title, as a reverse-video badge. |
| `heading` | `1;34` | Section and card titles. |
| `frame` | `34` | The header's rounded frame. |
| `rule` | `2;34` | Section rules and the summary's rule: the frame's blue, dimmed. |
| `muted` | `38;5;245` | Secondary text: paths, column labels, counts, hints, keys. |
| `faint` | `38;5;240` | Empty cells (`—`), locations not created yet. |
| `ok`, `warn`, `error` | `32`, `33`, `31` | State words; markers use the bold variant. |

The colors are the terminal's own ANSI slots, so output follows its theme.
The two greys are fixed, because many themes make "bright black" unreadable.
A terminal that cannot dim draws the rules in plain blue.

| Tone | Marker | Meaning |
| --- | --- | --- |
| `ok` | `●` | Healthy, present, done. |
| `pending` | `▲` | Work is due, and the tool's next step does it. |
| `warn` | `◆` | Worth a look; nothing failed. |
| `error` | `✖` | Failed, or needs a person. |
| `muted` | `○` | Information outside the tool's ownership. |

Event lines use their own signs: `›` information, `✓` done, `▲` warning and
`✖` error. `_zsh_ui_status_glyph` maps common status words to tones and keeps
a few sharper markers (`?` unknown, `◐` dormant); Python's
`Style.marker(tone, word)` draws the same ones. The frame uses `╭╮╰╯`,
`│` and `─`.

## Layout

- Width follows the terminal between 40 and 120 columns; a tool that fits
  its own layout passes `--width`. The margin is `_ZSH_UI_GUTTER` (2) on
  both sides and the step in is `_ZSH_UI_INDENT` (2): frame at column 0,
  titles at 2, rows at 4, a row's text at 6.
- Table columns are separated by two spaces. Column labels are capitals in
  every mode, muted when styled; numbers align right. Rows with a state lead
  with its marker.
- A row's continuation (reasons, locations, `fix`, `steps`) starts under its
  text and wraps to the right margin. Paths are shortened instead: they drop
  whole middle components (`~/.local/…/bin/node`), and `$HOME` becomes `~`.
- As the width shrinks, long cells shorten first, then the least important
  columns go. A dropped state word or failing location moves under its row
  instead of vanishing; a section's note gives way before its rule does.

## Components

| Zsh | Python (`terminal_style.py`) | Use |
| --- | --- | --- |
| `_zsh_ui_app_header` | `header` | Framed masthead: badge, title, context; subtitle and note beneath. |
| `_zsh_ui_heading` | — | Framed title of a simple command: the title as the badge, the subtitle beside or under it. |
| `_zsh_ui_section` | `section` | Section title and rule, ending in an optional note such as a count. `Title · note` also works; `--tone` colors the title of a section that reports an outcome. |
| `_zsh_ui_subsection` | — | Help-menu and catalog titles: a section title when styled, the zfuncs layout when plain. |
| `_zsh_ui_table` | `table` | Borderless table. Zsh takes `--marker`, `--status` and `--align` columns, or `--tones` when the caller knows each row's outcome; Python adds priorities and folding. |
| `_zsh_ui_card` | — | A section title and `key<TAB>value` fields one indent in. |
| `_zsh_ui_definition_list` | — | Help menus: accent terms, muted descriptions. |
| `_zsh_ui_callout` | `callout` | A notice set off by a bar in its tone. |
| `_zsh_ui_summary` | `summary` | Rule across the content, per-state counts, and the next step on the right. Plain, one leveled line of two sentences: `[INFO]  2 changes. Apply installs them.` The hint is a sentence of its own, capitalized unless it starts with a command. |
| `_zsh_ui_log` | — | One event line; warnings and errors go to stderr. |
| `_zsh_ui_rule` | — | A rule across the content. |
| `_zsh_ui_marker`, `_zsh_ui_status_glyph` | `Style.marker` | A tone's or a status word's marker. |
| — | `ArgumentParser` | A command's `--help` and usage errors in capitalized sentences: `Usage:`, `Options:`, `Show this help and exit`. Prose in the description and epilog is refilled; a paragraph with an indented line or a line ending in a colon (`Examples:`) keeps its layout. Subcommands inherit it. |

Untrusted text is escaped centrally: logs, headings, sections, cells and
notes pass through `_zsh_ui_sanitize_text` or `sanitize`.

## Interactions

Gum draws only what a printed line cannot: `_zsh_ui_confirm`,
`_zsh_ui_choose`, `_zsh_ui_spinner` and `_zsh_ui_spinner_fn`. They run through
`_zsh_ui_gum`, which applies the shared theme: cyan prompts, cursors and
spinners, blue selections, never Gum's default pink. Static output never
starts a Gum process.

Without a terminal on stdin, a confirmation or a choice fails: only the
caller's explicit flag, such as `--yes`, accepts unattended. A spinner keeps
the work's output and replays it when the work ends. Diagnostics hidden
behind the spinner are replayed only when the work fails.

## Modes

`ZSH_UI_STYLE=auto|plain|ansi|gum` selects the mode; `auto` styles a color
terminal and stays plain elsewhere, and `NO_COLOR` always wins. Python tools
decide the same way from their own stdout.

Full-screen interfaces (Bubble Tea) are outside this model: reserve them for
a future dedicated tool, which should still take its palette from these
tokens.
