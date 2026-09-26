//===---------------------------------------------------------------------------===//
/**
 * @file brew_check.c
 * @brief Regression checks for the brew_check event provider.
 *
 * Includes the provider source with its entry point renamed and its
 * SketchyBar sender replaced by a capture buffer, then verifies that:
 *  - a periodic check replaces a stale outdated count,
 *  - a forced check does the same,
 *  - Homebrew diagnostics on stderr never count as outdated packages.
 *
 * Usage: brew-test <fake-brew>
 * The fake brew executable must exit successfully without printing anything.
 */
//===---------------------------------------------------------------------------===//

#include "../sketchybar/helpers/event_providers/sketchybar.h"

/** @brief Last message the provider would have sent to SketchyBar. */
static char sent[4096];

/**
 * @brief Records a message instead of sending it over Mach IPC.
 *
 * @param message The command the provider would send.
 */
static void capture(const char* message) {
  snprintf(sent, sizeof(sent), "%s", message);
}

#define sketchybar capture
#define main provider_main
#include "../sketchybar/helpers/event_providers/brew_check/brew_check.c"
#undef main

int main(int argc, char** argv) {
  if (argc != 2) return 2;

  brew_t brew;
  if (brew_init(&brew) != BREW_SUCCESS) return 2;
  snprintf(BREW_EXECUTABLE_PATH, sizeof(BREW_EXECUTABLE_PATH), "%s", argv[1]);

  // A periodic check must replace the count left over from an earlier run.
  brew.last_update    = time(NULL);
  brew.outdated_count = 7;
  strcpy(brew.package_list, "old-package");
  check_and_notify(&brew, "audit", 3600, false, false);
  printf("periodic_count=%d expected=0 event=%s\n", brew.outdated_count, sent);
  bool stale = brew.outdated_count != 0;

  check_and_notify(&brew, "audit", 3600, true, false);
  printf("forced_count=%d expected=0\n", brew.outdated_count);

  // Only stdout lists packages; the warning on stderr must be ignored.
  const char* args[] = {
      "/bin/sh", "-c",
      "printf 'actual-package\\n'; printf 'Warning: diagnostic only\\n' >&2", NULL};
  char*  output = NULL;
  size_t size   = 0;
  if (_brew_execute_command(args, &output, &size) != BREW_SUCCESS) return 3;
  if (_brew_parse_outdated_output(&brew, output) != BREW_SUCCESS) return 4;
  printf("parsed_count=%d expected=1 packages=%s\n", brew.outdated_count, brew.package_list);
  bool contaminated = brew.outdated_count != 1;

  free(output);
  brew_cleanup(&brew);
  return stale || contaminated ? 1 : 0;
}

//===---------------------------------------------------------------------------===//
