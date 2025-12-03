#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Cross-platform package manager detector for Fastfetch.

set -euo pipefail

declare -A group_parts

# Pacman (Arch) - differentiate official repos from AUR.
if command -v pacman >/dev/null 2>&1; then
  # Pacchetti dai repository ufficiali (-Qqn = native).
  official_count=$(pacman -Qqn 2>/dev/null | wc -l | awk '{print $1}')
  # Pacchetti da AUR (-Qqm = foreign/manually installed).
  aur_count=$(pacman -Qqm 2>/dev/null | wc -l | awk '{print $1}')

  parts=""
  [[ ${official_count:-0} -gt 0 ]] && parts=" ${official_count} (pacman)"
  [[ ${aur_count:-0} -gt 0 ]] && parts="${parts}${parts:+, } ${aur_count} (aur)"
  [[ -n "$parts" ]] && group_parts[arch]="$parts"
fi

# Debian / Ubuntu (dpkg).
if command -v dpkg >/dev/null 2>&1; then
  count=$(dpkg -l 2>/dev/null | awk '/^ii/{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[dpkg]=" ${count} (dpkg)"
fi

# Fedora / RHEL (dnf / yum).
if command -v dnf >/dev/null 2>&1; then
  count=$(dnf list installed 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[dnf]=" ${count} (dnf)"
elif command -v yum >/dev/null 2>&1; then
  count=$(yum list installed 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[dnf]=" ${count} (yum)"
fi

# openSUSE (zypper).
if command -v zypper >/dev/null 2>&1; then
  count=$(zypper se -i 2>/dev/null | awk '/^i/{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[zypper]=" ${count} (zypper)"
fi

# Homebrew (macOS/Linux).
if command -v brew >/dev/null 2>&1; then
  brew_count=$(brew list --formula 2>/dev/null | wc -l | awk '{print $1}')
  cask_count=$(brew list --cask 2>/dev/null | wc -l | awk '{print $1}')
  line=""
  [[ ${brew_count:-0} -gt 0 ]] && line=" ${brew_count} (brew)"
  [[ ${cask_count:-0} -gt 0 ]] && line="${line}${line:+, } ${cask_count} (brew-cask)"
  [[ -n "${line}" ]] && group_parts[brew]="${line}"
fi

# Flatpak / Snap.
if command -v flatpak >/dev/null 2>&1; then
  count=$(flatpak list --app 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && group_parts[flatpak]=" ${count} (flatpak)"
fi
if command -v snap >/dev/null 2>&1; then
  count=$(snap list 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
  [[ ${count:-0} -gt 0 ]] && group_parts[snap]=" ${count} (snap)"
fi

# Nix (user / system / default).
nix_parts=""
if command -v nix-env >/dev/null 2>&1 && [ -d "/nix/var/nix/profiles/per-user/${USER:-$(whoami)}" ]; then
  count=$(nix-env -q 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && nix_parts=" ${count} (nix-user)"
fi
if [ -d /run/current-system/sw/bin ]; then
  count=$(ls -1 /run/current-system/sw/bin 2>/dev/null | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && nix_parts="${nix_parts}${nix_parts:+, } ${count} (nix-system)"
fi
if command -v nix-env >/dev/null 2>&1 && [ -e /nix/var/nix/profiles/default ]; then
  count=$(nix-env -p /nix/var/nix/profiles/default -q 2>/dev/null || true)
  count=$(printf "%s" "$count" | wc -l | awk '{print $1}')
  [[ ${count:-0} -gt 0 ]] && nix_parts="${nix_parts}${nix_parts:+, } ${count} (nix-default)"
fi
[[ -n "$nix_parts" ]] && group_parts[nix]="$nix_parts"

# Output in a consistent order, one family per line.
# -----------------------------------------------------------------------------
# Use box drawing characters for consistent formatting.
order=(brew arch dpkg dnf zypper flatpak snap nix)

# Collect all non-empty lines.
lines=()
for key in "${order[@]}"; do
  line="${group_parts[$key]:-}"
  [[ -z "$line" ]] && continue
  lines+=("$line")
done

# Get indent from fastfetch or default to escape sequence.
indent=${FASTFETCH_INDENT:-$'\033[40C'}

# Output with proper box drawing prefixes.
if (( ${#lines[@]} == 0 )); then
  echo "none"
elif (( ${#lines[@]} == 1 )); then
  # Single line: print newline, then indent + content.
  printf "\n%s└%s" "$indent" "${lines[0]}"
else
  # Multiple lines: print newline, then each line with indent.
  printf "\n"
  for i in "${!lines[@]}"; do
    if (( i == ${#lines[@]} - 1 )); then
      printf "%s└%s\n" "$indent" "${lines[$i]}"
    else
      printf "%s├%s\n" "$indent" "${lines[$i]}"
    fi
  done
fi
