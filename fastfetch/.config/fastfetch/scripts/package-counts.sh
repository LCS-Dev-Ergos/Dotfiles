#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Cross-platform package manager detector for Fastfetch.

set -euo pipefail

declare -A group_parts

# Temporary directory for parallel job results with secure permissions.
tmpdir=$(mktemp -d -t fastfetch-pkg.XXXXXXXXXX)
chmod 700 "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

# Pacman (Arch) - differentiate official repos from AUR.
if command -v pacman >/dev/null 2>&1; then
  (
    official_count=$(pacman -Qqn 2>/dev/null | wc -l | awk '{print $1}')
    aur_count=$(pacman -Qqm 2>/dev/null | wc -l | awk '{print $1}')
    parts=""
    [[ ${official_count:-0} -gt 0 ]] && parts=" ${official_count} (pacman)"
    [[ ${aur_count:-0} -gt 0 ]] && parts="${parts}${parts:+,} ${aur_count} (aur)"
    echo "$parts" > "$tmpdir/arch"
  ) &
fi

# Debian / Ubuntu (dpkg).
if command -v dpkg >/dev/null 2>&1; then
  (
    count=$(dpkg -l 2>/dev/null | awk '/^ii/{c++} END{print c+0}')
    [[ ${count:-0} -gt 0 ]] && echo " ${count} (dpkg)" > "$tmpdir/dpkg"
  ) &
fi

# Fedora / RHEL (dnf / yum).
if command -v dnf >/dev/null 2>&1; then
  (
    count=$(dnf list installed 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
    [[ ${count:-0} -gt 0 ]] && echo " ${count} (dnf)" > "$tmpdir/dnf"
  ) &
elif command -v yum >/dev/null 2>&1; then
  (
    count=$(yum list installed 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
    [[ ${count:-0} -gt 0 ]] && echo " ${count} (yum)" > "$tmpdir/dnf"
  ) &
fi

# openSUSE (zypper).
if command -v zypper >/dev/null 2>&1; then
  (
    count=$(zypper se -i 2>/dev/null | awk '/^i/{c++} END{print c+0}')
    [[ ${count:-0} -gt 0 ]] && echo " ${count} (zypper)" > "$tmpdir/zypper"
  ) &
fi

# Homebrew (macOS/Linux).
if command -v brew >/dev/null 2>&1; then
  (
    brew_count=$(brew list --formula 2>/dev/null | wc -l | awk '{print $1}')
    cask_count=$(brew list --cask 2>/dev/null | wc -l | awk '{print $1}')
    line=""
    [[ ${brew_count:-0} -gt 0 ]] && line=" ${brew_count} (brew)"
    [[ ${cask_count:-0} -gt 0 ]] && line="${line}${line:+,} ${cask_count} (brew-cask)"
    [[ -n "$line" ]] && echo "$line" > "$tmpdir/brew"
  ) &
fi

# Flatpak.
if command -v flatpak >/dev/null 2>&1; then
  (
    count=$(flatpak list --app 2>/dev/null | wc -l | awk '{print $1}')
    [[ ${count:-0} -gt 0 ]] && echo " ${count} (flatpak)" > "$tmpdir/flatpak"
  ) &
fi

# Snap.
if command -v snap >/dev/null 2>&1; then
  (
    count=$(snap list 2>/dev/null | awk 'NR>1{c++} END{print c+0}')
    [[ ${count:-0} -gt 0 ]] && echo " ${count} (snap)" > "$tmpdir/snap"
  ) &
fi

# Nix (user / system / default).
if command -v nix-env >/dev/null 2>&1 || [ -d /run/current-system/sw/bin ]; then
  (
    nix_parts=""
    # Sanitize USER variable to prevent injection.
    safe_user=$(id -un 2>/dev/null || echo "unknown")
    if command -v nix-env >/dev/null 2>&1 && [ -d "/nix/var/nix/profiles/per-user/${safe_user}" ]; then
      count=$(nix-env -q 2>/dev/null | wc -l | awk '{print $1}')
      [[ ${count:-0} -gt 0 ]] && nix_parts=" ${count} (nix-user)"
    fi
    if [ -d /run/current-system/sw/bin ]; then
      count=$(ls -1 /run/current-system/sw/bin 2>/dev/null | wc -l | awk '{print $1}')
      [[ ${count:-0} -gt 0 ]] && nix_parts="${nix_parts}${nix_parts:+,} ${count} (nix-system)"
    fi
    if command -v nix-env >/dev/null 2>&1 && [ -e /nix/var/nix/profiles/default ]; then
      count=$(nix-env -p /nix/var/nix/profiles/default -q 2>/dev/null || true)
      count=$(printf "%s" "$count" | wc -l | awk '{print $1}')
      [[ ${count:-0} -gt 0 ]] && nix_parts="${nix_parts}${nix_parts:+,} ${count} (nix-default)"
    fi
    [[ -n "$nix_parts" ]] && echo "$nix_parts" > "$tmpdir/nix"
  ) &
fi

# Wait for all background jobs to complete.
wait

# Collect results from temporary files.
order=(brew arch dpkg dnf zypper flatpak snap nix)
for key in "${order[@]}"; do
  # Validate key is alphanumeric to prevent path traversal.
  if [[ "$key" =~ ^[a-z]+$ ]] && [[ -f "$tmpdir/$key" ]]; then
    group_parts[$key]=$(cat "$tmpdir/$key")
  fi
done

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
