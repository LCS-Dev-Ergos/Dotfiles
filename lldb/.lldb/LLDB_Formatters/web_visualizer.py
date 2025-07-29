# ---------------------------------------------------------------------- #
# FILE: web_visualizer.py
#
# DESCRIPTION:
# This module implements advanced, interactive data structure
# visualizations by generating self-contained HTML files that use the
# 'vis.js' JavaScript library.
#
# It provides three main commands:
#   - 'export_list_web': Generates an interactive, linear view of a
#     linked list with traversal animation.
#   - 'export_tree_web': Generates an interactive, hierarchical view
#     of a tree structure.
#   - 'export_graph_web': Generates an interactive, physics-based
#     force-directed layout of a graph structure.
#
# The generated HTML file is automatically opened in the user's
# default web browser.
# ---------------------------------------------------------------------- #

from .helpers import (
    get_child_member_by_names,
    get_raw_pointer,
    get_value_summary,
    type_has_field,
)

from .tree import (
    _safe_get_node_from_pointer,
    _get_node_children,
    _collect_nodes_preorder,
)

import json
import tempfile
import webbrowser
import os
import shlex
import string


# ----- Helper to build JSON for vis.js (for Trees) ----- #
def _build_visjs_data(node_ptr, nodes_list, edges_list, visited_addrs):
    """
    Recursively traverses a tree to build node and edge lists compatible with vis.js.
    """
    node_addr = get_raw_pointer(node_ptr)
    if not node_ptr or node_addr == 0 or node_addr in visited_addrs:
        return

    visited_addrs.add(node_addr)
    node_struct = _safe_get_node_from_pointer(node_ptr)
    if not node_struct or not node_struct.IsValid():
        return

    # Get node value and children
    value = get_child_member_by_names(node_struct, ["value", "val", "data", "key"])
    val_summary = get_value_summary(value)
    children = _get_node_children(node_struct)

    # Prepare the title string for the node
    title_str = f"Value: {val_summary}\nAddress: 0x{node_addr:x}"
    if children:
        title_str += "\n\nChildren:"
        for child_ptr in children:
            child_addr = get_raw_pointer(child_ptr)
            if child_addr != 0:
                title_str += f"\n - 0x{child_addr:x}"

    # Add the current node to the nodes list with the new 'title' field
    nodes_list.append(
        {
            "id": node_addr,
            "label": val_summary,
            "title": title_str,
        }
    )

    # Create edges and recurse
    for child_ptr in children:
        child_addr = get_raw_pointer(child_ptr)
        if child_addr != 0:
            edges_list.append({"from": node_addr, "to": child_addr})
            _build_visjs_data(child_ptr, nodes_list, edges_list, visited_addrs)


# ----- Library and Template Loading Logic ----- #
def _load_visjs_library():
    """
    Loads the content of the vis-network.min.js library from a file.
    """
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        visjs_path = os.path.join(script_dir, "templates/vis-network.min.js")
        with open(visjs_path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return "// FAILED TO LOAD VIS.JS LIBRARY"


def _create_and_launch_web_visualizer(template_filename, template_data, result):
    """
    A generic helper to handle the creation of an interactive web visualizer.

    This function performs the common tasks:
    1. Loads the specified HTML template file.
    2. Loads the vis.js library.
    3. Substitutes all placeholders with the provided data.
    4. Writes the result to a temporary file and opens it in the browser.
    """
    # 1. Load the main HTML template from its file.
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        template_path = os.path.join(script_dir, "templates", template_filename)
        with open(template_path, "r", encoding="utf-8") as f:
            final_html = f.read()
    except Exception as e:
        result.SetError(f"Failed to load HTML template '{template_filename}': {e}")
        return

    # 2. Load the vis.js library and add it to the data dictionary.
    visjs_library_content = _load_visjs_library()
    if visjs_library_content.startswith("//"):
        result.SetError(f"Could not load vis.js library: {visjs_library_content}")
        return
    template_data["__VISJS_LIBRARY__"] = visjs_library_content

    # 3. Substitute all placeholders using a loop.
    for placeholder, value in template_data.items():
        str_value = str(value) if not isinstance(value, str) else value
        final_html = final_html.replace(placeholder, str_value)

    # 4. Write the final HTML to a temporary file and open it.
    try:
        with tempfile.NamedTemporaryFile(
            "w", delete=False, suffix=".html", encoding="utf-8"
        ) as f:
            f.write(final_html)
            output_filename = f.name

        webbrowser.open(f"file://{os.path.realpath(output_filename)}")
        result.AppendMessage(
            f"Successfully exported visualizer to '{output_filename}'."
        )
    except Exception as e:
        result.SetError(f"Failed to create or open the HTML file: {e}")


# ----- Web Command for Lists ----- #
def export_list_web_command(debugger, command, result, internal_dict):
    """
    Implements the 'weblist' command. Generates an interactive HTML file for a list.
    Usage: (lldb) weblist <variable_name>
    """
    args = shlex.split(command)
    if not args:
        result.SetError("Usage: weblist <variable_name>")
        return

    var_name = args[0]
    frame = (
        debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
    )
    if not frame.IsValid():
        result.SetError("Cannot execute command: invalid execution context.")
        return

    list_val = frame.FindVariable(var_name)
    if not list_val or not list_val.IsValid():
        result.SetError(f"Could not find variable '{var_name}'.")
        return

    # 1. Traverse the list to gather data.
    head_ptr = get_child_member_by_names(list_val, ["head", "m_head", "_head", "top"])
    if not head_ptr or get_raw_pointer(head_ptr) == 0:
        result.AppendMessage("List is empty or head pointer not found.")
        return

    next_ptr_name, value_name, has_prev_field = None, None, False
    first_node = head_ptr.Dereference()
    if first_node and first_node.IsValid():
        node_type = first_node.GetType()
        for name in ["next", "m_next", "_next", "pNext"]:
            if type_has_field(node_type, name):
                next_ptr_name = name
                break
        for name in ["value", "val", "data", "m_data", "key"]:
            if type_has_field(node_type, name):
                value_name = name
                break
        for name in ["prev", "m_prev", "_prev", "pPrev"]:
            if type_has_field(node_type, name):
                has_prev_field = True
                break

    if not next_ptr_name or not value_name:
        result.SetError(
            "Could not determine list node structure ('next'/'value' members)."
        )
        return

    nodes_data, edges_data, traversal_order, visited_addrs = [], [], [], set()
    current_ptr = head_ptr
    while get_raw_pointer(current_ptr) != 0:
        node_addr = get_raw_pointer(current_ptr)
        if node_addr in visited_addrs:
            break
        visited_addrs.add(node_addr)
        traversal_order.append(node_addr)

        node_struct = current_ptr.Dereference()
        if not node_struct or not node_struct.IsValid():
            break

        val_summary = get_value_summary(node_struct.GetChildMemberWithName(value_name))
        address_str = f"0x{node_addr:x}"

        # Send raw data to the template. The label will be constructed in JS.
        nodes_data.append(
            {
                "id": node_addr,
                "value": val_summary,
                "address": address_str,
            }
        )

        next_ptr = node_struct.GetChildMemberWithName(next_ptr_name)
        if get_raw_pointer(next_ptr) != 0:
            edges_data.append({"from": node_addr, "to": get_raw_pointer(next_ptr)})
        current_ptr = next_ptr

    size_member = get_child_member_by_names(list_val, ["size", "m_size", "count"])
    list_size = size_member.GetValueAsUnsigned() if size_member else len(nodes_data)

    # 2. Prepare the data dictionary for the template.
    template_data = {
        "__NODES_DATA__": json.dumps(nodes_data),
        "__EDGES_DATA__": json.dumps(edges_data),
        "__TRAVERSAL_ORDER_DATA__": json.dumps(traversal_order),
        "__VAR_NAME__": var_name,
        "__TYPE_NAME__": list_val.GetTypeName(),
        "__LIST_SIZE__": list_size,
        "__IS_DOUBLY_LINKED__": json.dumps(has_prev_field),  # Pass the flag to JS
    }

    # 3. Call the generic helper to generate and open the page.
    _create_and_launch_web_visualizer("list_visualizer.html", template_data, result)


# ----- Web Command for Trees ----- #
def export_tree_web_command(debugger, command, result, internal_dict):
    """
    Implements the 'webtree' command. Generates an interactive HTML file for a tree.
    Usage: (lldb) webtree <variable_name>
    """
    args = shlex.split(command)
    if not args:
        result.SetError("Usage: webtree <variable_name>")
        return

    var_name = args[0]
    frame = (
        debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
    )
    if not frame.IsValid():
        result.SetError("Cannot execute command: invalid execution context.")
        return

    tree_val = frame.FindVariable(var_name)
    if not tree_val or not tree_val.IsValid():
        result.SetError(f"Could not find variable '{var_name}'.")
        return

    root_node_ptr = get_child_member_by_names(tree_val, ["root", "m_root", "_root"])
    if not root_node_ptr or get_raw_pointer(root_node_ptr) == 0:
        result.AppendMessage("Tree is empty.")
        return

    # 1. Traverse the tree to gather data.
    nodes_data, edges_data, visited_addrs = [], [], set()
    _build_visjs_data(root_node_ptr, nodes_data, edges_data, visited_addrs)

    preorder_nodes = []
    _collect_nodes_preorder(root_node_ptr, preorder_nodes)
    traversal_order_ids = [get_raw_pointer(node) for node in preorder_nodes]

    type_info = {
        "Variable Name": var_name,
        "Type Name": tree_val.GetTypeName(),
        "Is Pointer": "Yes" if tree_val.GetType().IsPointerType() else "No",
        "Is Reference": "Yes" if tree_val.GetType().IsReferenceType() else "No",
        "Number of Children": tree_val.GetNumChildren(),
    }
    type_info_html = "<h3>Type Information</h3><table>"
    for key, value in type_info.items():
        type_info_html += f"<tr><th>{key}</th><td>{value}</td></tr>"
    type_info_html += "</table>"

    # 2. Prepare the data dictionary for the template.
    template_data = {
        "__NODES_DATA__": json.dumps(nodes_data),
        "__EDGES_DATA__": json.dumps(edges_data),
        "__TRAVERSAL_ORDER_DATA__": json.dumps(traversal_order_ids),
        "__TYPE_INFO_HTML__": type_info_html,
    }

    # 3. Call the generic helper to generate and open the page.
    _create_and_launch_web_visualizer("tree_visualizer.html", template_data, result)


# ----- Web Command for Graphs ----- #
def export_graph_web_command(debugger, command, result, internal_dict):
    """
    Implements the 'webgraph' command. Generates an interactive HTML file for a graph.
    Usage: (lldb) webgraph <variable_name>
    """
    args = shlex.split(command)
    if not args:
        result.SetError("Usage: webgraph <variable_name>")
        return

    var_name = args[0]
    frame = (
        debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
    )
    if not frame.IsValid():
        result.SetError("Cannot execute command: invalid execution context.")
        return

    graph_val = frame.FindVariable(var_name)
    if not graph_val or not graph_val.IsValid():
        result.SetError(f"Could not find variable '{var_name}'.")
        return

    # 1. Traverse the graph to gather data.
    nodes_container = get_child_member_by_names(
        graph_val, ["nodes", "m_nodes", "adj", "adjacency_list"]
    )
    if (
        not nodes_container
        or not nodes_container.IsValid()
        or not nodes_container.MightHaveChildren()
    ):
        result.AppendMessage("Graph is empty or nodes container not found.")
        return

    nodes_data, edges_data, all_edge_tuples = [], [], set()
    # First pass: collect all nodes and their data for tooltips
    all_nodes = [
        nodes_container.GetChildAtIndex(i)
        for i in range(nodes_container.GetNumChildren())
    ]

    for node in all_nodes:
        if node.GetType().IsPointerType():
            node = node.Dereference()
        if not node or not node.IsValid():
            continue

        node_addr = get_raw_pointer(node)
        val_summary = get_value_summary(
            get_child_member_by_names(node, ["value", "val", "data", "key"])
        )

        # Build the title string with value and address
        title_str = f"Value: {val_summary}\nAddress: 0x{node_addr:x}"
        neighbors = get_child_member_by_names(node, ["neighbors", "adj", "edges"])
        if neighbors and neighbors.IsValid() and neighbors.MightHaveChildren():
            title_str += "\n\nNeighbors:"
            for j in range(neighbors.GetNumChildren()):
                neighbor = neighbors.GetChildAtIndex(j)
                if neighbor.GetType().IsPointerType():
                    neighbor = neighbor.Dereference()
                if not neighbor or not neighbor.IsValid():
                    continue
                neighbor_addr = get_raw_pointer(neighbor)
                title_str += f"\n - 0x{neighbor_addr:x}"
                # Add edge only if it hasn't been added yet
                if (node_addr, neighbor_addr) not in all_edge_tuples:
                    edges_data.append({"from": node_addr, "to": neighbor_addr})
                    all_edge_tuples.add((node_addr, neighbor_addr))

        nodes_data.append(
            {
                "id": node_addr,
                "label": val_summary,
                "title": title_str,
            }
        )

    # 2. Prepare the data dictionary for the template.
    template_data = {
        "__NODES_DATA__": json.dumps(nodes_data),
        "__EDGES_DATA__": json.dumps(edges_data),
    }

    # 3. Call the generic helper to generate and open the page.
    _create_and_launch_web_visualizer("graph_visualizer.html", template_data, result)
