#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++++ MODERN CLI TOOL ALIASES ++++++++++++++++++++++++++ #
# ============================================================================ #
#
# Aliases for modern CLI tools that replace traditional Unix commands.
# Each section checks if the tool is installed before defining aliases.
#
# Tools:
#   - eza  Modern replacement for ls (with git integration).
#   - bat  Modern replacement for cat (with syntax highlighting).
#   - duf  Modern replacement for df (with better output).
#
# ============================================================================ #

# ================================== EZA ===================================== #
# Modern replacement for ls with git integration and icons.
# https://github.com/eza-community/eza

if command -v eza &>/dev/null; then
  # Basic listing.
  alias ls='eza --color=auto --icons=auto'

  # Long format with git status.
  alias l='eza -lh --icons=auto'

  # Long format with hidden files, sorted by name, directories first.
  alias ll='eza -lha --icons=auto --sort=name --group-directories-first'

  # Long format, directories only.
  alias ld='eza -lhD --icons=auto'

  # Tree view.
  alias lt='eza --icons=auto --tree'

  # Tree view with git ignore.
  alias lti='eza --icons=auto --tree --git-ignore'
fi

# ================================== BAT ===================================== #
# Modern replacement for cat with syntax highlighting.
# https://github.com/sharkdp/bat

if command -v bat &>/dev/null; then
  # Replace cat with bat (plain style, no paging).
  alias cat='bat --style=plain --paging=never --color=auto'

  # Global alias to pipe --help through bat for colorized help output.
  # Usage: command --help (automatically colorized).
  alias -g -- --help='--help 2>&1 | bat --language=help --style=plain --paging=never --color=always'

  # Bat with line numbers.
  alias batn='bat --style=numbers'

  # Bat with full decorations.
  alias batf='bat --style=full'
fi

# ================================== DUF ===================================== #
# Modern replacement for df with better visualization.
# https://github.com/muesli/duf

if command -v duf &>/dev/null; then
  # Wrapper function to handle paths correctly.
  _df() {
    if [[ $# -ge 1 && -e "${@: -1}" ]]; then
      duf "${@: -1}"
    else
      duf
    fi
  }

  alias df='_df'
fi

# ============================================================================ #
