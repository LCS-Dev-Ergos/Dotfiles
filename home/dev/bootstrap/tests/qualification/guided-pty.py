#!/usr/bin/env python3
"""Drive one guided setup through a pseudo-terminal, as a person would.

The child gets a real terminal, so dev-bootstrap draws styled output and
asks with the pinned Gum. Each --answer is PATTERN=KEYS: when PATTERN
appears in the screen text, without color or cursor sequences, after the
previous answer, KEYS are typed once (Python escapes: \\r is Enter, \\x1b
Esc). An answer whose pattern never appears is not typed, so a question the
run does not ask is no failure here; the caller reads which ones were.

Usage: guided-pty.py TRANSCRIPT RECORD [--answer PATTERN=KEYS]... -- COMMAND...
TRANSCRIPT receives the raw terminal output, RECORD a JSON object with the
exit status and the answers typed. The exit status is the child's.
"""

import argparse
import fcntl
import json
import os
import pty
import re
import select
import struct
import sys
import termios
import time

# Color, cursor and mode sequences, and terminal queries Gum sends.
CONTROL = re.compile(
    rb"\x1b\[[0-9;?<>=$]*[A-Za-z~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)"
)
# Long enough for a CPython or OCaml source build between two answers.
QUIET = 3600


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("transcript")
    parser.add_argument("record")
    parser.add_argument("--answer", action="append", default=[])
    parser.add_argument("--columns", type=int, default=100)
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()
    answers = []
    for answer in args.answer:
        pattern, _, keys = answer.partition("=")
        answers.append(
            (pattern, keys.encode().decode("unicode_escape").encode())
        )

    child, terminal = pty.fork()
    if child == 0:
        os.execvp(args.command[0], args.command)
    fcntl.ioctl(
        terminal,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", 50, args.columns, 0, 0),
    )
    output, typed, seen = b"", [], 0
    while True:
        ready, _, _ = select.select([terminal], [], [], QUIET)
        if not ready:
            os.kill(child, 15)
            break
        try:
            data = os.read(terminal, 65536)
        except OSError:
            # The child closed the terminal: it has exited.
            break
        if not data:
            break
        output += data
        screen = CONTROL.sub(b"", output).decode("utf-8", "replace")
        for index, (pattern, keys) in enumerate(answers):
            position = screen.find(pattern, seen)
            if position < 0:
                continue
            # Let Gum finish drawing before it reads the keys.
            time.sleep(0.5)
            os.write(terminal, keys)
            typed.append(pattern)
            seen = position + len(pattern)
            del answers[index]
            break
    _, status = os.waitpid(child, 0)
    code = os.waitstatus_to_exitcode(status)
    with open(args.transcript, "wb") as file:
        file.write(output)
    with open(args.record, "w") as file:
        json.dump({"exit": code, "answered": typed}, file)
        file.write("\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
