# __init__.py
#
# Main entry point for the 'LLDB_Formatters' LLDB data formatter package.
# This script is executed by LLDB when the package is imported. Its primary role
# is to register all the formatters and custom commands defined in the other
# modules of this package.

try:
    import lldb  # type: ignore
except ImportError:
    # This allows the package to be imported in other contexts without error.
    lldb = None

# Import the public-facing functions and classes from the other modules
# within this package. The '.' prefix indicates a relative import.
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
from .graph import (
    GraphProvider,
    GraphNodeSummary,
    export_graph_command
)
from .web_visualizer import export_tree_web_command


def __lldb_init_module(debugger, internal_dict):
    """
    This is the main entry point that LLDB calls when the 'LLDB_Formatters'
    package is imported. It handles the registration of all formatters and commands.
    """
    if lldb is None:
        print("LLDB module not available - Skipping formatter registration")
        return

    print("Loading custom formatters from 'LLDB_Formatters' package...")

    # --- Category Setup ---
    # All our formatters will be placed in a dedicated category.
    category_name = "CustomFormatters"
    category = debugger.GetCategory(category_name)
    if not category.IsValid():
        category = debugger.CreateCategory(category_name)
    category.SetEnabled(True)

    # --- Regular Expressions for Type Matching ---
    # These regexes identify the C++ types our formatters will apply to.
    list_regex = r"^(Custom|My)?(Linked)?List<.*>$"
    stack_regex = r"^(Custom|My)?Stack<.*>$"
    queue_regex = r"^(Custom|My)?Queue<.*>$"
    tree_regex = r"^(Custom|My)?(Binary)?Tree<.*>$"
    tree_node_regex = r"^(Custom|My|Bin|Binary)?(Tree)?Node<.*>$"
    graph_regex = r"^(Custom|My)?Graph<.*>$"
    graph_node_regex = r"^(Custom|My)?(Graph)?Node<.*>$"

    # --- Register Data Formatters ---
    # Note: When using a package, the function name passed to LLDB must be the
    # full path to the function, e.g., 'LLDB_Formatters.module.function_name'.

    # 1. Linear Structures (List, Stack, Queue)
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(list_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName("LLDB_Formatters.linear.LinearContainerSummary")
    )
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(stack_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName("LLDB_Formatters.linear.LinearContainerSummary")
    )
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(queue_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName("LLDB_Formatters.linear.LinearContainerSummary")
    )

    # 2. Tree Structures
    # This provides the JSON payload for the VS Code visualizer.
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(tree_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName("LLDB_Formatters.tree.tree_visualizer_provider")
    )

    # 3. Graph Structures
    category.AddTypeSynthetic(
        lldb.SBTypeNameSpecifier(graph_regex, True),
        lldb.SBTypeSynthetic.CreateWithClassName("LLDB_Formatters.graph.GraphProvider")
    )
    category.AddTypeSummary(
        lldb.SBTypeNameSpecifier(graph_node_regex, True),
        lldb.SBTypeSummary.CreateWithFunctionName("LLDB_Formatters.graph.GraphNodeSummary")
    )

    # --- Register Custom LLDB Commands ---
    # Each command is defined in its relevant module and registered here.
    
    # Configuration command
    debugger.HandleCommand("command script add -f LLDB_Formatters.config.formatter_config_command formatter_config")

    # Tree commands
    debugger.HandleCommand("command script add -f LLDB_Formatters.tree.pptree_preorder_command pptree_preorder")
    debugger.HandleCommand("command script add -f LLDB_Formatters.tree.pptree_inorder_command pptree_inorder")
    debugger.HandleCommand("command script add -f LLDB_Formatters.tree.pptree_postorder_command pptree_postorder")
    debugger.HandleCommand("command alias pptree pptree_preorder") # Default alias
    debugger.HandleCommand("command script add -f LLDB_Formatters.tree.export_tree_command export_tree")

    # Graph commands
    debugger.HandleCommand("command script add -f LLDB_Formatters.graph.export_graph_command export_graph")

    # Web Visualizer commands
    debugger.HandleCommand("command script add -f LLDB_Formatters.web_visualizer.export_tree_web_command export_tree_web")
    debugger.HandleCommand("command alias webtree export_tree_web") # Convenient alias
    debugger.HandleCommand("command script add -f LLDB_Formatters.web_visualizer.export_graph_web_command webgraph")
    debugger.HandleCommand("command alias webg webgraph") # Convenient alias

    # --- Final Output Message ---
    print(f"{Colors.GREEN}Formatters and commands registered in category '{category_name}'.{Colors.RESET}")
    print("Available commands: 'pptree', 'export_tree', 'export_graph', 'webtree', 'formatter_config', and more.")
