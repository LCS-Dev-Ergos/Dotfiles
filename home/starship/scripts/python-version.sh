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

if [ -n "${VIRTUAL_ENV:-}" ] && pyvenv_version "$VIRTUAL_ENV/pyvenv.cfg"; then
  exit 0
fi
dir=$PWD
while [ -n "$dir" ] && [ "$dir" != "$HOME" ]; do
  pyvenv_version "$dir/.venv/pyvenv.cfg" && exit 0
  dir=${dir%/*}
done

pyenv_root=${PYENV_ROOT:-$HOME/.pyenv}
case $(command -v python) in
"$pyenv_root/shims/python")
  name=${PYENV_VERSION%%:*}
  if [ -z "$name" ]; then
    dir=$PWD
    while [ -n "$dir" ]; do
      if [ -r "$dir/.python-version" ]; then
        read -r name _ <"$dir/.python-version"
        break
      fi
      dir=${dir%/*}
    done
  fi
  if [ -z "$name" ] && [ -r "$pyenv_root/version" ]; then
    read -r name _ <"$pyenv_root/version"
  fi
  # "system", or a prefix pyenv resolves itself (3.12 -> 3.12.x), falls
  # through to the shim below.
  if [ -n "$name" ] && [ -x "$pyenv_root/versions/$name/bin/python" ]; then
    exec "$pyenv_root/versions/$name/bin/python" "$@"
  fi
  ;;
esac
exec python "$@"
