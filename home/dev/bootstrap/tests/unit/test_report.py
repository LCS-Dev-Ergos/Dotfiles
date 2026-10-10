"""The text report names what each row observed."""

import contextlib
import io
import unittest

from core import cli


def rendered(*rows):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        cli.report({"action": "verify", "runtimes": list(rows)}, False)
    return output.getvalue().splitlines()


class TextReportTests(unittest.TestCase):
    def test_a_health_row_shows_the_release_that_runs(self):
        # A switch on another compiler is healthy, but not the default.
        row = {
            "state": "ok",
            "language": "ocaml",
            "version": "5.5.1",
            "actualVersion": "5.4.1",
            "path": "/opam/rocq-test",
        }
        self.assertEqual(
            rendered(row),
            [
                "ok       ocaml  5.4.1    /opam/rocq-test",
                "         the declared default is 5.5.1",
            ],
        )

    def test_a_row_that_runs_the_default_prints_one_line(self):
        exact = {
            "state": "ok",
            "language": "rust",
            "version": "1.99.0",
            "path": "/rustup/toolchains/1.99.0",
        }
        health = dict(exact, actualVersion="1.99.0")
        self.assertEqual(
            rendered(exact, health),
            ["ok       rust   1.99.0   /rustup/toolchains/1.99.0"] * 2,
        )


if __name__ == "__main__":
    unittest.main()
