# ---------------------------------------------------------------------- #
# FILE: linear.py
#
# DESCRIPTION:
# This module provides data formatters for linear, pointer-based data
# structures such as singly-linked lists, stacks, and queues.
#
# The 'LinearContainerProvider' class generates a concise one-line
# summary by traversing the structure through 'next' pointers. It is
# designed to be adaptive to common member names (e.g., 'head', 'next',
# 'value') and includes cycle detection to prevent infinite loops.
# ---------------------------------------------------------------------- #

from .helpers import (
    Colors,
    get_raw_pointer,
    get_value_summary,
    g_summary_max_items,
    get_child_member_by_names,
    type_has_field,
    debug_print,
    should_use_colors,
)

# Import the web visualizer function for side effects
# This will be used to generate an interactive HTML visualizer in the IDE.
from .web_visualizer import generate_list_visualization_html


# ---- Formatter for Linear Data Structures (Lists, Stacks, Queues) ---- #
class LinearContainerProvider:
    """
    Provides a summary for linear structures that follow a 'next' pointer.
    E.g., List, Queue (list-based), Stack (list-based).
    """

    def __init__(self, valobj, internal_dict):
        self.valobj = valobj
        self.head_ptr = None
        self.next_ptr_name = None
        self.value_name = None
        self.size = 0
        debug_print(f"Provider created for object of type '{valobj.GetTypeName()}'")

    def update(self):
        """
        Initializes pointers and member names by searching through common conventions.
        Detects if the list is doubly-linked or singly-linked based on member names.
        """
        self.head_ptr = get_child_member_by_names(
            self.valobj, ["head", "m_head", "_head", "top"]
        )
        self.is_doubly_linked = False
        debug_print(
            f"Searching for head... Found: {'Yes' if self.head_ptr and self.head_ptr.IsValid() else 'No'}"
        )

        if self.head_ptr and get_raw_pointer(self.head_ptr) != 0:
            # Note: We must use Dereference() on the head_ptr to access the node's type info.
            node_obj = self.head_ptr.Dereference()
            debug_print(f"Head pointer is valid. Dereferencing to get node object.")

            if node_obj and node_obj.IsValid():
                node_type = node_obj.GetType()

                # Find member names for 'next', 'value', and 'prev'
                for name in ["next", "m_next", "_next", "pNext"]:
                    if type_has_field(node_type, name):
                        self.next_ptr_name = name
                        break
                for name in ["value", "val", "data", "m_data", "key"]:
                    if type_has_field(node_type, name):
                        self.value_name = name
                        break
                for name in ["prev", "m_prev", "_prev", "pPrev"]:
                    if type_has_field(node_type, name):
                        self.is_doubly_linked = True
                        break

        # Check the size of the list
        size_member = get_child_member_by_names(
            self.valobj, ["count", "size", "m_size", "_size"]
        )
        if size_member:
            self.size = size_member.GetValueAsUnsigned()
        debug_print(
            f"Found size member: {'Yes' if size_member else 'No'}. Size is {self.size}"
        )

    def get_summary(self, use_colors=True):
        """
        This method accepts a 'use_colors' flag to conditionally
        format the output string, making it safe for GUI panels.
        """
        self.update()

        # Conditionally define colors based on the context
        C_GREEN = Colors.GREEN if use_colors else ""
        C_RESET = Colors.RESET if use_colors else ""
        C_YELLOW = Colors.YELLOW if use_colors else ""
        C_BOLD_CYAN = Colors.BOLD_CYAN if use_colors else ""
        C_RED = Colors.RED if use_colors else ""

        size_str = f"size = {self.size}"

        if not self.head_ptr:
            return "Could not find head pointer"

        # Special case for an empty list
        if get_raw_pointer(self.head_ptr) == 0:
            size_str = f"size = {self.size}"
            return f"{C_GREEN}{size_str}{C_RESET}, []"

        if not self.next_ptr_name or not self.value_name:
            return "Cannot determine node structure (val/next)"

        summary = []
        node = self.head_ptr
        count = 0
        max_items = g_summary_max_items
        visited = set()

        # Traverse the list
        while get_raw_pointer(node) != 0 and count < max_items:
            node_addr = get_raw_pointer(node)
            if node_addr in visited:
                summary.append(f"{C_RED}[CYCLE DETECTED]{C_RESET}")
                break
            visited.add(node_addr)

            dereferenced_node = node.Dereference()
            if not dereferenced_node or not dereferenced_node.IsValid():
                break

            value_child = dereferenced_node.GetChildMemberWithName(self.value_name)
            current_val_str = get_value_summary(value_child)
            summary.append(f"{C_YELLOW}{current_val_str}{C_RESET}")

            node = dereferenced_node.GetChildMemberWithName(self.next_ptr_name)
            count += 1

        separator = (
            f" {C_BOLD_CYAN}<->{C_RESET} "
            if self.is_doubly_linked
            else f" {C_BOLD_CYAN}->{C_RESET} "
        )
        final_summary_str = separator.join(summary)

        # Append '...' if the list was truncated
        if get_raw_pointer(node) != 0:
            final_summary_str += f" {separator.strip()} ..."

        return f"{C_GREEN}{size_str}{C_RESET}, [{final_summary_str}]"


def LinearContainerSummary(valobj, internal_dict):
    """
    This function returns a clean, context-aware text summary for Linear Structures.
    The automatic web visualization has been disabled to prevent race conditions
    and ensure stable behavior in the GUI.
    Use the 'weblist' command for manual visualization.
    """

    # ----- Side Effect: DISABLED ----- #
    # Side Effect: Attempt to display the rich visualizer
    # try:
    #     # 'debugger' module is only available when run by CodeLLDB
    #     from debugger import display_html  # type: ignore
    #
    #     # Try to import the visualization function
    #     try:
    #         from .web_visualizer import generate_list_visualization_html
    #
    #         # Generate the HTML by calling the shared helper function
    #         html_content = generate_list_visualization_html(valobj)
    #         if html_content:
    #             # This is the direct command to the VS Code UI
    #             display_html(html_content, title=f"List: {valobj.GetName()}")
    #     except ImportError:
    #         # web_visualizer module not available
    #         pass
    #
    # except ImportError:
    #     # Not running inside CodeLLDB, or the API is unavailable. Do nothing.
    #     pass
    # except Exception as e:
    #     # Silently ignore other errors to avoid crashing the summary provider
    #     debug_print(f"Failed to call web visualizer from list provider: {e}")

    # Main logic: generate the text summary
    use_colors = should_use_colors()
    provider = LinearContainerProvider(valobj, internal_dict)
    summary_str = provider.get_summary(use_colors=use_colors)

    return summary_str
