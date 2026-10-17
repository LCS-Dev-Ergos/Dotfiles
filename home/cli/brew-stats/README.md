# Brew Stats

`brew-stats` reports how many Homebrew packages are installed and how much
disk each takes, largest first, then the totals and the download cache. Home
Manager installs it on macOS; the Zsh function `brew_stats` calls it.

```sh
brew-stats                 # every package, largest first, and the summary
brew-stats --cask --top 5  # the five largest casks
brew-stats -f --sort name  # formulae by name
brew-stats -q              # the table alone, uncolored, for scripts
```

`-f`/`--formula` and `-c`/`--cask` select one kind, `--top N` keeps the first
N rows, `--sort size|name` orders them and `-q`/`--quiet` drops the summary.
Exit status: 0 for a complete report; 1 when Homebrew, the inventory or a
measurement fails, or when some linked artifacts were left out (the report
is still printed and names them on standard error); 2 for a usage error.

## What Is Measured

- A formula is its Cellar directory, every installed version included. All
  formulae are measured in one `du -sk`, so a file several share through
  hard links counts once.
- A cask is its Caskroom entry plus the outermost targets of the links in it,
  such as an app in /Applications. A target counts only inside the install
  roots the cask recorded in `.metadata/config.json`, and only if that file
  is a regular file owned by the user and writable by nobody else; an app
  bundle's own links, which can cycle, are never followed. A broken link, or
  one pointing elsewhere, is left out and named.
- Files a `.pkg` installer placed cannot be attributed and are not included.

## Guarantees

- The report never mixes two moments: the inventory is read before measuring
  and again after, and a change in between fails the run.
- Every entry resolves to a directory inside the Cellar or Caskroom; one that
  escapes it, a missing directory or an unusable cache path fails the run.
- `brew` and `du` run with literal arguments and no input; nothing is
  written. Text from Homebrew never reaches the terminal unfiltered.

## Tests

`nix build .#brew-stats -L` runs the tests in `tests/`, which use a fake
`brew` over a temporary Cellar and Caskroom and the real `du`. Without Nix,
from this directory: `python3 -m unittest discover -s tests -t .`.
