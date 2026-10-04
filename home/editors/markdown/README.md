# Markdown Tooling

markdownlint rule sets for the VS Code extension, plus the `mdlint` command that
applies them from a terminal. Home Manager deploys the rules to
`~/.config/markdownlint` and installs `mdlint`.

## Rule Sets

| File | Purpose |
| --- | --- |
| `config/safe.jsonc` | Reduced set, the editor default. Allow-list of whitespace-only fixers, the table rules and a few diagnostics. Safe to auto-fix. |
| `config/extended.jsonc` | The reduced set plus every other markdownlint rule with the house style. Reports only. |
| `config/config.jsonc` | Options file the extension loads: custom rule plus `safe.jsonc`. |
| `config/rules/table-delimiter-dashes.cjs` | Custom rule LCS001: delimiter cells use exactly three dashes. |

MD060 `compact` normalizes the padding around cell contents but leaves dash
counts alone, which is why LCS001 exists. Together they turn a padded table into
the canonical `| --- |` form.

The reduced set is an allow-list on purpose. Rendering 1107 real documents
before and after a fix showed that the table rules and the whitespace fixers
(MD012, MD027, MD030, MD047, MD058) never change the output, while others do:
MD009 drops hard breaks, MD029 renumbers continued lists, MD037 turns `* N *`
into emphasis, MD026 and MD034 rewrite headings and URLs. Those live in the
extended set.

## Commands

`mdlint [--extended] PATH...` lints with the reduced set, or with the extended set
for a report. It refuses `--fix` together with `--extended`.

Bulk normalization is not part of the environment. The `mdfix` script lives on the
data volume, in `/Volumes/LCS.Data/Scripts/Markdown-Tools`, and is run on demand
with `uv` and a throwaway Nix shell for `markdownlint-cli2`. It reads the same rule
files from `~/.config/markdownlint`; its README has the command line, the safety
checks and its own tests.

## Tests

`nix build .#markdownlint-config -L` runs `tests/run.sh`: the table fixtures, a
hazard fixture that the reduced set must leave byte for byte, the extended
report and the `mdlint` wrapper.
