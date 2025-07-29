from .helpers import (
    get_child_member_by_names,
    get_raw_pointer,
    get_value_summary,
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


# ----- HTML Template for Advanced Web Visualizer ----- #
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Interactive Tree Visualizer</title>
    <style type="text/css">
        html, body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            width: 100%;
            height: 100%;
            padding: 0;
            margin: 0;
            background: linear-gradient(135deg, #f4ecd8 0%, #e8dcc0 100%); /* More elegant sepia gradient */
        }}
        #mynetwork {{
            width: 100%;
            height: 100%;
            position: absolute;
            top: 0;
            left: 0;
            z-index: 1;
        }}
        #info-box {{
            position: absolute;
            top: 20px;
            right: 20px;
            background: linear-gradient(135deg, rgba(255, 255, 255, 0.95) 0%, rgba(248, 240, 225, 0.95) 100%);
            border: 1px solid #d4a574;
            border-radius: 12px;
            padding: 18px;
            z-index: 2;
            box-shadow: 0 6px 20px rgba(139, 126, 110, 0.3);
            font-size: 14px;
            backdrop-filter: blur(5px);
        }}
        #info-box h3 {{
            margin-top: 0;
            font-size: 18px;
            color: #5e5146;
            text-shadow: 0 1px 2px rgba(255, 255, 255, 0.8);
        }}
        #info-box table {{
            width: 100%;
            border-collapse: collapse;
        }}
        #info-box th, #info-box td {{
            text-align: left;
            padding: 8px;
            border-bottom: 1px solid #d4a574;
        }}
        #info-box th {{
            font-weight: bold;
            color: #6b5d52;
        }}
        #info-box td {{
            color: #5e5146;
        }}
    </style>
    <script type="text/javascript">
        // The embedded vis.js library content goes here
        {visjs_library}
    </script>
</head>
<body>

<div id="info-box">
{type_info_html}
</div>
<div id="mynetwork"></div>

<script type="text/javascript">
    // --- Data from Python ---
    const nodesData = {nodes_data};
    const edgesData = {edges_data};
    const traversalOrder = {traversal_order_data}; // Keep this for animations

    // --- Uniform sepia color palette ---
    const colorPalette = {{
        // Base colors
        nodeDefault: '#a67c52',        // Main sepia brown
        nodeBorder: '#8b6f47',         // Darker border
        nodeHover: '#c49771',          // Lighter sepia for hover
        nodeHoverBorder: '#a67c52',    // Hover border
        nodeSelected: '#d4a574',       // Selection - sepia gold
        nodeSelectedBorder: '#b8956a', // Selection border
        
        // Edge colors
        edgeDefault: '#8b6f47',        // Same as node border
        edgeHover: '#a67c52',          // Slightly lighter
        edgeSelected: '#d4a574',       // Same as node selection
        
        // Text colors
        textDefault: '#ffffff',        // White for contrast
        textShadow: 'rgba(0,0,0,0.3)'  // Text shadow
    }};

    // --- Vis.js network configuration ---
    const container = document.getElementById('mynetwork');
    const nodes = new vis.DataSet(nodesData);
    const edges = new vis.DataSet(edgesData);
    const data = {{ nodes: nodes, edges: edges }};

    // --- Style and layout options (Hierarchical) ---
    const options = {{
        layout: {{
            hierarchical: {{
                enabled: true,
                sortMethod: 'directed',
                direction: 'UD',
                nodeSpacing: 150,
                levelSeparation: 170,
            }}
        }},
        interaction: {{ 
                dragNodes: true, 
                zoomView: true, 
                dragView: true,
                hover: true,
                hoverConnectedEdges: true,
                selectConnectedEdges: false
        }},
        physics: {{ enabled: false }},
        nodes: {{
            shape: 'box',
            shapeProperties: {{ 
                borderRadius: 12,
                useBorderWithImage: false
            }},
            font: {{ 
                size: 22, 
                color: colorPalette.textDefault,
                multi: 'html',
                strokeWidth: 2,
                strokeColor: colorPalette.textShadow
            }},
            borderWidth: 3,
            size: 50,
            margin: 12,
            color: {{
                background: colorPalette.nodeDefault,
                border: colorPalette.nodeBorder,
                highlight: {{
                    background: colorPalette.nodeHover,
                    border: colorPalette.nodeHoverBorder
                }},
                hover: {{
                    background: colorPalette.nodeHover,
                    border: colorPalette.nodeHoverBorder
                }}
            }},
            shadow: {{
                enabled: true,
                color: 'rgba(139, 111, 71, 0.4)', // Sepia shadow
                size: 18,
                x: 6,
                y: 6
            }},
            scaling: {{
                min: 10,
                max: 50
            }}
        }},
        edges: {{
            arrows: {{
                to: {{
                    enabled: true,
                    scaleFactor: 1.2,
                    type: 'arrow'
                }}
            }},
            width: 3,
            color: {{ 
                color: colorPalette.edgeDefault,
                highlight: colorPalette.edgeHover,
                hover: colorPalette.edgeHover,
                inherit: false,
                opacity: 0.8
            }},
            smooth: {{
                enabled: true,
                type: 'cubicBezier',
                forceDirection: 'vertical',
                roundness: 0.4
            }},
            shadow: {{
                enabled: true,
                color: 'rgba(139, 111, 71, 0.2)',
                size: 10,
                x: 3,
                y: 3
            }}
        }}
    }};

    const network = new vis.Network(container, data, options);

    // --- Function to reset colors ---
    function resetColors() {{
        nodes.getIds().forEach(nodeId => {{
            nodes.update({{
                id: nodeId, 
                color: {{
                    background: colorPalette.nodeDefault, 
                    border: colorPalette.nodeBorder
                }}
            }});
        }});
        edges.getIds().forEach(edgeId => {{
            edges.update({{
                id: edgeId, 
                color: {{
                    color: colorPalette.edgeDefault
                }}
            }});
        }});
    }}

    // --- Interaction: Highlight connected nodes on click ---
    network.on("click", function (params) {{
        resetColors();

        if (params.nodes.length > 0) {{
            const selectedNodeId = params.nodes[0];
            
            // Highlight the selected node
            nodes.update({{
                id: selectedNodeId, 
                color: {{
                    background: colorPalette.nodeSelected, 
                    border: colorPalette.nodeSelectedBorder
                }}
            }});

            // Highlight connected edges and nodes
            const connectedEdges = network.getConnectedEdges(selectedNodeId);
            connectedEdges.forEach(function (edgeId) {{
                const edge = edges.get(edgeId);
                const connectedNodeId = (edge.from === selectedNodeId) ? edge.to : edge.from;
                
                edges.update({{
                    id: edgeId, 
                    color: {{
                        color: colorPalette.edgeSelected
                    }}
                }});
                nodes.update({{
                    id: connectedNodeId, 
                    color: {{
                        background: colorPalette.nodeSelected, 
                        border: colorPalette.nodeSelectedBorder
                    }}
                }});
            }});
        }}
    }});

    // --- Smoother hover effect ---
    network.on("hoverNode", function (params) {{
        document.body.style.cursor = 'pointer';
    }});

    network.on("blurNode", function (params) {{
        document.body.style.cursor = 'default';
    }});

    // --- Click on empty area to deselect ---
    network.on("click", function (params) {{
        if (params.nodes.length === 0 && params.edges.length === 0) {{
            resetColors();
        }}
    }});

</script>

</body>
</html>
"""


def export_tree_web_command(debugger, command, result, internal_dict):
    """
    Implements the 'export_tree_web' command. It generates a self-contained
    interactive HTML file with styling and traversal animation capabilities.
    Usage: (lldb) export_tree_web <variable_name>
    """
    args = shlex.split(command)
    if not args:
        result.SetError("Usage: export_tree_web <variable_name>")
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

    # Load the vis.js library content dynamically
    visjs_library_content = _load_visjs_library()
    if visjs_library_content.startswith("//"):
        # If the library failed to load, report the error and stop.
        result.SetError(
            f"Could not load the vis.js library. Error: {visjs_library_content}"
        )
        return

    # 1. Build the node/edge data AND the traversal order list
    nodes_data = []
    edges_data = []
    visited_addrs = set()
    _build_visjs_data(root_node_ptr, nodes_data, edges_data, visited_addrs)

    # Collect nodes in pre-order for animation
    preorder_nodes = []
    _collect_nodes_preorder(root_node_ptr, preorder_nodes)
    # Get just the addresses (IDs) for JavaScript
    traversal_order_ids = [get_raw_pointer(node) for node in preorder_nodes]

    # 2. Gather type information for the info box
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

    # 3. Populate the HTML template
    final_html = HTML_TEMPLATE.format(
        visjs_library=visjs_library_content,
        nodes_data=json.dumps(nodes_data),
        edges_data=json.dumps(edges_data),
        traversal_order_data=json.dumps(traversal_order_ids),
        type_info_html=type_info_html,
    )

    # 4. Write to a temporary HTML file and open it
    try:
        with tempfile.NamedTemporaryFile(
            "w", delete=False, suffix=".html", encoding="utf-8"
        ) as f:
            f.write(final_html)
            output_filename = f.name

        webbrowser.open(f"file://{os.path.realpath(output_filename)}")
        result.AppendMessage(
            f"Successfully exported animated tree to '{output_filename}'. Opening in browser..."
        )
    except Exception as e:
        result.SetError(f"Failed to create or open the HTML file: {e}")


def _load_visjs_library():
    """
    Loads the content of the vis-network.min.js library from a file.
    This makes the script self-contained and avoids hardcoding the library.
    """
    try:
        # Get the directory where the current script is located
        script_dir = os.path.dirname(os.path.abspath(__file__))
        visjs_path = os.path.join(script_dir, "vis-network.min.js")

        with open(visjs_path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        # Return a specific error message if the file is missing
        return "// VIS.JS LIBRARY NOT FOUND"
    except Exception as e:
        # Return a generic error message for other potential issues
        return f"// FAILED TO LOAD VIS.JS: {e}"


# ----- Helper to build JSON for vis.js ----- #
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

    # Add the current node to the nodes list
    value = get_child_member_by_names(node_struct, ["value", "val", "data", "key"])
    val_summary = get_value_summary(value)
    nodes_list.append({"id": node_addr, "label": val_summary})

    # Get children and create edges
    children = _get_node_children(node_struct)
    for child_ptr in children:
        child_addr = get_raw_pointer(child_ptr)
        if child_addr != 0:
            # Add the edge
            edges_list.append({"from": node_addr, "to": child_addr})
            # Recurse on the child
            _build_visjs_data(child_ptr, nodes_list, edges_list, visited_addrs)


# ----- HTML Template for Graph Visualizer (Physics-based) -----
GRAPH_HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
  <title>Interactive Graph Visualizer</title>
  <style type="text/css">
    html, body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      width: 100%;
      height: 100%;
      padding: 0;
      margin: 0;
      background-color: #f0f0f0;
    }}
    #mynetwork {{
      width: 100%;
      height: 100%;
      border: 1px solid lightgray;
    }}
  </style>
  <script type="text/javascript">
    // The embedded vis.js library content goes here
    {visjs_library}
  </script>
</head>
<body>

<div id="mynetwork"></div>

<script type="text/javascript">
  // --- Data from Python ---
  const nodesData = {nodes_data};
  const edgesData = {edges_data};

  // --- Vis.js Network Setup ---
  const container = document.getElementById('mynetwork');
  const nodes = new vis.DataSet(nodesData);
  const edges = new vis.DataSet(edgesData);
  const data = {{ nodes: nodes, edges: edges }};

  // --- Styling and Layout Options (Physics-based) ---
  const options = {{
    nodes: {{
      shape: 'dot',
      size: 25,
      font: {{ size: 18, color: '#333' }},
      borderWidth: 2,
      shadow: true
    }},
    edges: {{
      width: 2,
      shadow: true,
      arrows: 'to'
    }},
    physics: {{
      enabled: true,
      barnesHut: {{
        gravitationalConstant: -40000,
        centralGravity: 0.2,
        springLength: 150,
        springConstant: 0.05,
        damping: 0.09,
        avoidOverlap: 0.1
      }},
      solver: 'barnesHut',
      stabilization: {{ iterations: 2000 }}
    }},
    interaction: {{
      dragNodes: true,
      dragView: true,
      zoomView: true,
      tooltipDelay: 200
    }}
  }};

  const network = new vis.Network(container, data, options);

</script>

</body>
</html>
"""


# ----- Web Command for Graphs ----- #
def export_graph_web_command(debugger, command, result, internal_dict):
    """
    Implements the 'webgraph' command. It traverses a graph and generates
    an interactive, physics-based HTML visualization.
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

    # 1. Traverse the graph to collect nodes and edges
    nodes_data = []
    edges_data = []
    visited_nodes = set()

    for i in range(nodes_container.GetNumChildren()):
        node = nodes_container.GetChildAtIndex(i)
        if node.GetType().IsPointerType():
            node = node.Dereference()
        if not node or not node.IsValid():
            continue

        node_addr = get_raw_pointer(node)
        if node_addr not in visited_nodes:
            visited_nodes.add(node_addr)
            node_value = get_child_member_by_names(
                node, ["value", "val", "data", "key"]
            )
            val_summary = get_value_summary(node_value)
            nodes_data.append({"id": node_addr, "label": val_summary})

        neighbors = get_child_member_by_names(node, ["neighbors", "adj", "edges"])
        if neighbors and neighbors.IsValid() and neighbors.MightHaveChildren():
            for j in range(neighbors.GetNumChildren()):
                neighbor = neighbors.GetChildAtIndex(j)
                if neighbor.GetType().IsPointerType():
                    neighbor = neighbor.Dereference()
                if not neighbor or not neighbor.IsValid():
                    continue

                neighbor_addr = get_raw_pointer(neighbor)
                edges_data.append({"from": node_addr, "to": neighbor_addr})

    # 2. Load the library and populate the HTML template
    visjs_library_content = _load_visjs_library()
    if visjs_library_content.startswith("//"):
        result.SetError(f"Could not load vis.js library: {visjs_library_content}")
        return

    final_html = GRAPH_HTML_TEMPLATE.format(
        visjs_library=visjs_library_content,
        nodes_data=json.dumps(nodes_data),
        edges_data=json.dumps(edges_data),
    )

    # 3. Write to a temporary file and open it
    try:
        with tempfile.NamedTemporaryFile(
            "w", delete=False, suffix=".html", encoding="utf-8"
        ) as f:
            f.write(final_html)
            output_filename = f.name
        webbrowser.open(f"file://{os.path.realpath(output_filename)}")
        result.AppendMessage(
            f"Successfully exported graph to '{output_filename}'. Opening in browser..."
        )
    except Exception as e:
        result.SetError(f"Failed to create or open HTML file: {e}")
