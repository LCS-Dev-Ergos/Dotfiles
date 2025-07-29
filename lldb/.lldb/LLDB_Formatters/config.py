# ---------------------------------------------------------------------- #
# FILE: config.py
#
# DESCRIPTION:
# This module implements the user-facing configuration command for the
# formatters. It allows users to inspect and modify global settings
# at runtime directly from the LLDB console.
#
# It contains the implementation for the 'formatter_config' command,
# which provides an interface to the global variables defined in
# the 'helpers.py' module.
# ---------------------------------------------------------------------- #

from .helpers import (
    g_summary_max_items,
    g_graph_max_neighbors,
)


def formatter_config_command(debugger, command, result, internal_dict):
    """
    Implements the 'formatter_config' command to view and change global settings.
    Usage:
      formatter_config                # View current settings and their descriptions.
      formatter_config <key> <value>  # Set a new value for a setting.
    """
    # We must declare that we intend to MODIFY the global variables.
    global g_summary_max_items, g_graph_max_neighbors

    args = command.split()

    # Case 1: No arguments. Print current settings and descriptions.
    if len(args) == 0:
        result.AppendMessage("Current Formatter Settings:")
        result.AppendMessage(
            f"  - summary_max_items: {g_summary_max_items} (Max items for list/tree summaries)"
        )
        result.AppendMessage(
            f"  - graph_max_neighbors: {g_graph_max_neighbors} (Max neighbors in graph node summaries)"
        )
        result.AppendMessage(
            "\nUse 'formatter_config <key> <value>' to change a setting."
        )
        return

    # Case 2: Wrong number of arguments.
    if len(args) != 2:
        result.SetError("Usage: formatter_config <setting_name> <value>")
        return

    # Case 3: Set a value.
    key = args[0]
    value_str = args[1]

    try:
        value = int(value_str)
    except ValueError:
        result.SetError(f"Invalid value. '{value_str}' is not a valid integer.")
        return

    if key == "summary_max_items":
        g_summary_max_items = value
        result.AppendMessage(f"Set summary_max_items -> {value}")
    elif key == "graph_max_neighbors":
        g_graph_max_neighbors = value
        result.AppendMessage(f"Set graph_max_neighbors -> {value}")
    else:
        result.SetError(
            f"Unknown setting '{key}'.\nAvailable settings are: 'summary_max_items', 'graph_max_neighbors'"
        )
