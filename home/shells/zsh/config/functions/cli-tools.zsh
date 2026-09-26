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

  # Long format, directories only. Keep `ld` free for the system linker.
  alias ldirs='eza -lhD --icons=auto'

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

  # ---------------------------------------------------------------------------
  # h
  # @description Displays a command's --help output with bat highlighting.
  # @arg $1 string Command whose help output to display.
  # @arg $@ string Optional arguments forwarded to the command.
  # @exitcode 1 If no command is supplied.
  # ---------------------------------------------------------------------------
  h() {
    if [[ $# -eq 0 ]]; then
      echo "Usage: h <command>"
      echo "Shows help for a command with syntax highlighting."
      return 1
    fi

    local cmd="$1"
    shift

    "$cmd" --help "${@}" 2>&1 | bat --language=help --style=plain --paging=never --color=always
  }

  # Bat with line numbers.
  alias batn='bat --style=numbers'

  # Bat with full decorations.
  alias batf='bat --style=full'
fi

# ================================== DUF ===================================== #
# Modern replacement for df with better visualization.
# https://github.com/muesli/duf

if command -v duf &>/dev/null; then
  # ---------------------------------------------------------------------------
  # _cli_duf_df
  # @internal
  # @description Backs the df alias: shows duf for the last argument when it
  # names an existing path, otherwise for every mount. df-style flags are
  # dropped. The name must not be `_df`: that is the completion function
  # compinit binds to df, and redefining it would make `\df <Tab>` or
  # `sudo df <Tab>` run duf in the middle of completion.
  # @arg $@ string df-style arguments; only a trailing path is used.
  # ---------------------------------------------------------------------------
  _cli_duf_df() {
    if (( $# )) && [[ -e "${@[-1]}" ]]; then
      command duf "${@[-1]}"
    else
      command duf
    fi
  }

  alias df='_cli_duf_df'
fi

# ============================================================================ #
# End of cli-tools.zsh
