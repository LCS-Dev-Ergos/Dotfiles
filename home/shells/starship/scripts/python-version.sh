#!/bin/sh
# Answers Starship's `python --version` probe (python_binary, wired up in
# ../default.nix) without paying for pyenv on every prompt. Through a pyenv
# shim, `python --version` goes through `pyenv exec` and its plugin hooks,
# which costs about 200 ms; everything below is file reads in this shell.
#
#   1. An active virtualenv, then the nearest project .venv above the
#      working directory (uv, poetry, python -m venv; $HOME itself does not
#      count): report the version its pyvenv.cfg records. That .venv is what
#      `uv run` uses, even when it is not activated and PATH points elsewhere.
#   2. `python` resolving to a pyenv shim: run the selected version's
#      interpreter directly, choosing it the way pyenv does (PYENV_VERSION,
#      then the nearest .python-version, then the global version file).
#   3. Anything else: the first python in PATH, exactly as Starship would.

pyvenv_version() {
  [ -r "$1" ] || return 1
  while IFS='= ' read -r key value; do
    case $key in
    version | version_info)
      printf 'Python %s\n' "$value"
      return 0
      ;;
    esac
  done <"$1"
  return 1
}

pyenv_file_version() {
  # Match pyenv's comment/blank-line handling, selecting one safe probe name.
  while read -r selected _ || [ -n "$selected" ]; do
    selected=${selected%"$(printf '\r')"}
    case $selected in
      ''|\#*) continue ;;
      *) printf '%s\n' "$selected"; return 0 ;;
    esac
  done < "$1"
  return 1
}

if [ -n "${VIRTUAL_ENV:-}" ] && pyvenv_version "$VIRTUAL_ENV/pyvenv.cfg"; then
  exit 0
fi
dir=$PWD
while [ -n "$dir" ] && [ "$dir" != "$HOME" ]; do
  pyvenv_version "$dir/.venv/pyvenv.cfg" && exit 0
  dir=${dir%/*}
done

pyenv_root=${PYENV_ROOT:-$HOME/.pyenv}
for binary in python python3 python2; do
  command -v "$binary" >/dev/null 2>&1 || continue
  case $(command -v "$binary") in
"$pyenv_root/shims/$binary")
  name=${PYENV_VERSION%%:*}
  if [ -z "$name" ]; then
    dir=$PWD
    while [ -n "$dir" ]; do
      if [ -r "$dir/.python-version" ]; then
        name=$(pyenv_file_version "$dir/.python-version")
        break
      fi
      dir=${dir%/*}
    done
  fi
  if [ -z "$name" ] && [ -r "$pyenv_root/version" ]; then
    name=$(pyenv_file_version "$pyenv_root/version")
  fi
  # A selector is an installed name, never a pathname. Do not let a shim
  # reread other, unchecked lines or entries in the project version file.
  case $name in
    '') name=system ;;
    .|..|*[!a-zA-Z0-9._-]*) exit 1 ;;
  esac
  if [ -x "$pyenv_root/versions/$name/bin/$binary" ]; then
    exec "$pyenv_root/versions/$name/bin/$binary" "$@"
  fi
  PYENV_VERSION=$name
  export PYENV_VERSION
  ;;
  esac
  # The first available candidate owns the result, including probe failure.
  # shellcheck disable=SC2093
  exec "$binary" "$@"
done
exit 1
