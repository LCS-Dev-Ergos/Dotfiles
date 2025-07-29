from .helpers import (
    Colors,
    get_child_member_by_names,
    get_raw_pointer,
    get_value_summary,
    debug_print,
    g_graph_max_neighbors,
)


# ----- Formatter for Graphs ----- #
class GraphProvider:
    """
    Provides a summary and synthetic children for an entire Graph structure.
    Displays the graph's nodes as children.
    """

    def __init__(self, valobj, internal_dict):
        self.valobj = valobj
        self.nodes_container = None
        self.update()

    def update(self):
        self.nodes_container = get_child_member_by_names(
            self.valobj, ["nodes", "m_nodes", "adj", "adjacency_list"]
        )

    def num_children(self):
        if self.nodes_container and self.nodes_container.IsValid():
            return self.nodes_container.GetNumChildren()
        return 0

    def get_child_at_index(self, index):
        if self.nodes_container:
            return self.nodes_container.GetChildAtIndex(index)
        return None

    def get_summary(self):
        num_nodes_member = get_child_member_by_names(
            self.valobj, ["num_nodes", "V", "node_count"]
        )
        num_edges_member = get_child_member_by_names(
            self.valobj, ["num_edges", "E", "edge_count"]
        )

        summary = f"{Colors.MAGENTA}Graph{Colors.RESET}"
        if num_nodes_member:
            summary += f" | V = {num_nodes_member.GetValueAsUnsigned()}"
        if num_edges_member:
            summary += f" | E = {num_edges_member.GetValueAsUnsigned()}"
        return summary


# ----- Function for Graph Nodes ----- #
def GraphNodeSummary(valobj, internal_dict):
    """
    Provides a summary for a single Graph Node, showing its value and neighbors.
    """
    # valobj is the node itself
    debug_print(f"GraphNodeSummary called for '{valobj.GetTypeName()}'")
    node_value = get_child_member_by_names(valobj, ["value", "val", "data", "key"])
    neighbors = get_child_member_by_names(valobj, ["neighbors", "adj", "edges"])

    val_str = get_value_summary(node_value)
    summary = f"{Colors.YELLOW}{val_str}{Colors.RESET}"

    if neighbors and neighbors.IsValid() and neighbors.MightHaveChildren():
        neighbor_summaries = []
        max_neighbors = g_graph_max_neighbors
        num_neighbors = neighbors.GetNumChildren()

        debug_print(
            f"-> Node '{val_str}' has {num_neighbors} neighbors. Displaying up to {max_neighbors}."
        )
        for i in range(min(neighbors.GetNumChildren(), max_neighbors)):
            neighbor_node = neighbors.GetChildAtIndex(i)

            # The neighbor might be a pointer to a node, or a node itself
            if neighbor_node.GetType().IsPointerType():
                neighbor_node = neighbor_node.Dereference()

            if neighbor_node and neighbor_node.IsValid():
                neighbor_val = get_child_member_by_names(
                    neighbor_node, ["value", "val", "data", "key"]
                )
                neighbor_summaries.append(get_value_summary(neighbor_val))

        if neighbor_summaries:
            summary += f" -> [{', '.join(neighbor_summaries)}]"
        if neighbors.GetNumChildren() > max_neighbors:
            summary += " ..."

    return summary


# ----- Custom LLDB command 'export_graph' ----- #
def export_graph_command(debugger, command, result, internal_dict):
    """
    Implements the 'export_graph' command. It traverses a graph structure
    and writes a Graphviz .dot file to disk.
    Usage: (lldb) export_graph <variable_name> [output_file.dot]
    """
    debug_print("=" * 20 + " 'export_graph' Command Start " + "=" * 20)

    # 1. Parse arguments
    args = command.split()
    if not args:
        result.SetError("Usage: export_graph <variable_name> [output_file.dot]")
        debug_print("Command failed: No variable name provided.")
        return

    var_name = args[0]
    output_filename = args[1] if len(args) > 1 else "graph.dot"
    debug_print(f"Variable: '{var_name}', Output file: '{output_filename}'")

    # 2. Get the variable from the current frame
    frame = (
        debugger.GetSelectedTarget().GetProcess().GetSelectedThread().GetSelectedFrame()
    )
    if not frame.IsValid():
        result.SetError("Cannot execute 'export_graph': invalid execution context.")
        debug_print("Command failed: Invalid frame.")
        return

    graph_val = frame.FindVariable(var_name)
    if not graph_val or not graph_val.IsValid():
        result.SetError(f"Could not find a variable named '{var_name}'.")
        debug_print(f"Command failed: Variable '{var_name}' not found.")
        return

    # 3. Access the container of nodes within the graph object
    nodes_container = get_child_member_by_names(
        graph_val, ["nodes", "m_nodes", "adj", "adjacency_list"]
    )
    if (
        not nodes_container
        or not nodes_container.IsValid()
        or not nodes_container.MightHaveChildren()
    ):
        result.AppendMessage("Graph is empty or nodes container not found.")
        debug_print("Nodes container not found or is empty.")
        return

    # 4. Traverse the graph and build the .dot file content
    dot_lines = [
        "digraph G {",
        f"  dpi={300};",
        '  rankdir="LR";',
        "  node [shape=circle, style=filled, fillcolor=lightblue];",
    ]
    edge_lines = set()  # Use a set to avoid duplicate edges
    visited_nodes = set()

    num_nodes = nodes_container.GetNumChildren()
    debug_print(f"Found {num_nodes} nodes in the container. Starting traversal...")

    for i in range(num_nodes):
        node = nodes_container.GetChildAtIndex(i)

        # If the container holds pointers, dereference them
        if node.GetType().IsPointerType():
            node = node.Dereference()

        if not node or not node.IsValid():
            continue

        node_addr = get_raw_pointer(node)

        # Define the node if not already seen
        if node_addr not in visited_nodes:
            visited_nodes.add(node_addr)
            node_value = get_child_member_by_names(
                node, ["value", "val", "data", "key"]
            )
            val_summary = get_value_summary(node_value).replace(
                '"', '\\"'
            )  # Escape quotes
            dot_lines.append(f'  Node_{node_addr} [label="{val_summary}"];')
            debug_print(f"  - Defined node Node_{node_addr} with label '{val_summary}'")

        # Find its neighbors and define edges
        neighbors = get_child_member_by_names(node, ["neighbors", "adj", "edges"])
        if neighbors and neighbors.IsValid() and neighbors.MightHaveChildren():
            for j in range(neighbors.GetNumChildren()):
                neighbor = neighbors.GetChildAtIndex(j)

                if neighbor.GetType().IsPointerType():
                    neighbor = neighbor.Dereference()

                if not neighbor or not neighbor.IsValid():
                    continue

                neighbor_addr = get_raw_pointer(neighbor)
                edge_str = f"  Node_{node_addr} -> Node_{neighbor_addr};"

                if edge_str not in edge_lines:
                    edge_lines.add(edge_str)
                    debug_print(
                        f"    - Found edge: Node_{node_addr} -> Node_{neighbor_addr}"
                    )

    dot_lines.extend(list(edge_lines))
    dot_lines.append("}")
    dot_content = "\n".join(dot_lines)

    # 5. Write the content to the output file
    try:
        with open(output_filename, "w") as f:
            f.write(dot_content)
        result.AppendMessage(f"Successfully exported graph to '{output_filename}'.")
        result.AppendMessage(
            f"Run this command to generate the image: {Colors.BOLD_CYAN}dot -Tpng {output_filename} -o graph.png{Colors.RESET}"
        )
    except IOError as e:
        result.SetError(f"Failed to write to file '{output_filename}': {e}")
        debug_print(f"File I/O Error: {e}")

    debug_print("=" * 20 + " 'export_graph' Command End " + "=" * 20)
