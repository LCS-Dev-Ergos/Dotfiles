#!/usr/bin/env zsh
# ============================================================================ #
# Git status formatter for Starship [custom.git_status]
# Single-shot git report:
#   - file status counters (conflicted/untracked/modified/staged/renamed/deleted/typechanged)
#   - stash count
#   - ahead/behind
#   - line metrics (+added/-deleted, equivalent to git_metrics)
# ============================================================================ #

emulate -L zsh
setopt local_options no_aliases no_sh_word_split typeset_silent

_return_ok() {
  return 0 2>/dev/null || exit 0
}

_resolve_git_dir() {
  typeset probe line candidate

  if [[ -n ${GIT_DIR-} ]]; then
    [[ -d $GIT_DIR ]] || return 1
    REPLY=$GIT_DIR
    return 0
  fi

  probe=$PWD
  while true; do
    if [[ -d $probe/.git ]]; then
      REPLY=$probe/.git
      return 0
    fi

    if [[ -f $probe/.git ]]; then
      IFS= read -r line < "$probe/.git" || return 1
      candidate=${line#gitdir: }
      [[ -n $candidate ]] || return 1
      [[ $candidate == /* ]] || candidate=$probe/$candidate
      [[ -d $candidate ]] || return 1
      REPLY=$candidate
      return 0
    fi

    [[ $probe == / ]] && return 1
    probe=${probe:h}
  done
}

integer conflicted=0 untracked=0 modified=0 staged=0
integer renamed=0 deleted=0 typechanged=0 stashed=0 ahead=0 behind=0
integer added_lines=0 deleted_lines=0
typeset -a core_statuses output_parts
typeset status_out diff_out line ab x y a d rest
typeset gd
typeset ansi_reset ansi_red ansi_green

_resolve_git_dir || _return_ok
gd=$REPLY

status_out=$(git --no-optional-locks status \
  --porcelain=v2 --branch --ignore-submodules=all 2>/dev/null) || _return_ok

for line in ${(f)status_out}; do
  case ${line[1]} in
    '#')
      [[ ${line[3,12]} == 'branch.ab ' ]] || continue
      ab=${line#\# branch.ab }
      ahead=${ab%% *}
      ahead=${ahead#+}
      behind=${ab##* }
      behind=${behind#-}
      ;;
    '1')
      x=${line[3]}
      y=${line[4]}
      [[ $x != '.' ]] && (( staged++ ))
      [[ $y == 'M' ]] && (( modified++ ))
      [[ $y == 'D' ]] && (( deleted++ ))
      [[ $x == 'T' || $y == 'T' ]] && (( typechanged++ ))
      ;;
    '2')
      (( staged++ ))
      [[ ${line[3]} == 'R' ]] && (( renamed++ ))
      y=${line[4]}
      [[ $y == 'M' ]] && (( modified++ ))
      [[ $y == 'D' ]] && (( deleted++ ))
      ;;
    'u') (( conflicted++ )) ;;
    '?') (( untracked++ )) ;;
  esac
done

if [[ -r $gd/logs/refs/stash ]]; then
  while IFS= read -r line; do
    (( stashed++ ))
  done < "$gd/logs/refs/stash"
fi

# Same semantic as starship git_metrics: aggregate changed lines vs HEAD.
# Fast-path: skip the extra git call if there are no tracked changes at all.
if (( staged || modified || deleted || renamed || typechanged || conflicted )); then
  diff_out=$(git --no-optional-locks diff \
    --numstat --ignore-submodules=all HEAD 2>/dev/null)
  for line in ${(f)diff_out}; do
    a=${line%%$'\t'*}
    rest=${line#*$'\t'}
    d=${rest%%$'\t'*}
    [[ $a == <-> && $d == <-> ]] || continue
    (( added_lines += a, deleted_lines += d ))
  done
fi

(( conflicted  )) && core_statuses+=("󰩬 $conflicted")
(( stashed     )) && core_statuses+=("󰏗 $stashed")
(( untracked   )) && core_statuses+=("󰟢 $untracked")
(( modified    )) && core_statuses+=("󰏫 $modified")
(( staged      )) && core_statuses+=("󰐙 $staged")
(( renamed     )) && core_statuses+=("󰑕 $renamed")
(( deleted     )) && core_statuses+=("󰆴 $deleted")
(( typechanged )) && core_statuses+=("󰦒 $typechanged")

if (( ahead > 0 && behind > 0 )); then
  core_statuses+=("󰘻 󰜷$ahead 󰜮$behind")
elif (( ahead > 0 )); then
  core_statuses+=("󰜷 $ahead")
elif (( behind > 0 )); then
  core_statuses+=("󰜮 $behind")
fi

ansi_reset=$'\e[0m'
ansi_red=$'\e[31m'
ansi_green=$'\e[32m'

(( $#core_statuses )) && output_parts+=("${ansi_red}[${(j: :)core_statuses}]${ansi_reset}")
(( added_lines   )) && output_parts+=("${ansi_green}+${added_lines}${ansi_reset}")
(( deleted_lines )) && output_parts+=("${ansi_red}-${deleted_lines}${ansi_reset}")

(( $#output_parts )) && print -r -- "${(j: :)output_parts}"
_return_ok

# ============================================================================ #
# End of script.
