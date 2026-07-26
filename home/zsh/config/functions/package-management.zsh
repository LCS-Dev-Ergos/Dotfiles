#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++++ PACKAGE MANAGEMENT HELPERS ++++++++++++++++++++++++ #
# ============================================================================ #
#
# Substantive package-manager behavior kept out of the aliases-only module
# (lib/60-aliases.zsh). Each function is scoped to the platform it applies to.
#
# Functions:
#   - brew                       (macOS) Homebrew wrapper, triggers sketchybar.
#   - brew_stats                 (macOS) Reports Homebrew package counts/sizes.
#   - command_not_found_handler  (Arch, opt-in) Suggests the owning package.
#   - in                         (Arch) Installs via pacman or an AUR helper.
#
# ============================================================================ #

if [[ "$PLATFORM" == macOS ]]; then
  # ---------------------------------------------------------------------------
  # brew
  # @description Forwards Homebrew commands; triggers sketchybar after updates.
  # @arg $@ string Optional Homebrew command and arguments.
  # @exitcode 1 If the Homebrew command fails.
  # ---------------------------------------------------------------------------
  brew() {
    command brew "$@"
    local rc=$?
    case "${1:-}" in
      upgrade|update|outdated)
        command -v sketchybar >/dev/null 2>&1 && sketchybar --trigger brew_update &!
        ;;
    esac
    return $rc
  }

  # The report implementation is a deep internal module; keep only its public
  # interface in the package-management catalog.
  if [[ -r \
    "${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts/brew-stats.zsh" ]]; then
    source \
      "${ZSH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh}/scripts/brew-stats.zsh"
  fi

  # ---------------------------------------------------------------------------
  # brew_stats
  # @description Reports the number and on-disk size of installed Homebrew
  # packages (formulae and canonical casks), sorted largest-first by default,
  # plus the download cache size. Files placed by .pkg installers cannot be
  # attributed reliably.
  # @arg $@ string Optional flags; see --help.
  # @option -f | --formula Show only formulae.
  # @option -c | --cask Show only casks.
  # @option --top <n> Limit the table to the n largest (or first) entries.
  # @option --sort size|name Sort order; defaults to size.
  # @option -q | --quiet Print only the table, no heading or summary card.
  # @option -h | --help Show usage information.
  # @exitcode 1 If inventory, metadata, cache, rendering, or size resolution
  # fails, or if the installed inventory changes while the report is built.
  # @exitcode 2 If command-line arguments are invalid.
  # ---------------------------------------------------------------------------
  brew_stats() {
    emulate -L zsh
    (( $+functions[_brew_stats_main] )) || {
      print -u2 "brew_stats: report implementation is unavailable."
      return 1
    }
    _brew_stats_main "$@"
  }
fi

if [[ "$PLATFORM" == Linux && "$ARCH_LINUX" == true ]]; then
  : "${ENABLE_CMD_NOT_FOUND:=false}"

  if [[ "$ENABLE_CMD_NOT_FOUND" == true ]]; then
    # -------------------------------------------------------------------------
    # command_not_found_handler
    # @internal
    # @description Reports Arch package candidates for a missing command.
    # @arg $1 string Missing command name.
    # @exitcode 127 When the command cannot be found.
    # -------------------------------------------------------------------------
    command_not_found_handler() {
      local purple=$'\e[1;35m' bright=$'\e[0;1m' green=$'\e[1;32m' reset=$'\e[0m'
      printf 'zsh: command not found: %s\n' "$1"
      local entries=( "${(f)"$(/usr/bin/pacman -F --machinereadable -- "/usr/bin/$1")"}" )
      local entry pkg
      for entry in "${entries[@]}"; do
        local fields=( "${(0)entry}" )
        if [[ "$pkg" != "${fields[2]}" ]]; then
          printf '%s%s/%s%s %s%s%s\n' "$purple" "${fields[1]}" "$bright" "${fields[2]}" "$green" "${fields[3]}" "$reset"
        fi
        printf '    /%s\n' "${fields[4]}"
        pkg="${fields[2]}"
      done
      return 127
    }
  fi

  _aur_helper() {
    pacman -Qi yay &>/dev/null && { print -r -- yay; return 0; }
    pacman -Qi paru &>/dev/null && { print -r -- paru; return 0; }
    return 1
  }

  () {
    local aur_helper="$(_aur_helper 2>/dev/null)"
    [[ -n "$aur_helper" ]] || return 0
    alias un="${aur_helper} -Rns"
    alias up="${aur_helper} -Syu"
    alias pl="${aur_helper} -Qs"
    alias pa="${aur_helper} -Ss"
    alias pc="${aur_helper} -Sc"
    alias po="pacman -Qtdq | ${aur_helper} -Rns -"
  }

  # ---------------------------------------------------------------------------
  # in
  # @description Installs packages from Arch repositories or an AUR helper.
  # @arg $1 string First package name; additional names may follow.
  # @option -h | --help Show usage information.
  # @exitcode 1 If installation fails or no AUR helper is available.
  # ---------------------------------------------------------------------------
  in() {
    if [[ "$1" == -h || "$1" == --help || $# -eq 0 ]]; then
      print -r -- "Usage: in <package1> [package2 ...]"
      (( $# > 0 ))
      return
    fi

    local -a official=() aur=()
    local aur_helper="$(_aur_helper 2>/dev/null)" pkg
    for pkg in "$@"; do
      if pacman -Si "$pkg" &>/dev/null; then
        official+=("$pkg")
      else
        aur+=("$pkg")
      fi
    done

    (( ${#official[@]} == 0 )) || sudo pacman -S --needed "${official[@]}" || return 1
    if (( ${#aur[@]} )); then
      [[ -n "$aur_helper" ]] || {
        print -u2 "in: no AUR helper (yay or paru) is installed."
        return 1
      }
      command "$aur_helper" -S --needed "${aur[@]}"
    fi
  }
fi

# ============================================================================ #
# End of package-management.zsh
