"""Operational failures reported by the CLI without a traceback."""


class BootstrapError(Exception):
    """An expected bootstrap prerequisite, identity or installation failure."""
