#!/usr/bin/env bash
# Git status formatter for Starship [custom.git_status]
# Outputs icon+count pairs joined by spaces — no trailing space.
# Drop-in replacement for the built-in [git_status] module.

statuses=()
conflicted=0 untracked=0 modified=0 staged=0 renamed=0 deleted=0 typechanged=0
ahead=0 behind=0

# Single call: porcelain v2 gives status + branch info (ahead/behind).
git_out=$(git status --porcelain=v2 --branch --ignore-submodules=all 2>/dev/null) \
    || exit 0

while IFS= read -r line; do
    case "${line:0:1}" in
        '#')
            if [[ "$line" == '# branch.ab '* ]]; then
                ab="${line#'# branch.ab '}"
                ahead_s="${ab%% *}"; ahead="${ahead_s#+}"
                behind_s="${ab##* }"; behind="${behind_s#-}"
            fi
            ;;
        '1')
            x="${line:2:1}"; y="${line:3:1}"
            [[ $x != '.' ]]  && (( staged++ ))
            [[ $y == 'M' ]]  && (( modified++ ))
            [[ $y == 'D' ]]  && (( deleted++ ))
            [[ $x == 'T' || $y == 'T' ]] && (( typechanged++ ))
            ;;
        '2')
            # Renamed / copied entries are always staged.
            x="${line:2:1}"; y="${line:3:1}"
            (( staged++ ))
            [[ $x == 'R' ]] && (( renamed++ ))
            [[ $y == 'M' ]] && (( modified++ ))
            [[ $y == 'D' ]] && (( deleted++ ))
            ;;
        'u')
            (( conflicted++ ))
            ;;
        '?')
            (( untracked++ ))
            ;;
    esac
done <<< "$git_out"

# Stash count requires a separate call (not in porcelain v2 output).
stashed=$(git stash list 2>/dev/null | wc -l)
stashed="${stashed//[[:space:]]/}"

# Build the array in the same order Starship uses for $all_status.
(( conflicted  )) && statuses+=("󰩬 $conflicted")
(( stashed     )) && statuses+=("󰏗 $stashed")
(( untracked   )) && statuses+=("󰟢 $untracked")
(( modified    )) && statuses+=("󰏫 $modified")
(( staged      )) && statuses+=("󰐙 $staged")
(( renamed     )) && statuses+=("󰑕 $renamed")
(( deleted     )) && statuses+=("󰆴 $deleted")
(( typechanged )) && statuses+=("󰦒 $typechanged")

# Ahead / behind (mirrors diverged / ahead / behind from the original config).
if (( ahead > 0 && behind > 0 )); then
    statuses+=("󰘻 󰜷$ahead 󰜮$behind")
elif (( ahead > 0 )); then
    statuses+=("󰜷 $ahead")
elif (( behind > 0 )); then
    statuses+=("󰜮 $behind")
fi

# Print elements joined by a single space — no trailing space.
(( ${#statuses[@]} )) && printf '%s' "${statuses[*]}"
