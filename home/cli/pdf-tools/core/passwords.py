"""Passwords: asked for at the terminal or read from a file, never argv.

A password on the command line would sit in the shell history and in the
process list, where other users can read it. One is typed at a terminal,
without echo, or read from a file the user names; protecting a file asks
twice, so a typo cannot lock it for good.
"""

import getpass
import os
import stat
import sys
from pathlib import Path

import pikepdf

from .documents import ToolError


def ask(
    prompt: str, source: Path | None = None, *, confirm: bool = False
) -> str:
    """A password from ``source`` (first line) or the terminal.

    Raises:
        ToolError: If there is no terminal and no file, the file cannot be
            read, the password is empty, or the confirmation differs.
    """
    if source is not None:
        password = _from_file(source)
    elif sys.stdin.isatty():
        try:
            password = getpass.getpass(f"{prompt}: ")
            if confirm and getpass.getpass("Again, to confirm: ") != password:
                raise ToolError("The passwords differ; nothing was changed")
        except EOFError as error:
            raise ToolError("No password was given") from error
    else:
        raise ToolError(
            "No terminal to ask for the password; --password-file reads it "
            "from a file"
        )
    if not password:
        raise ToolError("The password is empty")
    return password


def _from_file(source: Path) -> str:
    """The first line of a password file, without its line break.

    A pipe works too, so ``--password-file <(op read ...)`` hands a secret
    over without it touching the disk.

    Raises:
        ToolError: If the file cannot be read or is a device or folder.
    """
    try:
        with source.open(encoding="utf-8") as handle:
            mode = os.fstat(handle.fileno()).st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISFIFO(mode)):
                raise ToolError(f"{source} is not a file or a pipe")
            return handle.readline().rstrip("\r\n")
    except (OSError, UnicodeDecodeError) as error:
        raise ToolError(f"Cannot read {source}: {error}") from error


def encryption(password: str) -> pikepdf.Encryption:
    """AES-256 protection that opens with the password and allows all.

    The owner password is the same: whoever can open the file may also
    change it, which is what a personal password means.
    """
    return pikepdf.Encryption(owner=password, user=password, R=6)
