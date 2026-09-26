"""Build-time check of the display reconciliation patch for SketchyBar.

The package's check phase runs this script against the patched ``src``
directory. It extracts the patched event handlers, compiles them together with
``display_layout.h`` against counting stubs, and replays the display sequence
recorded while two external displays woke from sleep.

Usage: ``python3 display_reconcile_test.py <sketchybar-src>``
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HARNESS = r"""
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include "display_layout.h"

// Counting stubs for the bar manager functions the extracted handlers call.
struct bar_manager { int unused; };
static struct bar_manager g_bar_manager;
static int wakes, unlocks, rebuilds, scheduled;
#define DISPLAY_RECONCILE_QUIET_NS 1
void bar_manager_handle_system_woke(struct bar_manager* b) { wakes++; }
void bar_manager_handle_screen_unlocked(struct bar_manager* b) { unlocks++; }
void bar_manager_display_changed(struct bar_manager* b) { rebuilds++; }
void bar_manager_schedule_display_reconcile(struct bar_manager* b, uint64_t delay) {
  scheduled++;
}

@WOKE@
@DISPLAY_EVENTS@

// Builds a layout from parallel arrays of display ids and bounds.
static struct display_layout layout(uint32_t count, const uint32_t* did,
                                    const CGRect* bounds) {
  struct display_layout result = { .count = count };
  for (uint32_t i = 0; i < count; i++) {
    result.did[i] = did[i];
    result.bounds[i] = bounds[i];
  }
  return result;
}

int main(void) {
  // An unlock carries a context pointer; a system wake does not.
  event_system_woke((void*)1);
  event_system_woke(NULL);
  assert(unlocks == 1 && wakes == 1);

  // Display callbacks only schedule a reconcile; none rebuilds directly.
  bar_manager_display_added(&g_bar_manager, 2);
  bar_manager_display_removed(&g_bar_manager, 2);
  bar_manager_display_moved(&g_bar_manager, 2);
  bar_manager_display_resized(&g_bar_manager, 2);
  assert(scheduled == 4 && rebuilds == 0);

  const uint32_t desk_did[] = { 3, 2 };
  const CGRect desk_bounds[] = { { { 0, 0 }, { 3008, 1692 } },
                                 { { 3008, -785 }, { 1692, 3008 } } };
  const uint32_t placeholder_did[] = { 5 };
  const CGRect placeholder_bounds[] = { { { 0, 0 }, { 1920, 1080 } } };
  const CGRect reprobing_bounds[] = { CGRectZero, CGRectZero };

  struct display_layout built = layout(2, desk_did, desk_bounds);
  struct display_layout same = layout(2, desk_did, desk_bounds);
  struct display_layout empty = { 0 };
  struct display_layout reprobing = layout(2, desk_did, reprobing_bounds);
  struct display_layout placeholder = layout(1, placeholder_did, placeholder_bounds);

  // The observed wake: no displays, unsized displays, a placeholder, then the
  // original desk. Nothing is rebuilt and the desk is refreshed once.
  assert(display_reconcile_decide(&built, &empty, true, true, false)
         == DISPLAY_RECONCILE_WAIT);
  assert(display_reconcile_decide(&built, &reprobing, true, true, false)
         == DISPLAY_RECONCILE_WAIT);
  assert(display_reconcile_decide(&built, &placeholder, true, true, false)
         == DISPLAY_RECONCILE_WAIT);
  assert(display_reconcile_decide(&built, &same, true, true, false)
         == DISPLAY_RECONCILE_REFRESH);

  // Behind the lock screen the unchanged desk waits for the unlock refresh.
  assert(display_reconcile_decide(&built, &same, true, true, true)
         == DISPLAY_RECONCILE_KEEP);
  assert(display_reconcile_decide(&built, &placeholder, true, false, true)
         == DISPLAY_RECONCILE_REBUILD);

  // Outside the settle period a different layout is rebuilt at once.
  assert(display_reconcile_decide(&built, &same, true, false, false)
         == DISPLAY_RECONCILE_REFRESH);
  assert(display_reconcile_decide(&built, &placeholder, true, false, false)
         == DISPLAY_RECONCILE_REBUILD);
  assert(display_reconcile_decide(&built, &same, false, true, false)
         == DISPLAY_RECONCILE_REBUILD);
  assert(display_reconcile_decide(&built, &empty, false, false, false)
         == DISPLAY_RECONCILE_WAIT);

  struct display_layout moved = same;
  moved.bounds[1].origin.y = 0;
  assert(display_reconcile_decide(&built, &moved, true, false, false)
         == DISPLAY_RECONCILE_REBUILD);
  return 0;
}
"""


def extract(source: str, start: str, end: str) -> str:
    """Return the text of ``source`` from ``start`` up to the next ``end``."""
    begin = source.index(start)
    return source[begin : source.index(end, begin + 1)]


def main() -> None:
    """Compile the harness against the patched sources and run it."""
    src = Path(sys.argv[1])
    event_c = (src / "event.c").read_text()
    bar_manager_c = (src / "bar_manager.c").read_text()

    woke = extract(
        event_c,
        "static void event_system_woke(void* context) {",
        "\nstatic void event_display_reconcile",
    )
    display_events = extract(
        bar_manager_c,
        "void bar_manager_display_resized(",
        "\n// Runs after the notification burst",
    )
    harness = HARNESS.replace("@WOKE@", woke).replace(
        "@DISPLAY_EVENTS@", display_events
    )

    with tempfile.TemporaryDirectory() as directory:
        test = Path(directory) / "reconcile.c"
        binary = Path(directory) / "reconcile"
        test.write_text(harness)
        compiler = os.environ.get("CC", "cc")
        subprocess.run(
            [
                compiler,
                "-I",
                str(src),
                str(test),
                "-framework",
                "CoreGraphics",
                "-o",
                str(binary),
            ],
            check=True,
        )
        subprocess.run([str(binary)], check=True)
    print("native wake/unlock/display reconciliation: PASS")


if __name__ == "__main__":
    main()
