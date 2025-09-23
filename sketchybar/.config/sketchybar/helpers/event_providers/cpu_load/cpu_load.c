#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "../sketchybar.h"
#include "cpu.h"

static const int MAX_EVENT_MESSAGE_LENGTH   = 512;
static const int MAX_TRIGGER_MESSAGE_LENGTH = 512;

/**
 * Shows the usage instructions for the program
 */
static void show_usage(const char* program_name) {
  if (!program_name) program_name = "cpu_load";
  printf("Usage: %s \"<event-name>\" \"<event_freq>\"\n", program_name);
}

int main(int argc, char** argv) {
  float update_freq;

  // Argument check
  if (argc < 3 || (sscanf(argv[2], "%f", &update_freq) != 1) || update_freq <= 0) {
    show_usage(argv[0]);
    return 1;
  }

  // Disable the alarm signal
  if (alarm(0) == (unsigned int)-1) {
    fprintf(stderr, "Error disabling alarm: %s\n", strerror(errno));
    // Not a critical error, we can continue
  }

  // Initialize the CPU structure
  struct cpu cpu;
  cpu_init(&cpu);

  // Setup the event in sketchybar
  char event_message[MAX_EVENT_MESSAGE_LENGTH];
  int  msg_len = snprintf(event_message, sizeof(event_message), "--add event '%s'", argv[1]);

  if (msg_len < 0 || msg_len >= (int)sizeof(event_message)) {
    fprintf(stderr, "Error formatting event message\n");
    return 1;
  }

  sketchybar(event_message);

  // Prepare the buffer for the trigger message
  char trigger_message[MAX_TRIGGER_MESSAGE_LENGTH];

  // Main loop
  while (true) {
    // Update CPU information
    cpu_update(&cpu);

    // Prepare the event message
    int trigger_len = snprintf(
        trigger_message, sizeof(trigger_message),
        "--trigger '%s' user_load='%d' sys_load='%02d' total_load='%02d'", argv[1], cpu.user_load,
        cpu.sys_load, cpu.total_load);

    if (trigger_len < 0 || trigger_len >= (int)sizeof(trigger_message)) {
      fprintf(stderr, "Error or truncation while formatting trigger message\n");
      // Continue execution anyway
    }

    // Send the trigger to sketchybar
    sketchybar(trigger_message);

    // Wait for the next update
    // Check that the value is not too large or negative
    if (update_freq <= 0 || update_freq > 3600) {
      fprintf(stderr, "Invalid update frequency (%f), using 1 second\n", update_freq);
      update_freq = 1.0;
    }

    unsigned long sleep_time = (unsigned long)(update_freq * 1000000);
    usleep(sleep_time);
  }

  // Never reached, but the compiler may warn without return
  return 0;
}
