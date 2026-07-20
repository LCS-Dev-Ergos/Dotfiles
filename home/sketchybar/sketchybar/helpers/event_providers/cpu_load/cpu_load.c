//===---------------------------------------------------------------------------===//
/**
 * @file cpu_load.c
 * @brief CPU utilization monitor and event provider for SketchyBar.
 *
 * This program monitors real-time CPU load statistics (user, system, and total)
 * and reports the data to SketchyBar via custom events. It continuously samples
 * host CPU tick counters, computes load percentages, and triggers bar updates
 * at a configurable frequency.
 *
 * Key features:
 *  - Real-time CPU load calculation using Mach kernel statistics
 *  - Differentiation between user and system load
 *  - Signal-safe termination handling
 *  - Direct Mach IPC communication with SketchyBar
 *
 * Typical usage:
 *  ./cpu_load "cpu_change" "2.0"
 *
 * @note Designed as a long-running event provider daemon for SketchyBar.
 *
 * @author LCS.Dev
 * @date 2025-01-10
 */
 //===---------------------------------------------------------------------------===//

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../sketchybar.h"
#include "cpu.h"

//===-------------------------------- CONSTANTS --------------------------------===//

static const int MAX_EVENT_MESSAGE_LENGTH   = 512;
static const int MAX_TRIGGER_MESSAGE_LENGTH = 512;

/**
 * @brief Displays usage instructions for the cpu_load daemon.
 *
 * @param program_name The name of the executable (argv[0]). If NULL, defaults
 *                     to "cpu_load".
 */
static void show_usage(const char* program_name) {
  if (!program_name) program_name = "cpu_load";
  printf("Usage: %s \"<event-name>\" \"<event_freq>\"\n", program_name);
}

/**
 * @brief Main entry point for the cpu_load daemon.
 *
 * Parses command-line arguments, initializes the CPU monitor, registers a
 * SketchyBar custom event, and enters an infinite loop that periodically
 * samples CPU load and triggers updates.
 *
 * @param argc Number of command-line arguments.
 * @param argv Argument vector. Expected: argv[1] = event_name, argv[2] = frequency.
 * @return 0 on normal termination (unreachable), or 1 on initialization failure.
 *
 * @note The daemon runs indefinitely until killed. The alarm signal is disabled
 *       to prevent unexpected interruptions.
 */
int main(int argc, char** argv) {
  float update_freq;

  // Argument check.
  if (argc < 3 || (sscanf(argv[2], "%f", &update_freq) != 1) || update_freq <= 0) {
    show_usage(argv[0]);
    return 1;
  }

  // Disable the alarm signal.
  if (alarm(0) == (unsigned int)-1) {
    fprintf(stderr, "Error disabling alarm: %s\n", strerror(errno));
    // Not a critical error, we can continue.
  }

  // Initialize the CPU structure.
  struct cpu cpu;
  cpu_init(&cpu);

  // Setup the event in sketchybar.
  char event_message[MAX_EVENT_MESSAGE_LENGTH];
  int  msg_len = snprintf(event_message, sizeof(event_message), "--add event '%s'", argv[1]);

  if (msg_len < 0 || msg_len >= (int)sizeof(event_message)) {
    fprintf(stderr, "Error formatting event message\n");
    return 1;
  }

  sketchybar(event_message);

  // Prepare the buffer for the trigger message.
  char trigger_message[MAX_TRIGGER_MESSAGE_LENGTH];

  // Main loop.
  while (true) {
    // Update CPU information.
    cpu_update(&cpu);

    // Prepare the event message.
    int trigger_len = snprintf(
        trigger_message, sizeof(trigger_message),
        "--trigger '%s' user_load='%d' sys_load='%02d' total_load='%02d'", argv[1], cpu.user_load,
        cpu.sys_load, cpu.total_load);

    if (trigger_len < 0 || trigger_len >= (int)sizeof(trigger_message)) {
      fprintf(stderr, "Error or truncation while formatting trigger message\n");
      // Continue execution anyway.
    }

    // Send the trigger to sketchybar.
    sketchybar(trigger_message);

    // Wait for the next update.
    // Check that the value is not too large or negative.
    if (update_freq <= 0 || update_freq > 3600) {
      fprintf(stderr, "Invalid update frequency (%f), using 1 second\n", update_freq);
      update_freq = 1.0;
    }

    struct timespec req;
    req.tv_sec  = (time_t)update_freq;
    req.tv_nsec = (long)((update_freq - req.tv_sec) * 1e9);
    nanosleep(&req, NULL);
  }

  // Never reached, but the compiler may warn without return.
  return 0;
}

//===---------------------------------------------------------------------------===//
