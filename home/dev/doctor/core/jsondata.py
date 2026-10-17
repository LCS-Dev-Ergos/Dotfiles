"""Typed views of parsed JSON values."""

from typing import cast


def as_object(value: object) -> dict[str, object] | None:
    """A JSON object as a dictionary, or None when ``value`` is not one.

    JSON object keys are always strings, so the cast only names what the
    parser produced.
    """
    if isinstance(value, dict):
        return cast("dict[str, object]", value)
    return None


def as_array(value: object) -> list[object] | None:
    """A JSON array as a list, or None when ``value`` is not one."""
    if isinstance(value, list):
        return cast("list[object]", value)
    return None
