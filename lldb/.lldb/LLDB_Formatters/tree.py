# ---------------------------------------------------------------------- #
# FILE: tree.py
#
# DESCRIPTION:
# This module contains all the logic for formatting and visualizing
# tree data structures, supporting both binary and n-ary trees.
#
# Its features include:
#   - A synthetic children provider ('GenericTreeProvider') to allow
#     expanding tree nodes in the debugger's variable view.
#   - A summary provider ('TreeSummary', 'tree_visualizer_provider')
#     that generates a one-line summary or a JSON payload for VS Code.
#   - A suite of 'pptree' commands for printing a visual representation
#     of the tree directly in the LLDB console.
#   - An 'export_tree' command to generate a Graphviz .dot file for
#     offline visualization.
# ---------------------------------------------------------------------- #

from .helpers import (
    Colors,
    get_raw_pointer,
    get_value_summary,
    g_summary_max_items,
    get_child_member_by_names,
    debug_print,
    should_use_colors,
)

import shlex
import os
import json
import base64
import traceback

try:
    import lldb  # type: ignore
    import debugger  # type: ignore
except ImportError:
    # This allows the package to be imported in other contexts without error.
    lldb = None
    debugger = None


# ----- Building the vis.js data for tree visualization ----- #
def _build_visjs_data_for_tree(node_ptr, nodes_list, edges_list, visited_addrs):
    """
    Recursively traverses a tree to build node and edge lists compatible with vis.js.
    This helper is specific to the tree visualization logic.
    """
    node_addr = get_raw_pointer(node_ptr)
    if not node_ptr or node_addr == 0 or node_addr in visited_addrs:
        return

    visited_addrs.add(node_addr)
    node_struct = _safe_get_node_from_pointer(node_ptr)
    if not node_struct or not node_struct.IsValid():
        return

    value = get_child_member_by_names(node_struct, ["value", "val", "data", "key"])
    val_summary = get_value_summary(value)

    # Add the current node to the nodes list
    nodes_list.append(
        {
            "id": node_addr,
            "label": val_summary,
            "title": f"Value: {val_summary}\nAddress: 0x{node_addr:x}",
        }
    )

    # Recurse on all children
    children = _get_node_children(node_struct)
    for child_ptr in children:
        child_addr = get_raw_pointer(child_ptr)
        if child_addr != 0:
            edges_list.append({"from": node_addr, "to": child_addr})
            _build_visjs_data_for_tree(child_ptr, nodes_list, edges_list, visited_addrs)


# ----- Generating the full HTML for tree visualization ----- #
def _get_html_for_tree_visualization(valobj):
    """
    Generates the full, self-contained HTML for visualizing a tree,
    ready to be displayed.
    """
    root_node_ptr = get_child_member_by_names(valobj, ["root", "m_root", "_root"])
    if not root_node_ptr or get_raw_pointer(root_node_ptr) == 0:
        return None  # Return None if the tree is empty

    # 1. Gather tree data
    nodes_data, edges_data, visited_addrs = [], [], set()
    _build_visjs_data_for_tree(root_node_ptr, nodes_data, edges_data, visited_addrs)

    # 2. Prepare data for the template
    type_info_html = f"<h3>Tree: {valobj.GetName()} ({valobj.GetTypeName()})</h3>"
    template_data = {
        "__NODES_DATA__": json.dumps(nodes_data),
        "__EDGES_DATA__": json.dumps(edges_data),
        "__TYPE_INFO_HTML__": type_info_html,
    }

    # 3. Load vis.js and the HTML template
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))

        # Load vis.js library
        visjs_path = os.path.join(script_dir, "templates/vis-network.min.js")
        with open(visjs_path, "r", encoding="utf-8") as f:
            template_data["__VISJS_LIBRARY__"] = f.read()

        # Load the HTML template file
        template_path = os.path.join(script_dir, "templates", "tree_visualizer.html")
        with open(template_path, "r", encoding="utf-8") as f:
            final_html = f.read()

        # Substitute placeholders
        for placeholder, value in template_data.items():
            final_html = final_html.replace(placeholder, str(value))

        return final_html
    except Exception as e:
        # Return an error HTML if something goes wrong
        return f"<html><body>Error generating visualizer: {e}</body></html>"


# ----- Formatter for Trees (Binary and N-ary) ----- #
class GenericTreeProvider:
    """
    Provides 'synthetic children' for tree nodes, allowing them to be expanded in the debugger.
    Handles both binary (left/right) and N-ary (children) trees.
    """

    def __init__(self, valobj, internal_dict):
        self.valobj = valobj
        self.children_member = None
        self.left_member = None
        self.right_member = None
        self.is_nary = False
        self.num_children_val = 0
        self.update()

    def update(self):
        self.children_member = get_child_member_by_names(
            self.valobj, ["children", "m_children"]
        )
        if (
            self.children_member
            and self.children_member.IsValid()
            and self.children_member.MightHaveChildren()
        ):
            self.is_nary = True
            self.num_children_val = self.children_member.GetNumChildren()
        else:
            self.is_nary = False
            self.left_member = get_child_member_by_names(
                self.valobj, ["left", "m_left", "_left"]
            )
            self.right_member = get_child_member_by_names(
                self.valobj, ["right", "m_right", "_right"]
            )

            count = 0
            if self.left_member and get_raw_pointer(self.left_member) != 0:
                count += 1
            if self.right_member and get_raw_pointer(self.right_member) != 0:
                count += 1
            self.num_children_val = count

    def num_children(self):
        return self.num_children_val

    def get_child_at_index(self, index):
        if self.is_nary:
            return (
                self.children_member.GetChildAtIndex(index)
                if self.children_member
                else None
            )
        else:
            current_index = 0
            if self.left_member and get_raw_pointer(self.left_member) != 0:
                if index == current_index:
                    return self.left_member
                current_index += 1
            if self.right_member and get_raw_pointer(self.right_member) != 0:
                if index == current_index:
                    return self.right_member
        return None


# ----- Summary function for Tree Root ----- #
def TreeSummary(valobj, internal_dict, use_colors=None):
    """
    Provides a one-line summary for a tree root using pre-order traversal.
    """
    if use_colors is None:
        use_colors = should_use_colors()

    # Conditionally define colors
    C_GREEN = Colors.GREEN if use_colors else ""
    C_YELLOW = Colors.YELLOW if use_colors else ""
    C_CYAN = Colors.BOLD_CYAN if use_colors else ""
    C_RESET = Colors.RESET if use_colors else ""
    C_RED = Colors.RED if use_colors else ""

    root_node = get_child_member_by_names(valobj, ["root", "m_root", "_root"])
    if not root_node or get_raw_pointer(root_node) == 0:
        return "Tree is empty"

    summary_parts = []
    max_nodes = g_summary_max_items
    visited = set()

    # This inner function performs the recursive traversal
    def _pre_order_traverse(node_ptr):
        """Helper to recursively traverse and collect node values in pre-order."""
        if get_raw_pointer(node_ptr) == 0 or len(summary_parts) >= max_nodes:
            return

        node_addr = get_raw_pointer(node_ptr)
        if node_addr in visited:
            summary_parts.append(f"{C_RED}[CYCLE]{C_RESET}")
            return
        visited.add(node_addr)

        node = _safe_get_node_from_pointer(node_ptr)
        if not node or not node.IsValid():
            return

        # Find value member in the node struct
        value = get_child_member_by_names(node, ["value", "val", "data", "key"])

        # 1. Process the current node (Root) FIRST
        val_str = get_value_summary(value)
        summary_parts.append(f"{C_YELLOW}{val_str}{C_RESET}")

        if len(summary_parts) >= max_nodes:
            return

        # 2. Recurse on all children returned by the generic helper
        children = _get_node_children(node)
        for child in children:
            _pre_order_traverse(child)

    _pre_order_traverse(root_node)

    # Use a more appropriate separator for a hierarchical traversal
    separator = f" {C_CYAN}->{C_RESET} "
    summary_str = separator.join(summary_parts)
    if len(summary_parts) >= max_nodes:
        summary_str += " ..."

    size_member = get_child_member_by_names(valobj, ["size", "m_size", "count"])
    size_str = ""
    if size_member:
        size_str = f"{C_GREEN}size = {size_member.GetValueAsUnsigned()}{C_RESET}, "

    return f"{size_str}[{summary_str}]"


# ----- Tree Visualizer Provider ----- #
def tree_visualizer_provider(valobj, internal_dict):
    """
    This is the main summary provider for Tree structures. It has a dual role:
    1. SIDE EFFECT: If in CodeLLDB, it generates and displays a rich HTML
       visualizer in a new IDE tab using a direct API call.
    2. RETURN VALUE: It always returns a concise, context-aware (colored or
       colorless) text summary to be displayed in the debugger's variable panel.
    """

    # ----- Side Effect: DISABLED ----- #
    # Side Effect: Attempt to display the rich visualizer
    # try:
    #     # 'debugger' module is only available when run by CodeLLDB
    #     from debugger import display_html  # type: ignore
    #
    #     html_content = _get_html_for_tree_visualization(valobj)
    #     if html_content:
    #         # This is the direct command to the VS Code UI
    #         display_html(html_content, title=f"Tree: {valobj.GetName()}")
    #
    # except ImportError:
    #     # Not running inside CodeLLDB, or the API is unavailable. Do nothing.
    #     pass
    # except Exception as e:
    #     # Silently ignore other errors to avoid crashing the summary provider
    #     debug_print(f"Failed to generate/display web visualizer: {e}")

    # Main Purpose: Return the text summary for the panel
    # Use the reliable helper to check if we are in a color-supporting terminal.
    is_terminal = should_use_colors()
    return TreeSummary(valobj, internal_dict, use_colors=is_terminal)


# ----- Helper to safely dereference a node pointer ----- #
def _safe_get_node_from_pointer(node_ptr):
    """
    Safely gets the underlying TreeNode struct from an SBValue that can be
    a raw pointer or a smart pointer, returning the SBValue for the struct.
    """
    if not node_ptr or not node_ptr.IsValid():
        return None

    # Try to handle it as a smart pointer first.
    internal_ptr = get_child_member_by_names(node_ptr, ["_M_ptr", "__ptr_", "pointer"])
    if internal_ptr and internal_ptr.IsValid():
        debug_print("   - Smart pointer detected, dereferencing internal ptr.")
        return internal_ptr.Dereference()

    # Fallback for raw pointers.
    debug_print("   - Assuming raw pointer, dereferencing directly.")
    return node_ptr.Dereference()


# ----- Helper to get children from a tree node (binary or n-ary) ----- #
def _get_node_children(node_struct):
    """
    Gets a list of children for a given tree node SBValue.
    This function is adaptive and handles both n-ary trees (which have a 'children'
    container member) and binary trees (which have 'left' and 'right' members).

    Args:
        node_struct: The SBValue of the dereferenced node struct.

    Returns:
        A list of SBValue objects, where each is a pointer/smart_ptr to a child node.
    """
    children = []

    # First, attempt to find an n-ary style 'children' container (e.g., std::vector).
    # This is the preferred method if available.
    children_container = get_child_member_by_names(
        node_struct, ["children", "m_children"]
    )
    if (
        children_container
        and children_container.IsValid()
        and children_container.MightHaveChildren()
    ):
        for i in range(children_container.GetNumChildren()):
            child = children_container.GetChildAtIndex(i)
            # Ensure the child is a valid pointer before adding
            if child and get_raw_pointer(child) != 0:
                children.append(child)
        return children

    # If no 'children' container is found, fall back to binary tree style.
    left = get_child_member_by_names(node_struct, ["left", "m_left", "_left"])
    if left and get_raw_pointer(left) != 0:
        children.append(left)

    right = get_child_member_by_names(node_struct, ["right", "m_right", "_right"])
    if right and get_raw_pointer(right) != 0:
        children.append(right)

    return children


# ----- Helper functions to collect nodes in different orders (n-ary compatible) ----- #
def _collect_nodes_preorder(node_ptr, nodes_list, visited_addrs=None):
    """
    Collect nodes in pre-order traversal (Root, Children).
    Includes cycle detection to prevent infinite recursion.
    """
    # Initialize the visited set on the first call.
    if visited_addrs is None:
        visited_addrs = set()

    if not node_ptr or get_raw_pointer(node_ptr) == 0:
        return

    node_addr = get_raw_pointer(node_ptr)
    if node_addr in visited_addrs:
        return  # Cycle detected
    visited_addrs.add(node_addr)

    node = _safe_get_node_from_pointer(node_ptr)
    if not node or not node.IsValid():
        return

    # Pre-order: visit root first, then recurse on children.
    nodes_list.append(node_ptr)

    children = _get_node_children(node)
    for child in children:
        _collect_nodes_preorder(child, nodes_list, visited_addrs)


def _collect_nodes_inorder(node_ptr, nodes_list, visited_addrs=None):
    """
    Collect nodes in in-order traversal. Includes cycle detection.
    For binary trees: (Left, Root, Right).
    For n-ary trees, this uses a common generalization: (First Child, Root, Other Children).
    """
    # Initialize the visited set on the first call.
    if visited_addrs is None:
        visited_addrs = set()

    if not node_ptr or get_raw_pointer(node_ptr) == 0:
        return

    node_addr = get_raw_pointer(node_ptr)
    if node_addr in visited_addrs:
        return  # Cycle detected
    visited_addrs.add(node_addr)

    node = _safe_get_node_from_pointer(node_ptr)
    if not node or not node.IsValid():
        return

    children = _get_node_children(node)

    # If there are children, visit the first child's subtree first.
    if children:
        _collect_nodes_inorder(children[0], nodes_list, visited_addrs)

    # Then, visit the root node.
    nodes_list.append(node_ptr)

    # Finally, visit the rest of the children's subtrees.
    for i in range(1, len(children)):
        _collect_nodes_inorder(children[i], nodes_list, visited_addrs)


def _collect_nodes_postorder(node_ptr, nodes_list, visited_addrs=None):
    """
    Collect nodes in post-order traversal (Children, Root).
    Includes cycle detection to prevent infinite recursion.
    """
    # Initialize the visited set on the first call.
    if visited_addrs is None:
        visited_addrs = set()

    if not node_ptr or get_raw_pointer(node_ptr) == 0:
        return

    node_addr = get_raw_pointer(node_ptr)
    if node_addr in visited_addrs:
        return  # Cycle detected
    visited_addrs.add(node_addr)

    node = _safe_get_node_from_pointer(node_ptr)
    if not node or not node.IsValid():
        return

    # Post-order: recurse on children first, then visit root.
    children = _get_node_children(node)
    for child in children:
        _collect_nodes_postorder(child, nodes_list, visited_addrs)

    nodes_list.append(node_ptr)


# ----- Helper for the Pre-Order "drawing" view ----- #
def _recursive_preorder_print(node_ptr, prefix, is_last, result, visited_addrs=None):
    """Helper function to recursively "draw" the tree in Pre-Order."""
    # Initialize the visited set on the first call to prevent cycles.
    if visited_addrs is None:
        visited_addrs = set()

    if not node_ptr or get_raw_pointer(node_ptr) == 0:
        return

    node_addr = get_raw_pointer(node_ptr)
    if node_addr in visited_addrs:
        result.AppendMessage(
            f"{prefix}{'└── ' if is_last else '├── '}{Colors.RED}[CYCLE]{Colors.RESET}"
        )
        return
    visited_addrs.add(node_addr)

    node = _safe_get_node_from_pointer(node_ptr)
    if not node or not node.IsValid():
        return

    value = get_child_member_by_names(node, ["value", "val", "data", "key"])
    value_summary = get_value_summary(value)

    # Process the node first
    result.AppendMessage(
        f"{prefix}{'└── ' if is_last else '├── '}{Colors.YELLOW}{value_summary}{Colors.RESET}"
    )

    # Then recurse on children, using the centralized helper function.
    # This ensures consistency with other commands and supports n-ary trees.
    children = _get_node_children(node)

    for i, child in enumerate(children):
        new_prefix = f"{prefix}{'    ' if is_last else '│   '}"
        _recursive_preorder_print(
            child, new_prefix, i == len(children) - 1, result, visited_addrs
        )


# ----- Central dispatcher to handle all 'pptree' commands ----- #
def _pptree_command_dispatcher(debugger, command, result, internal_dict, order):
    """
    A single function to handle the logic for all traversal commands.
    'order' can be 'preorder', 'inorder', or 'postorder'.
    - 'preorder' prints a visual tree structure.
    - 'inorder' and 'postorder' print a sequential list of node values.
    """
    args = shlex.split(command)
    if not args:
        result.SetError(f"Usage: pptree_{order} <variable_name>")
        return

    frame = (
        debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
    )
    if not frame.IsValid():
        result.SetError("Cannot execute command: invalid execution context.")
        return

    tree_val = frame.FindVariable(args[0])
    if not tree_val or not tree_val.IsValid():
        result.SetError(f"Could not find variable '{args[0]}'.")
        return

    root_node_ptr = get_child_member_by_names(tree_val, ["root", "m_root", "_root"])
    if not root_node_ptr or get_raw_pointer(root_node_ptr) == 0:
        result.AppendMessage("Tree is empty.")
        return

    result.AppendMessage(
        f"{tree_val.GetTypeName()} at {tree_val.GetAddress()} ({order.capitalize()}):"
    )

    # Select the correct approach based on the order
    if order == "preorder":
        # Pre-order traversal is well-suited for a recursive visual print.
        # We pass an empty string for prefix and True for is_last for the root call.
        _recursive_preorder_print(root_node_ptr, "", True, result)

    elif order in ["inorder", "postorder"]:
        # For in-order and post-order, reconstructing a visual tree is misleading.
        # The correct and clearest output is a sequential list of values.
        nodes_list = []
        if order == "inorder":
            # The 'visited' set is now handled internally by the function.
            _collect_nodes_inorder(root_node_ptr, nodes_list)
        else:  # postorder
            _collect_nodes_postorder(root_node_ptr, nodes_list)

        if not nodes_list:
            result.AppendMessage("[]")
            return

        summary_parts = []
        for node_ptr in nodes_list:
            node = _safe_get_node_from_pointer(node_ptr)
            if not node or not node.IsValid():
                continue

            value = get_child_member_by_names(node, ["value", "val", "data", "key"])
            summary_parts.append(
                f"{Colors.YELLOW}{get_value_summary(value)}{Colors.RESET}"
            )

        result.AppendMessage(f"[{' -> '.join(summary_parts)}]")


# ----- The user-facing command functions are now simple one-liners ----- #
def pptree_preorder_command(debugger, command, result, internal_dict):
    """Implements the 'pptree_preorder' command."""
    _pptree_command_dispatcher(debugger, command, result, internal_dict, "preorder")


def pptree_inorder_command(debugger, command, result, internal_dict):
    """Implements the 'pptree_inorder' command."""
    _pptree_command_dispatcher(debugger, command, result, internal_dict, "inorder")


def pptree_postorder_command(debugger, command, result, internal_dict):
    """Implements the 'pptree_postorder' command."""
    _pptree_command_dispatcher(debugger, command, result, internal_dict, "postorder")


# ----- JSON Tree Visualizer ----- #
# tree.py (versione corretta)


def _build_json_tree_node(node_ptr, depth):
    """
    Recursive helper to build a Python dictionary representing the tree node
    and its descendants, ready to be serialized to JSON.
    """
    # SAFETY CHECK 1: Maximum recursion depth
    MAX_DEPTH = 50
    if depth > MAX_DEPTH:
        return {"name": f"[RECURSION DEPTH LIMIT REACHED AT {MAX_DEPTH}]"}

    # SAFETY CHECK 2: Null pointer
    if not node_ptr or get_raw_pointer(node_ptr) == 0:
        return None

    # SAFETY CHECK 3: Valid node struct
    node = _safe_get_node_from_pointer(node_ptr)
    if not node or not node.IsValid():
        return {"name": "[ERROR: Could not dereference node pointer]"}

    # Estrai il valore del nodo
    value = get_child_member_by_names(node, ["value", "val", "data", "key"])
    val_summary = get_value_summary(value)

    json_node = {"name": val_summary}
    json_children = []

    # --- CHIAVE DELLA SOLUZIONE ---
    # Usa l'helper generico per ottenere tutti i figli,
    # indipendentemente dal fatto che sia un albero binario o n-ario.
    children_pointers = _get_node_children(node)

    # Itera sui figli trovati e costruisci ricorsivamente il JSON per ciascuno
    for child_ptr in children_pointers:
        json_child = _build_json_tree_node(child_ptr, depth + 1)
        if json_child:
            json_children.append(json_child)

    # Se sono stati trovati dei figli, aggiungili al nodo JSON corrente
    if json_children:
        json_node["children"] = json_children

    return json_node


# ----- Main JSON Provider Function ----- #
def get_tree_json(valobj):
    """
    This is the main JSON provider function. It now initiates the
    recursive build with an initial depth of 0.
    """
    root_node_ptr = get_child_member_by_names(valobj, ["root", "m_root", "_root"])
    if not root_node_ptr or get_raw_pointer(root_node_ptr) == 0:
        return {"kind": {"tree": True}, "root": {"name": "[Empty Tree]"}}

    # Start the recursion with depth=0
    json_root = _build_json_tree_node(root_node_ptr, depth=0)

    # The final JSON payload expected by CodeLLDB's tree visualizer
    return {"kind": {"tree": True}, "root": json_root}


# ----- Section: Debugging Helper Command ----- #
def test_visualizer_command(debugger, command, result, internal_dict):
    """
    A temporary debug command to run the visualizer provider and print
    the full Python traceback to the console if it fails.
    Usage: test_visualizer <variable_name>
    """
    args = command.split()
    if not args:
        result.SetError("Usage: test_visualizer <variable_name>")
        return

    frame = (
        debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
    )
    if not frame.IsValid():
        result.SetError("Cannot execute: invalid frame.")
        return

    var_to_test = frame.FindVariable(args[0])
    if not var_to_test or not var_to_test.IsValid():
        result.SetError(f"Could not find variable '{args[0]}'.")
        return

    # ----- This is the core of the debug tool ----- #
    try:
        # We explicitly call the function that is crashing.
        output = tree_visualizer_provider(var_to_test, internal_dict)

        # If it succeeds, print the output.
        result.AppendMessage(
            "--- Visualizer function executed successfully. Output: ---"
        )
        result.AppendMessage(output)

    except Exception:
        # If it crashes, we catch the exception and print the FULL traceback
        # into LLDB's result stream, so we can finally see it.
        result.SetError("!!! Visualizer function crashed. Traceback follows: !!!")
        traceback.print_exc(file=result.GetErrorFile())


# ----- Helper to build Graphviz .dot content for a tree (now n-ary compatible) ----- #
def _build_dot_for_tree(
    smart_ptr_sbvalue, dot_lines, visited_nodes, traversal_map=None
):
    """
    Recursive helper to traverse a tree and generate Graphviz .dot content.
    This version uses horizontal HTML-like labels for a clear and compact
    representation of traversal order and node value.
    """
    node_addr = get_raw_pointer(smart_ptr_sbvalue)

    if node_addr == 0 or node_addr in visited_nodes:
        return
    visited_nodes.add(node_addr)

    node_struct = _safe_get_node_from_pointer(smart_ptr_sbvalue)
    if not node_struct or not node_struct.IsValid():
        return

    # Get node value and escape special HTML characters for safety in labels.
    value = get_child_member_by_names(node_struct, ["value", "val", "data", "key"])
    val_summary = get_value_summary(value)
    # Correctly formatted, multi-line replace calls for readability
    val_summary_escaped = (
        val_summary.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )

    # Label Generation Logic
    if traversal_map and node_addr in traversal_map:
        # ADVANCED HORIZONTAL LABEL
        # A single row (<TR>) with two cells (<TD>) makes the layout horizontal.
        order_index = traversal_map[node_addr]
        label_html = f"""<
<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="5" STYLE="ROUNDED">
  <TR>
    <TD BGCOLOR="#FFDDC1" VALIGN="MIDDLE"><b>{order_index}</b></TD>
    <TD VALIGN="MIDDLE">{val_summary_escaped}</TD>
  </TR>
</TABLE>>"""
        dot_lines.append(f"  Node_{node_addr} [shape=plain, label={label_html}];")
    else:
        # SIMPLE LABEL (classic circle)
        # If no traversal order is specified, we fall back to the simple and clear circular node.
        dot_lines.append(f'  Node_{node_addr} [label="{val_summary_escaped}"];')

    # Get all children (binary or n-ary) and create edges to them.
    children = _get_node_children(node_struct)
    for child_ptr in children:
        child_addr = get_raw_pointer(child_ptr)
        if child_addr != 0:
            dot_lines.append(f"  Node_{node_addr} -> Node_{child_addr};")
            _build_dot_for_tree(child_ptr, dot_lines, visited_nodes, traversal_map)


# ----- LLDB Command to Export Tree as Graphviz .dot File ----- #
def export_tree_command(debugger, command, result, internal_dict):
    """
    Implements the 'export_tree' command. It traverses a tree structure
    and writes a Graphviz .dot file to disk.
    Usage: (lldb) export_tree <variable_name> [output_file.dot] [order]
           'order' can be one of 'preorder', 'inorder', 'postorder'.
           If 'order' is specified, nodes will be labeled with their traversal index.
    """
    args = shlex.split(command)
    if not args:
        result.SetError(
            "Usage: export_tree <variable_name> [output_file.dot] [traversal_order]"
        )
        return

    var_name = args[0]
    output_filename = args[1] if len(args) > 1 else "tree.dot"
    traversal_order = args[2].lower() if len(args) > 2 else None

    valid_orders = ["preorder", "inorder", "postorder"]
    if traversal_order and traversal_order not in valid_orders:
        result.SetError(
            f"Invalid traversal order '{traversal_order}'. Valid options are: {', '.join(valid_orders)}"
        )
        return

    frame = (
        debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
    )
    if not frame.IsValid():
        result.SetError("Cannot execute 'export_tree': invalid execution context.")
        return

    tree_val = frame.FindVariable(var_name)
    if not tree_val or not tree_val.IsValid():
        result.SetError(f"Could not find a variable named '{var_name}'.")
        return

    root_node_ptr = get_child_member_by_names(tree_val, ["root", "m_root", "_root"])
    if not root_node_ptr or get_raw_pointer(root_node_ptr) == 0:
        result.AppendMessage("Tree is empty or root pointer not found.")
        return

    # If a traversal order is requested, collect nodes and create a map of [address -> index]
    traversal_map = None
    if traversal_order:
        nodes_in_order = []
        if traversal_order == "preorder":
            _collect_nodes_preorder(root_node_ptr, nodes_in_order)
        elif traversal_order == "inorder":
            _collect_nodes_inorder(root_node_ptr, nodes_in_order)
        elif traversal_order == "postorder":
            _collect_nodes_postorder(root_node_ptr, nodes_in_order)

        # Create a mapping from a node's memory address to its 1-based index in the traversal
        traversal_map = {
            get_raw_pointer(node): i + 1 for i, node in enumerate(nodes_in_order)
        }

    # Build the .dot file content recursively
    dot_lines = [
        "digraph Tree {",
        f"  dpi={300};",
        "  node [shape=plain];",
    ]
    visited_nodes = set()
    _build_dot_for_tree(root_node_ptr, dot_lines, visited_nodes, traversal_map)
    dot_lines.append("}")
    dot_content = "\n".join(dot_lines)

    # Write the content to the output file
    try:
        with open(output_filename, "w") as f:
            f.write(dot_content)
        result.AppendMessage(f"Successfully exported tree to '{output_filename}'.")
        if traversal_order:
            result.AppendMessage(
                f"Node labels are annotated with '{traversal_order}' traversal index."
            )
        result.AppendMessage(
            f"Run this command to generate the image: {Colors.BOLD_CYAN}dot -Tpng {output_filename} -o tree.png{Colors.RESET}"
        )
    except IOError as e:
        result.SetError(f"Failed to write to file '{output_filename}': {e}")
