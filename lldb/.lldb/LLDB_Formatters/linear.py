from .helpers import (
    Colors,
    get_child_member_by_names,
    get_raw_pointer,
    type_has_field,
    get_value_summary,
    debug_print,
    g_summary_max_items,
)

# ----- Formatter for Linear Data Structures (Lists, Stacks, Queues) ----- #
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
        """
        self.head_ptr = get_child_member_by_names(
            self.valobj, ["head", "m_head", "_head", "top"]
        )
        debug_print(
            f"Searching for head... Found: {'Yes' if self.head_ptr and self.head_ptr.IsValid() else 'No'}"
        )

        if self.head_ptr and get_raw_pointer(self.head_ptr) != 0:
            node_obj = self.head_ptr.Dereference()
            debug_print(f"Head pointer is valid. Dereferencing to get node object.")

            if node_obj and node_obj.IsValid():
                node_type = node_obj.GetType()

                for name in ["next", "m_next", "_next", "pNext"]:
                    if type_has_field(node_type, name):
                        self.next_ptr_name = name
                        break
                for name in ["value", "val", "data", "m_data", "key"]:
                    if type_has_field(node_type, name):
                        self.value_name = name
                        break
                debug_print(f"-> Found 'next' member: '{self.next_ptr_name}'")
                debug_print(f"-> Found 'value' member: '{self.value_name}'")
            else:
                debug_print("-> Failed to dereference head pointer.")

        size_member = get_child_member_by_names(
            self.valobj, ["size", "m_size", "_size", "count"]
        )
        if size_member:
            self.size = size_member.GetValueAsUnsigned()
        debug_print(
            f"Found size member: {'Yes' if size_member else 'No'}. Size is {self.size}"
        )

    def get_summary(self):
        self.update()

        if not self.head_ptr:
            return "Could not find head pointer"

        if get_raw_pointer(self.head_ptr) == 0:
            return f"{Colors.GREEN}size={self.size}{Colors.RESET}, []"

        if not self.next_ptr_name or not self.value_name:
            debug_print(
                "Bailing out: could not determine node structure (val/next names not found)."
            )
            return "Cannot determine node structure (val/next)"

        summary = []
        node = self.head_ptr
        count = 0
        max_items = g_summary_max_items
        visited = set()

        while get_raw_pointer(node) != 0 and count < max_items:
            debug_print(
                f"Loop iter {count+1}: node type='{node.GetTypeName()}', addr='{get_raw_pointer(node):#x}'"
            )

            node_addr = get_raw_pointer(node)
            if node_addr in visited:
                summary.append(f"{Colors.RED}[CYCLE DETECTED]{Colors.RESET}")
                break
            visited.add(node_addr)

            dereferenced_node = node.Dereference()
            if not dereferenced_node or not dereferenced_node.IsValid():
                debug_print("-> Node could not be dereferenced. Breaking loop.")
                break

            value_child = dereferenced_node.GetChildMemberWithName(self.value_name)
            current_val_str = get_value_summary(value_child)
            debug_print(f"-> Extracted value string: '{current_val_str}'")

            summary.append(f"{Colors.YELLOW}{current_val_str}{Colors.RESET}")

            node = dereferenced_node.GetChildMemberWithName(self.next_ptr_name)
            count += 1

        final_summary_str = f" {Colors.BOLD_CYAN}->{Colors.RESET} ".join(summary)

        if get_raw_pointer(node) != 0:
            final_summary_str += f" {Colors.BOLD_CYAN}->{Colors.RESET} ..."

        return f"{Colors.GREEN}size = {self.size}{Colors.RESET}, [{final_summary_str}]"


def LinearContainerSummary(valobj, internal_dict):
    """
    This function is registered with LLDB for Linear Structures.
    """
    provider = LinearContainerProvider(valobj, internal_dict)
    return provider.get_summary()