# ---------------------------------------------------------------------- #
# FILE: __init__.py
#
# DESCRIPTION:
# This file is the main entry point for the 'LLDB_Formatters' package.
# It is automatically executed by LLDB when the package is imported via
# the command 'command script import LLDB_Formatters'.
#
# Its primary responsibilities are:
#   - Creating and enabling a dedicated category named 'CustomFormatters'.
#   - Registering all data formatters (summaries and synthetic children)
#     for linear, tree, and graph data structures.
#   - Registering all custom LLDB commands (e.g., 'pptree', 'export_graph',
#     'webtree', 'formatter_config') defined in the other modules.
# ---------------------------------------------------------------------- #

try:
    import lldb  # type: ignore
except ImportError:
    # This allows the package to be imported in other contexts without error.
    lldb = None

# Import the public-facing functions and classes from the other modules
# within this package.
from .config import formatter_config_command
from .helpers import Colors
from .linear import LinearContainerSummary
from .tree import (
    tree_visualizer_provider,
    pptree_preorder_command,
    pptree_inorder_command,
    pptree_postorder_command,
    export_tree_command,
)
from .graph import GraphProvider, GraphNodeSummary, export_graph_command
from .web_visualizer import (
    export_tree_web_command,
    generate_list_visualization_html,
    generate_tree_visualization_html,
    generate_graph_visualization_html,
)
import re


# ----- Help Command ----- #
def formatter_help_command(debugger, command, result, internal_dict):
    """
    Implements the 'formatter_help' command.
    It prints a formatted list of all available custom commands,
    their usage, and aliases.
    """
    C_CMD = Colors.BOLD_CYAN
    C_ARG = Colors.YELLOW
    C_RST = Colors.RESET
    C_TTL = Colors.GREEN

    help_message = f"""
{C_TTL}-----------------------------------------{C_RST}
{C_TTL}  Custom LLDB Formatters - Command List  {C_RST}
{C_TTL}-----------------------------------------{C_RST}

{C_CMD}Configuration:{C_RST}
  formatter_config [{C_ARG}<key> <value>{C_RST}]
    - View or change global settings for the formatters.
    - Example: `formatter_config summary_max_items 50`

{C_CMD}Console Tree Printing:{C_RST}
  pptree [{C_ARG}<variable>{C_RST}] (alias: `pptree_preorder`)
    - Prints a visual tree representation in the console.

  pptree_inorder [{C_ARG}<variable>{C_RST}]
    - Prints tree node values sequentially using in-order traversal.

  pptree_postorder [{C_ARG}<variable>{C_RST}]
    - Prints tree node values sequentially using post-order traversal.

{C_CMD}File Exporters (Graphviz .dot):{C_RST}
  export_tree [{C_ARG}<variable> [file.dot] [order]{C_RST}]
    - Exports a tree to a .dot file. `order` can be 'preorder', etc.

  export_graph [{C_ARG}<variable> [file.dot]{C_RST}]
    - Exports a graph to a .dot file.

{C_CMD}Interactive Web Visualizers:{C_RST}
  weblist [{C_ARG}<variable>{C_RST}]
    - Opens an interactive list visualization in your web browser.

  webtree [{C_ARG}<variable>{C_RST}] (alias: `export_tree_web`)
    - Opens an interactive tree visualization in your web browser.

  webgraph [{C_ARG}<variable>{C_RST}] (alias: `webg`)
    - Opens an interactive graph visualization in your web browser.

{C_CMD}Help:{C_RST}
  formatter_help (alias: `fhelp`)
    - Shows this help message.
"""
    result.AppendMessage(help_message)


# ----- LLDB Module Initialization ----- #
def __lldb_init_module(debugger, internal_dict):
    """
    This is the main entry point that LLDB calls when the 'LLDB_Formatters'
    package is imported. It handles the registration of all formatters and commands.
    """
    if lldb is None:
        print("LLDB module not available - Skipping formatter registration")
        return

    print("Loading custom formatters from 'LLDB_Formatters' package...")

    # ----- Category Setup ----- #
    # All our formatters will be placed in a dedicated category.
    category_name = "CustomFormatters"
    category = debugger.GetCategory(category_name)
    if not category.IsValid():
        category = debugger.CreateCategory(category_name)
    category.SetEnabled(True)

    # ----- Regular Expressions for Type Matching ----- #
    # These regexes identify the C++ types our formatters will apply to.
    list_regex = r"^(Custom|My)?(Linked)?List<.*>$"
    stack_regex = r"^(Custom|My)?Stack<.*>$"
    queue_regex = r"^(Custom|My)?Queue<.*>$"
    tree_regex = r"^(Custom|My)?(Binary)?Tree<.*>$"
    tree_node_regex = r"^(Custom|My|Bin|Binary)?(Tree)?Node<.*>$"
    graph_regex = r"^(Custom|My)?Graph<.*>$"
    graph_node_regex = r"^(Custom|My)?(Graph)?Node<.*>$"

    # ----- Register Data Formatters ----- #
    # Note: When using a package, the function name passed to LLDB must be the
    # full path to the function, e.g., 'LLDB_Formatters.module.function_name'.

    # 1. Linear Structures (List, Stack, Queue)
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(list_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName(
            "LLDB_Formatters.linear.LinearContainerSummary"
        ),
    )
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(stack_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName(
            "LLDB_Formatters.linear.LinearContainerSummary"
        ),
    )
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(queue_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName(
            "LLDB_Formatters.linear.LinearContainerSummary"
        ),
    )

    # 2. Tree Structures
    # This provides the JSON payload for the VS Code visualizer.
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(tree_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName(
            "LLDB_Formatters.tree.tree_visualizer_provider"
        ),
    )

    # 3. Graph Structures
    category.AddTypeSynthetic(
        lldb.SBTypeNameSpecifier(graph_regex, True),
        lldb.SBTypeSynthetic.CreateWithClassName("LLDB_Formatters.graph.GraphProvider"),
    )
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(graph_node_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName(
            "LLDB_Formatters.graph.GraphNodeSummary"
        ),
    )

    # ----- Register Custom LLDB Commands ----- #
    # Each command is defined in its relevant module and registered here.

    # Help command
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.formatter_help_command formatter_help"
    )
    debugger.HandleCommand("command alias fhelp formatter_help")

    # Configuration command
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.config.formatter_config_command formatter_config"
    )

    # Tree commands
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.tree.pptree_preorder_command pptree_preorder"
    )
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.tree.pptree_inorder_command pptree_inorder"
    )
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.tree.pptree_postorder_command pptree_postorder"
    )
    debugger.HandleCommand("command alias pptree pptree_preorder")
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.tree.export_tree_command export_tree"
    )

    # Graph commands
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.graph.export_graph_command export_graph"
    )

    # Web Visualizer commands
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.web_visualizer.export_list_web_command weblist"
    )
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.web_visualizer.export_tree_web_command export_tree_web"
    )
    debugger.HandleCommand("command alias webtree export_tree_web")  # Convenient alias
    debugger.HandleCommand(
        "command script add -f LLDB_Formatters.web_visualizer.export_graph_web_command webgraph"
    )
    debugger.HandleCommand("command alias webg webgraph")  # Convenient alias

    # Custom test command for visualizing data structures
    debugger.HandleCommand(
        "command script add -f lldb_formatters.test_visualizer_command test_visualizer"
    )

    # ----- Final Output Message ----- #
    print(
        f"{Colors.GREEN}Formatters and commands registered in category '{category_name}'.{Colors.RESET}"
    )
    print(
        f"Type '{Colors.BOLD_CYAN}formatter_help{Colors.RESET}' or '{Colors.BOLD_CYAN}fhelp{Colors.RESET}' to see the list of new commands."
    )
