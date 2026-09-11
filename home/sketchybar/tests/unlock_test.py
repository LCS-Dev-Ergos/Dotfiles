"""Exercise the upstream wake event handler with reset/refresh boundaries observed."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index("static void event_system_woke(void* context) {")
end = source.index("\nstatic void ", start + 1)
handler = source[start:end]
harness = r"""
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
struct bar_manager { bool sleeps; int bar_count; bool needs_ordering; int animator; };
static struct bar_manager g_bar_manager;
static int resets, refreshes, notifications;
#define COMMAND_SUBSCRIBE_SYSTEM_WOKE "system_woke"
void bar_manager_handle_system_woke(struct bar_manager* b) { resets++; }
void bar_manager_handle_display_change(struct bar_manager* b) {}
void bar_manager_handle_space_change(struct bar_manager* b, bool forced) {}
void bar_manager_refresh(struct bar_manager* b, bool forced) { refreshes++; }
void animator_renew_display_link(int* a) {}
void bar_manager_custom_events_trigger(struct bar_manager* b, const char* e, void* v) {
  notifications++;
}
HANDLER
int main(void) {
  g_bar_manager.bar_count = 1;
  event_system_woke((void*)1);
  assert(resets == 0 && refreshes == 1 && notifications == 1);
  assert(g_bar_manager.needs_ordering);
  event_system_woke(NULL);
  assert(resets == 1);
  g_bar_manager.sleeps = true;
  event_system_woke((void*)1);
  assert(resets == 2);
  g_bar_manager.sleeps = false;
  g_bar_manager.bar_count = 0;
  event_system_woke((void*)1);
  assert(resets == 3);
}
""".replace("HANDLER", handler)
with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "wake.c"
    binary = Path(directory) / "wake"
    test.write_text(harness)
    subprocess.run([os.environ.get("CC", "cc"), str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("native unlock/wake routing: PASS")
