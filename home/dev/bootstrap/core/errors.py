"""Operational failures reported by the CLI without a traceback."""


class BootstrapError(Exception):
    """An expected bootstrap prerequisite, identity or installation failure."""


class Interrupted(BaseException):
    """A termination signal, raised so locks and child processes unwind."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum
