//===---------------------------------------------------------------------------===//
/**
 * @file network_load.c
 * @brief Network interface throughput monitor and event provider for SketchyBar.
 *
 * This program monitors real-time network upload and download throughput for a
 * specified interface and reports the data to SketchyBar via custom events.
 * It continuously samples interface statistics, computes data rates, and triggers
 * bar updates at a configurable frequency.
 *
 * Key features:
 *  - Real-time bandwidth calculation using kernel MIB counters
 *  - Automatic unit scaling (Bps, KBps, MBps)
 *  - Signal-safe termination handling
 *  - Direct Mach IPC communication with SketchyBar
 *
 * Typical usage:
 *  ./network_load "en0" "network_change" "2.0"
 *
 * @note Designed as a long-running event provider daemon for SketchyBar.
 *
 * @author LCS.Dev
 * @date 2025-01-10
 */
//===---------------------------------------------------------------------------===//

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../sketchybar.h"
#include "network.h"

//===-------------------------------- CONSTANTS --------------------------------===//

static const int MAX_MESSAGE_LENGTH = 512;

/**
 * @brief Displays usage instructions for the network_load daemon.
 *
 * @param program_name The name of the executable (argv[0]). If NULL, defaults
 *                     to "network_load".
 */
static void show_usage(const char* program_name) {
  if (!program_name) program_name = "network_load";
  printf("Usage: %s \"<interface>\" \"<event-name>\" \"<event_freq>\"\n", program_name);
}

/**
 * @brief Signal handler for clean daemon termination.
 *
 * Logs the received signal to stderr and exits the process immediately.
 *
 * @param signum The signal number received (e.g., SIGINT, SIGTERM).
 *
 * @note This handler is intentionally simple to remain async-signal-safe.
 *       It does not perform any cleanup; the OS reclaims resources on exit.
 */
static void signal_handler(int signum) {
  fprintf(stderr, "Received signal %d, exiting...\n", signum);
  exit(signum);
}

/**
 * @brief Main entry point for the network_load daemon.
 *
 * Parses command-line arguments, initializes the network interface monitor,
 * registers a SketchyBar custom event, and enters an infinite loop that
 * periodically samples throughput and triggers updates.
 *
 * @param argc Number of command-line arguments.
 * @param argv Argument vector. Expected: argv[1] = interface, argv[2] = event_name,
 *             argv[3] = update_frequency.
 * @return 0 on normal termination (unreachable), or 1 on initialization failure.
 *
 * @note The daemon runs indefinitely until killed. Signal handlers are installed
 *       for SIGINT and SIGTERM to allow clean termination.
 */
int main(int argc, char** argv) {
  float update_freq;

  // Check arguments
  if (argc < 4 || (sscanf(argv[3], "%f", &update_freq) != 1) || update_freq <= 0) {
    show_usage(argv[0]);
    exit(1);
  }

  // Disable alarm signal and set up signal handlers.
  if (alarm(0) == (unsigned int)-1) {
    fprintf(stderr, "Warning: error disabling alarm: %s\n", strerror(errno));
    // Not a critical error, we can continue.
  }

  // Set up signal handling for clean termination.
  struct sigaction sa = {0};
  sa.sa_handler       = signal_handler;
  sigemptyset(&sa.sa_mask);

  if (sigaction(SIGINT, &sa, NULL) < 0 || sigaction(SIGTERM, &sa, NULL) < 0) {
    fprintf(stderr, "Warning: unable to set signal handler: %s\n", strerror(errno));
    // Not a critical error, we can continue.
  }

  // Setup the event in sketchybar.
  char event_message[MAX_MESSAGE_LENGTH];
  int  msg_len = snprintf(event_message, sizeof(event_message), "--add event '%s'", argv[2]);

  if (msg_len < 0 || msg_len >= (int)sizeof(event_message)) {
    fprintf(stderr, "Error formatting event message\n");
    return 1;
  }

  sketchybar(event_message);

  // Initialize the network structure.
  struct network network;
  if (network_init(&network, argv[1]) != 0) {
    fprintf(stderr, "Error: unable to initialize network interface '%s'\n", argv[1]);
    return 1;
  }

  // Buffer for the trigger message.
  char trigger_message[MAX_MESSAGE_LENGTH];

  // Check that the frequency value is within a reasonable range.
  if (update_freq < 0.1 || update_freq > 3600) {
    fprintf(stderr, "Invalid update frequency (%f), using 1 second\n", update_freq);
    update_freq = 1.0;
  }

  unsigned long sleep_microseconds = (unsigned long)(update_freq * 1000000);

  // Main loop.
  for (;;) {
    // Update network information.
    network_update(&network);

    // Prepare the event message.
    int trigger_len = snprintf(
        trigger_message, sizeof(trigger_message),
        "--trigger '%s' upload='%03d%s' download='%03d%s'", argv[2], network.up,
        unit_str[network.up_unit], network.down, unit_str[network.down_unit]);

    if (trigger_len < 0 || trigger_len >= (int)sizeof(trigger_message)) {
      fprintf(stderr, "Error or truncation while formatting trigger message\n");
      // Continue execution anyway.
    }

    // Send the trigger to sketchybar.
    sketchybar(trigger_message);

    // Wait for the next update.
    usleep(sleep_microseconds);
  }

  // Never reached.
  return 0;
}

//===---------------------------------------------------------------------------===//
