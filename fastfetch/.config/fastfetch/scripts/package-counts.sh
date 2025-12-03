#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Cross-platform package manager detector for Fastfetch.

set -euo pipefail

declare -A group_parts

# Paru / Pacman (Arch).
if command -v paru >/dev/null 2>&1; then
  count=$(paru -Qq 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && group_parts[arch]="${group_parts[arch]:+${group_parts[arch]},} ${count} (paru)"
elif command -v pacman >/dev/null 2>&1; then
  count=$(pacman -Qq 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && group_parts[arch]="${group_parts[arch]:+${group_parts[arch]},} ${count} (pacman)"
fi

# Debian / Ubuntu (dpkg).
if command -v dpkg >/dev/null 2>&1; then
  count=$(dpkg -l 2>/dev/null | awk '/^ii/{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[dpkg]=" ${count} (dpkg)"
fi

# Fedora / RHEL (dnf / yum).
if command -v dnf >/dev/null 2>&1; then
  count=$(dnf list installed 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[dnf]=" ${count} (dnf)"
elif command -v yum >/dev/null 2>&1; then
  count=$(yum list installed 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[dnf]=" ${count} (yum)"
fi

# openSUSE (zypper).
if command -v zypper >/dev/null 2>&1; then
  count=$(zypper se -i 2>/dev/null | awk '/^i/{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[zypper]=" ${count} (zypper)"
fi

# Homebrew (macOS/Linux).
if command -v brew >/dev/null 2>&1; then
  brew_count=$(brew list --formula 2>/dev/null | wc -l | awk '{print $1}')
  cask_count=$(brew list --cask 2>/dev/null | wc -l | awk '{print $1}')
  line=""
  [[ ${brew_count:-0} -gt 0 ]] && line="󰛓 ${brew_count} (brew)"
  [[ ${cask_count:-0} -gt 0 ]] && line="${line}${line:+,}󰛓 ${cask_count} (brew-cask)"
  [[ -n "${line}" ]] && group_parts[brew]="${line}"
fi

# Flatpak / Snap.
if command -v flatpak >/dev/null 2>&1; then
  count=$(flatpak list --app 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && group_parts[flatpak]="󰘚 ${count} (flatpak)"
fi
if command -v snap >/dev/null 2>&1; then
  count=$(snap list 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[snap]="󱘖 ${count} (snap)"
fi

# Nix (user / system / default).
if command -v nix-env >/dev/null 2>&1 && [ -d "/nix/var/nix/profiles/per-user/${USER:-$(whoami)}" ]; then
  count=$(nix-env -q 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && group_parts[nix]="${group_parts[nix]:+${group_parts[nix]},} ${count} (nix-user)"
fi
if [ -d /run/current-system/sw/bin ]; then
  count=$(ls -1 /run/current-system/sw/bin 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && group_parts[nix]="${group_parts[nix]:+${group_parts[nix]},} ${count} (nix-system)"
fi
if command -v nix-env >/dev/null 2>&1 && [ -e /nix/var/nix/profiles/default ]; then
  count=$(nix-env -p /nix/var/nix/profiles/default -q 2>/dev/null || true)
  count=$(printf "%s" "$count" | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && group_parts[nix]="${group_parts[nix]:+${group_parts[nix]},} ${count} (nix-default)"
fi

# Output in a consistent order, one family per line.
# -----------------------------------------------------------------------------
# Subsequent lines are indented using FASTFETCH_INDENT (if fastfetch provides it),
# otherwise we move the cursor ~40 cols to the right to line up with the value column.
order=(brew arch dpkg dnf zypper flatpak snap nix)
indent=${FASTFETCH_INDENT:-$'\033[40C'}
first_line_printed=0
for key in "${order[@]}"; do
  line="${group_parts[$key]:-}"
  [[ -z "$line" ]] && continue
  # Ensure comma-space between entries on same line for readability.
  line="${line//,/,\ }"
  if (( first_line_printed == 0 )); then
    printf "%s\n" "$line"
    first_line_printed=1
  else
    printf "%s%s\n" "$indent" "$line"
  fi
done

if (( first_line_printed == 0 )); then
  echo "none"
fi
