/**
 * @file brew_check.c
 * @brief Homebrew package update checker and event provider for SketchyBar.
 *
 * @note This program monitors Homebrew for available package updates and
 *       sends notifications to SketchyBar when updates are detected.
 *       It acts as an event provider that can trigger bar item updates.
 *
 * @author LCS.Dev
 * @date 2025-01-10
 */
//===--------------------------------------------------------------------------===//

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <time.h>

#include "../sketchybar.h"
#include "brew.h"

//===------------------------------- Constants --------------------------------===//

#define DEFAULT_UPDATE_INTERVAL 900
#define DEFAULT_CHECK_INTERVAL 60
#define MAX_EVENT_NAME_LENGTH 64
#define MAX_MESSAGE_LENGTH 2048

//===------------------------------ Global State ------------------------------===//

/** @brief Flag to gracefully terminate the daemon, set by a signal handler. Must be volatile
 * sig_atomic_t. */
static volatile sig_atomic_t g_terminate_flag = 0;
/** @brief Flag to force an immediate check, set by a signal handler. Must be volatile sig_atomic_t.
 */
static volatile sig_atomic_t g_force_check_flag = 0;

//===-------------------------- Forward Declarations --------------------------===//

static void handle_signal(int sig);
static void check_and_notify(brew_t* brew, const char* event_name, bool force_update, bool verbose);
static void show_usage(const char* program_name);
static void log_message(bool verbose, const char* format, ...);

/**
 * @brief Main entry point for the brew_check daemon.
 */
int main(int argc, char** argv) {
  // Argument Parsing.
  if (argc < 3) {
    show_usage(argv[0]);
    return 1;
  }

  char event_name[MAX_EVENT_NAME_LENGTH] = {0};
  strncpy(event_name, argv[1], sizeof(event_name) - 1);

  // Parse check interval with proper error handling.
  errno                     = 0;
  char* endptr              = NULL;
  long  check_interval_secs = strtol(argv[2], &endptr, 10);
  if (errno != 0 || endptr == argv[2] || *endptr != '\0' || check_interval_secs <= 0
      || check_interval_secs > INT_MAX) {
    check_interval_secs = DEFAULT_CHECK_INTERVAL;
  }

  // Parse update interval with proper error handling.
  long update_interval_secs = DEFAULT_UPDATE_INTERVAL;
  if (argc > 3) {
    errno                = 0;
    endptr               = NULL;
    update_interval_secs = strtol(argv[3], &endptr, 10);
    if (errno != 0 || endptr == argv[3] || *endptr != '\0' || update_interval_secs <= 0
        || update_interval_secs > INT_MAX) {
      update_interval_secs = DEFAULT_UPDATE_INTERVAL;
    }
  }

  // This variable is now used by the log_message function.
  bool verbose_mode = (argc > 4 && strcmp(argv[4], "--verbose") == 0);

  // Signal Handling Setup.
  struct sigaction sa = {0};
  sa.sa_handler       = handle_signal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;  // Restart syscalls if possible.
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGUSR1, &sa, NULL);

  // Initialization.
  brew_t       brew_state;
  brew_error_t err = brew_init(&brew_state);
  if (err != BREW_SUCCESS) {
    // Fatal errors are always logged.
    log_message(true, "Initialization failed: %s", brew_error_string(err));
    return 1;
  }

  // Register the custom event with Sketchybar.
  char sketchybar_cmd[256];
  snprintf(sketchybar_cmd, sizeof(sketchybar_cmd), "--add event %s", event_name);
  sketchybar(sketchybar_cmd);
  log_message(verbose_mode, "Daemon started. Event '%s' registered.", event_name);

  // Main Loop.
  // The first check is triggered immediately to populate the bar on startup.
  g_force_check_flag = 1;

  while (!g_terminate_flag) {
    if (g_force_check_flag) {
      g_force_check_flag = 0;
      check_and_notify(&brew_state, event_name, true, verbose_mode);
    } else {
      check_and_notify(&brew_state, event_name, false, verbose_mode);
    }

    // Sleep in chunks to remain responsive to signals.
    // Check for overflow before multiplication.
    long sleep_iterations =
        (check_interval_secs <= LONG_MAX / 2) ? check_interval_secs * 2 : LONG_MAX;
    for (long i = 0; i < sleep_iterations; ++i) {
      if (g_terminate_flag || g_force_check_flag) break;
      usleep(500000);  // Sleep for 0.5 seconds
    }
  }

  // Cleanup.
  brew_cleanup(&brew_state);
  log_message(verbose_mode, "Terminating gracefully.");
  return 0;
}

//===------------------------ Function Implementations ------------------------===//

/**
 * @brief Performs the brew check and sends a trigger to Sketchybar.
 *
 * @param brew The brew state structure.
 * @param event_name The name of the custom event to trigger.
 * @param force_update If true, ignores the time interval and system load checks.
 * @param verbose If true, enables detailed logging for this operation.
 */
static void check_and_notify(
    brew_t* brew, const char* event_name, bool force_update, bool verbose) {
  if (force_update || brew_needs_update(brew, DEFAULT_UPDATE_INTERVAL)) {
    log_message(verbose, "Fetching outdated packages (forced: %s)...", force_update ? "yes" : "no");

    // Capture the return value to satisfy the [[nodiscard]] attribute.
    brew_error_t fetch_err = brew_fetch_outdated(brew);
    if (fetch_err != BREW_SUCCESS) {
      log_message(verbose, "Fetch failed with error: %s", brew_error_string(fetch_err));
    } else {
      log_message(verbose, "Fetch successful. Found %d outdated packages.", brew->outdated_count);
    }
  }

  // Prepare the message for Sketchybar.
  char trigger_message[MAX_MESSAGE_LENGTH];
  snprintf(
      trigger_message, sizeof(trigger_message),
      "--trigger %s outdated_count='%d' pending_updates='%s' last_check='%ld' error='%s'",
      event_name, brew->outdated_count, brew->package_list ? brew->package_list : "",
      (long)brew->last_check, brew_error_string(brew->last_error));

  // Send the command to Sketchybar.
  sketchybar(trigger_message);
}

/**
 * @brief Signal handler for graceful shutdown and forced refresh.
 *
 * This function is async-signal-safe. It only sets atomic flags.
 * @param sig The signal number received.
 */
static void handle_signal(int sig) {
  switch (sig) {
    case SIGINT:
    case SIGTERM:
      g_terminate_flag = 1;
      break;
    case SIGUSR1:
      g_force_check_flag = 1;
      break;
  }
}

/**
 * @brief Prints usage information to stderr.
 * @param program_name The name of the executable (argv[0]).
 */
static void show_usage(const char* program_name) {
  fprintf(
      stderr, "Usage: %s <event_name> [check_interval_s] [update_interval_s] [--verbose]\n",
      program_name);
}

/**
 * @brief Logs a message to stderr if verbose mode is enabled.
 *
 * @param verbose The flag indicating if logging is active.
 * @param format The format string for the message.
 * @param ... Variable arguments for the format string.
 */
static void log_message(bool verbose, const char* format, ...) {
  if (!verbose) return;

  // Add timestamp for better logging (using thread-safe localtime_r).
  char      time_buf[26];
  time_t    now = time(NULL);
  struct tm tminfo;
  if (localtime_r(&now, &tminfo) != NULL) {
    strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M:%S", &tminfo);
  } else {
    snprintf(time_buf, sizeof(time_buf), "UNKNOWN");
  }

  fprintf(stderr, "[%s] brew_check: ", time_buf);

  va_list args;
  va_start(args, format);
  vfprintf(stderr, format, args);
  va_end(args);
  fprintf(stderr, "\n");
}

//===--------------------------------------------------------------------------===//
