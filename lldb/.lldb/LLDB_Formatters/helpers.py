# ---------------------------------------------------------------------- #
# FILE: helpers.py
#
# DESCRIPTION:
# This module provides a collection of shared utility functions, global
# configuration variables, and constants used across the entire
# 'LLDB_Formatters' package.
#
# It centralizes common logic to avoid code duplication and includes:
#   - Generic helper functions to interact with LLDB's SBValue and SBType.
#   - Global settings that can be modified at runtime (e.g., via the
#     'formatter_config' command).
#   - ANSI color code definitions for colored console output.
#   - A conditional debug printing utility.
# ---------------------------------------------------------------------- #

import os

# ----- Global Configuration Settings ----- #
# These can be changed at runtime using the 'formatter_config' command.
g_summary_max_items = 30
g_graph_max_neighbors = 10


# ----- ANSI Color Codes ----- #
# List of colors used in prints.
class Colors:
    RESET = "\x1b[0m"
    BOLD_CYAN = "\x1b[1;36m"
    YELLOW = "\x1b[33m"
    GREEN = "\x1b[32m"
    MAGENTA = "\x1b[35m"
    RED = "\x1b[31m"


# ----- Debug flag to control print statements ----- #
DEBUG_ENABLED = False  # Set to True to see detailed debug output in the LLDB console


def debug_print(message):
    """Prints a message only if debugging is enabled."""
    if DEBUG_ENABLED:
        print(f"[Formatter Debug] {message}")


# ----- Generic Helpers ----- #
def get_child_member_by_names(value, names):
    """
    Attempts to find and return the first valid child member from a list of possible names.
    """
    for name in names:
        child = value.GetChildMemberWithName(name)
        if child.IsValid():
            return child
    return None


def get_raw_pointer(value):
    """
    Extracts the raw pointer address from a raw pointer, unique_ptr, or shared_ptr.
    """
    if not value or not value.IsValid():
        return 0

    # If it's already a pointer, just get the value
    if value.GetType().IsPointerType():
        return value.GetValueAsUnsigned()

    # For smart pointers, try to get the internal pointer by common names
    ptr_member = get_child_member_by_names(value, ["_M_ptr", "__ptr_", "pointer"])
    if ptr_member and ptr_member.IsValid():
        return ptr_member.GetValueAsUnsigned()

    return value.GetValueAsUnsigned()  # Fallback for other smart pointer-like types


def type_has_field(type_obj, field_name):
    """
    Checks if an SBType has a field with the given name by iterating.
    """
    for i in range(type_obj.GetNumberOfFields()):
        if type_obj.GetFieldAtIndex(i).GetName() == field_name:
            return True
    return False


def get_value_summary(value_child):
    """
    Extracts a displayable string from a value SBValue, preferring GetSummary.
    """
    if not value_child or not value_child.IsValid():
        return f"{Colors.RED}[invalid]{Colors.RESET}"

    # GetSummary() often provides a better representation (e.g., for strings)
    summary = value_child.GetSummary()
    if summary:
        # Remove quotes for cleaner display inside our own formatting
        return summary.strip('"')

    # Fallback to GetValue() if no summary is available
    return value_child.GetValue()


def should_use_colors():
    """
    Returns True if the script is likely running in a terminal that
    supports ANSI color codes (like CodeLLDB's debug console or a real terminal).
    """
    return os.environ.get("TERM_PROGRAM") == "vscode"
