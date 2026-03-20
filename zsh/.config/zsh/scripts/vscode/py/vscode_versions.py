from __future__ import annotations

import re

_TOKEN_SPLIT_RE = re.compile(r"[._+-]")


def compare_versions(left: str | None, right: str | None) -> int:
    """Compare VS Code extension versions using shell-compatible token rules."""
    if not left and not right:
        return 0
    if not left:
        return -1
    if not right:
        return 1

    left_parts = [token for token in _TOKEN_SPLIT_RE.split(left) if token]
    right_parts = [token for token in _TOKEN_SPLIT_RE.split(right) if token]
    max_len = max(len(left_parts), len(right_parts))

    for idx in range(max_len):
        left_token = left_parts[idx] if idx < len(left_parts) else "0"
        right_token = right_parts[idx] if idx < len(right_parts) else "0"

        left_is_numeric = left_token.isdigit()
        right_is_numeric = right_token.isdigit()

        if left_is_numeric and right_is_numeric:
            left_value = int(left_token)
            right_value = int(right_token)
            if left_value > right_value:
                return 1
            if left_value < right_value:
                return -1
            continue

        if left_is_numeric and not right_is_numeric:
            return 1
        if not left_is_numeric and right_is_numeric:
            return -1

        left_lower = left_token.lower()
        right_lower = right_token.lower()
        if left_lower > right_lower:
            return 1
        if left_lower < right_lower:
            return -1

    return 0

