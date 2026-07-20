//===---------------------------------------------------------------------------===//
/**
 * @file brew.h
 * @brief Homebrew package manager integration library for monitoring outdated packages.
 *
 * This header provides a lightweight, self-contained C library for checking Homebrew
 * package updates. It offers thread-safe operations for running `brew update` and
 * `brew outdated` commands, with built-in safeguards against system overload and
 * concurrent execution.
 *
 * Key features:
 *  - Zero external dependencies (uses only POSIX system calls)
 *  - Robust error handling with detailed error codes
 *  - Memory-safe buffer management with overflow protection
 *  - System load awareness to defer updates during high CPU usage
 *  - Direct process execution via fork/exec (no shell invocation)
 *
 * Typical usage:
 *  1. Initialize with brew_init()
 *  2. Check if update is needed with brew_needs_update()
 *  3. Fetch outdated packages with brew_fetch_outdated()
 *  4. Access results via brew_t structure
 *  5. Clean up with brew_cleanup()
 *
 * @note Designed for use in minimal environments like status bar applications
 *       where PATH may be restricted.
 *
 * @author LCS.Dev
 * @date 2025-01-10
 */
//===---------------------------------------------------------------------------===//

#ifndef BREW_H
#define BREW_H

#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

//===-------------------------------- CONSTANTS --------------------------------===//

/** @brief Absolute path to the Homebrew executable. Using an absolute path is crucial for
 * robustness when running from environments like Sketchybar, which may have a minimal PATH. */
static char BREW_EXECUTABLE_PATH[PATH_MAX] = "/opt/homebrew/bin/brew";

/** @brief Maximum length for a single package name. */
static const int BREW_MAX_PACKAGE_NAME = 128;

/** @brief The initial size of the buffer that stores the concatenated list of outdated packages. */
static const int BREW_INITIAL_BUFFER_SIZE = 1024;

/** @brief The absolute maximum size for the package list buffer to prevent uncontrolled memory
 * allocation. */
static const int BREW_MAX_BUFFER_SIZE = 16384;

/** @brief Maximum time a single brew command may run before it is terminated. */
static const int BREW_COMMAND_TIMEOUT_SECONDS = 120;

/**
 * @brief Global variable tracking the PID of the currently running brew child process.
 *
 * Used by signal handlers and cleanup routines to terminate active commands.
 * Must be volatile sig_atomic_t for async-signal-safe access.
 */
static volatile sig_atomic_t g_brew_child_pid = 0;

//===------------------------------- ERROR CODES -------------------------------===//

/**
 * @enum brew_error_t
 * @brief Defines possible error codes for brew operations.
 */
typedef enum {
  BREW_SUCCESS = 0,              /**< Operation completed successfully. */
  BREW_ERROR_NOT_INSTALLED,      /**< Homebrew executable not found. */
  BREW_ERROR_UPDATE_IN_PROGRESS, /**< An update operation is already running. */
  BREW_ERROR_MEMORY_ALLOCATION,  /**< Failed to allocate memory (malloc, realloc). */
  BREW_ERROR_COMMAND_EXECUTION,  /**< Failed to fork or execute a brew command. */
  BREW_ERROR_PIPE_CREATION,      /**< Failed to create a pipe for IPC. */
  BREW_ERROR_BUFFER_OVERFLOW, /**< The list of outdated packages exceeds the maximum buffer size. */
  BREW_ERROR_INVALID_STATE,   /**< An operation was called on an uninitialized or invalid structure.
                               */
} brew_error_t;

//===----------------------------- DATA STRUCTURES -----------------------------===//

/**
 * @struct brew_t
 * @brief Holds the state of Homebrew information.
 *
 * This structure tracks the number of outdated packages, a list of their names,
 * and metadata about when checks and updates were last performed.
 */
typedef struct {
  int          outdated_count;     /**< Number of outdated packages. */
  char*        package_list;       /**< Comma-separated string of outdated package names. */
  size_t       package_list_size;  /**< Current allocated size of package_list buffer. */
  time_t       last_update;        /**< Timestamp of the last successful `brew update`. */
  time_t       last_check;         /**< Timestamp of the last check for outdated packages. */
  brew_error_t last_error;         /**< The last error that occurred during an operation. */
  bool         update_in_progress; /**< Flag to prevent concurrent updates. */
} brew_t;

//===------------------------ PRIVATE HELPER FUNCTIONS -------------------------===//

static void brew_terminate_active_command(void);
[[nodiscard]] static brew_error_t _brew_execute_command(
    const char* args[], char** output_buffer, size_t* buffer_size);
[[nodiscard]] static brew_error_t _brew_parse_outdated_output(brew_t* brew, char* package_output);
[[nodiscard]] static brew_error_t _brew_resize_buffer(brew_t* brew, size_t required_size);
[[nodiscard]] static bool         _brew_resolve_executable(void);
[[nodiscard]] static time_t       _brew_load_last_update(void);
static void                       _brew_save_last_update(time_t timestamp);
static int                        _get_cpu_core_count();

/**
 * @brief Terminates the active brew child process, if any.
 *
 * Sends SIGTERM to the process group and directly to the child PID
 * stored in @ref g_brew_child_pid. This is async-signal-safe.
 */
static inline void brew_terminate_active_command(void) {
  pid_t pid = (pid_t)g_brew_child_pid;
  if (pid <= 0) return;

  kill(-pid, SIGTERM);
  kill(pid, SIGTERM);
}

//===------------------------------- PUBLIC API --------------------------------===//

/**
 * @brief Initializes the brew state structure.
 * @param brew A pointer to the brew_t struct to initialize.
 * @return BREW_SUCCESS on success, or an error code on failure.
 */
[[nodiscard]] static inline brew_error_t brew_init(brew_t* brew) {
  if (!brew) return BREW_ERROR_INVALID_STATE;

  memset(brew, 0, sizeof(brew_t));
  brew->package_list = (char*)malloc(BREW_INITIAL_BUFFER_SIZE);
  if (!brew->package_list) {
    return BREW_ERROR_MEMORY_ALLOCATION;
  }
  brew->package_list[0]   = '\0';
  brew->package_list_size = BREW_INITIAL_BUFFER_SIZE;
  brew->last_error        = BREW_SUCCESS;

  // Check if brew is installed right away.
  if (!_brew_resolve_executable()) {
    // Free allocated memory before returning error.
    free(brew->package_list);
    brew->package_list = NULL;
    brew->last_error   = BREW_ERROR_NOT_INSTALLED;
    return BREW_ERROR_NOT_INSTALLED;
  }

  brew->last_update = _brew_load_last_update();

  return BREW_SUCCESS;
}

/**
 * @brief Frees all resources associated with the brew state.
 * @param brew A pointer to the brew_t struct to clean up.
 */
static inline void brew_cleanup(brew_t* brew) {
  if (brew) {
    free(brew->package_list);
    brew->package_list = NULL;
  }
}

/**
 * @brief Checks if a `brew update` operation is needed based on a time interval and system load.
 * @param brew A pointer to the brew_t struct.
 * @param update_interval_seconds The minimum time in seconds that must pass before a new update.
 * @return True if an update is needed, false otherwise.
 */
[[nodiscard]] static inline bool brew_needs_update(
    const brew_t* brew, int update_interval_seconds) {
  if (!brew) return false;

  // Time check.
  time_t current_time = time(NULL);
  if ((current_time - brew->last_update) < update_interval_seconds) {
    return false;
  }

  // System load check to avoid running updates on a busy system.
  double load[1];
  if (getloadavg(load, 1) == 1) {
    static int core_count = 0;
    if (core_count == 0) core_count = _get_cpu_core_count();
    // The threshold is 75% of the number of cores.
    double high_load_threshold = (double)core_count * 0.75;
    if (load[0] > high_load_threshold) {
      return false;  // Defer update if system is busy.
    }
  }
  return true;
}

/**
 * @brief Runs `brew update` and then gets the list of outdated packages.
 * @param brew A pointer to the brew_t struct to update with new data.
 * @return BREW_SUCCESS on success, or an error code on failure.
 */
[[nodiscard]] static inline brew_error_t brew_fetch_outdated(brew_t* brew, bool run_update) {
  if (!brew) return BREW_ERROR_INVALID_STATE;
  if (brew->update_in_progress) return BREW_ERROR_UPDATE_IN_PROGRESS;

  brew->update_in_progress = true;
  brew->last_check         = time(NULL);

  if (run_update) {
    // Step 1: Run `brew update`
    const char*  update_args[] = {BREW_EXECUTABLE_PATH, "update", NULL};
    brew_error_t err           = _brew_execute_command(update_args, NULL, NULL);

    if (err != BREW_SUCCESS) {
      brew->last_error         = err;
      brew->update_in_progress = false;
      return err;
    }
    brew->last_update = time(NULL);
    _brew_save_last_update(brew->last_update);
  }

  // Step 2: Run `brew outdated --quiet` to get the list.
  const char* outdated_args[] = {BREW_EXECUTABLE_PATH, "outdated", "--quiet", NULL};
  char*       package_output  = NULL;
  size_t      output_size     = 0;
  brew_error_t err            = _brew_execute_command(outdated_args, &package_output, &output_size);

  if (err != BREW_SUCCESS) {
    free(package_output);
    brew->last_error         = err;
    brew->update_in_progress = false;
    return err;
  }

  err = _brew_parse_outdated_output(brew, package_output);
  if (err != BREW_SUCCESS) {
    free(package_output);
    brew->last_error         = err;
    brew->update_in_progress = false;
    return err;
  }

  free(package_output);
  brew->update_in_progress = false;
  brew->last_error         = BREW_SUCCESS;
  return BREW_SUCCESS;
}

/**
 * @brief Gets a human-readable string for a brew_error_t code.
 * @param error The error code.
 * @return A constant string describing the error.
 */
[[nodiscard]] static inline const char* brew_error_string(brew_error_t error) {
  switch (error) {
    case BREW_SUCCESS:
      return "Success";
    case BREW_ERROR_NOT_INSTALLED:
      return "Homebrew not found";
    case BREW_ERROR_UPDATE_IN_PROGRESS:
      return "Update already in progress";
    case BREW_ERROR_MEMORY_ALLOCATION:
      return "Memory allocation failed";
    case BREW_ERROR_COMMAND_EXECUTION:
      return "Command execution failed";
    case BREW_ERROR_PIPE_CREATION:
      return "IPC pipe creation failed";
    case BREW_ERROR_BUFFER_OVERFLOW:
      return "Output buffer overflow";
    case BREW_ERROR_INVALID_STATE:
      return "Invalid state";
    default:
      return "Unknown error";
  }
}

//===----------------- PRIVATE HELPER FUNCTIONS IMPLEMENTATION -----------------===//

/**
 * @brief [Private] Parses the raw output of `brew outdated --quiet`.
 *
 * Tokenizes the output by newline, filters out non-package lines, and builds
 * a comma-separated package list stored in the brew state structure.
 *
 * @param brew           Pointer to the brew state structure.
 * @param package_output Raw null-terminated string from the brew command.
 * @return BREW_SUCCESS on success, or an error code on failure.
 *
 * @note Lines that do not start with an alphanumeric character are skipped
 *       to filter status messages and decorative output.
 */
[[nodiscard]] static inline brew_error_t _brew_parse_outdated_output(
    brew_t* brew, char* package_output) {
  if (!brew || !package_output) return BREW_ERROR_INVALID_STATE;

  brew->outdated_count     = 0;
  brew->package_list[0]    = '\0';
  size_t package_list_used = 0;

  char* line = strtok(package_output, "\n");
  while (line != NULL) {
    // Skip status lines like "✔︎ JSON API cask.jws.json".
    if (line[0] == '\0'
        || (!(line[0] >= 'a' && line[0] <= 'z') && !(line[0] >= 'A' && line[0] <= 'Z')
            && !(line[0] >= '0' && line[0] <= '9'))) {
      line = strtok(NULL, "\n");
      continue;
    }

    brew->outdated_count++;
    size_t line_len       = strlen(line);
    size_t required_space = package_list_used + line_len + 2;

    if (required_space > brew->package_list_size) {
      brew_error_t err = _brew_resize_buffer(brew, required_space);
      if (err != BREW_SUCCESS) return err;
    }

    if (package_list_used > 0) {
      brew->package_list[package_list_used] = ',';
      package_list_used++;
    }
    memcpy(brew->package_list + package_list_used, line, line_len);
    package_list_used += line_len;
    brew->package_list[package_list_used] = '\0';

    line = strtok(NULL, "\n");
  }

  return BREW_SUCCESS;
}

/**
 * @brief [Private] Resolves the absolute path to the Homebrew executable.
 *
 * Checks a list of known installation paths and updates @ref BREW_EXECUTABLE_PATH
 * if a valid executable is found.
 *
 * @return true if a brew executable was found, false otherwise.
 */
[[nodiscard]] static inline bool _brew_resolve_executable(void) {
  const char* candidates[] = {
      "/opt/homebrew/bin/brew",
      "/usr/local/bin/brew",
      NULL,
  };

  for (int i = 0; candidates[i] != NULL; ++i) {
    if (access(candidates[i], X_OK) == 0) {
      int written = snprintf(BREW_EXECUTABLE_PATH, sizeof(BREW_EXECUTABLE_PATH), "%s", candidates[i]);
      return written > 0 && written < (int)sizeof(BREW_EXECUTABLE_PATH);
    }
  }

  return false;
}

/**
 * @brief [Private] Executes a command and captures its standard output.
 *
 * This function is the robust replacement for `popen` and `system`. It uses
 * `fork`, `execv`, and `pipe` for full control over process execution.
 *
 * @param args Null-terminated array of strings representing the command and its arguments.
 * @param output_buffer A pointer to a char pointer that will be allocated to store the output. The
 * caller must free this buffer. If NULL, output is discarded.
 * @param buffer_size A pointer to a size_t to store the size of the output buffer. Can be NULL if
 * output is discarded.
 * @return BREW_SUCCESS on success, or an error code on failure.
 */
[[nodiscard]] static inline brew_error_t _brew_execute_command(
    const char* args[], char** output_buffer, size_t* buffer_size) {
  bool capture_output = output_buffer != NULL;
  int  pipefd[2]      = {-1, -1};

  if (output_buffer) *output_buffer = NULL;
  if (buffer_size) *buffer_size = 0;

  if (capture_output && pipe(pipefd) == -1) {
    return BREW_ERROR_PIPE_CREATION;
  }

  pid_t pid = fork();
  if (pid == -1) {
    if (output_buffer) {
      close(pipefd[0]);
      close(pipefd[1]);
    }
    return BREW_ERROR_COMMAND_EXECUTION;
  }

  if (pid == 0) {  // Child process.
    setpgid(0, 0);
    if (capture_output) {
      close(pipefd[0]);                // Close unused read end.
      dup2(pipefd[1], STDOUT_FILENO);  // Redirect stdout to pipe.
      dup2(pipefd[1], STDERR_FILENO);  // Redirect stderr to pipe as well.
      close(pipefd[1]);
    }

    execv(args[0], (char* const*)args);
    // If execv returns, it must have failed.
    fprintf(stderr, "brew_check: execv failed: %s\n", strerror(errno));
    _exit(127);
  }

  setpgid(pid, pid);
  g_brew_child_pid = pid;

  if (capture_output) {
    close(pipefd[1]);
    pipefd[1] = -1;

    int flags = fcntl(pipefd[0], F_GETFL, 0);
    if (flags != -1) fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK);
  }

  size_t capacity = capture_output ? 4096 : 0;
  size_t size     = 0;
  char*  buffer   = NULL;
  if (capture_output) {
    buffer = (char*)malloc(capacity);
    if (!buffer) {
      close(pipefd[0]);
      brew_terminate_active_command();
      waitpid(pid, NULL, 0);
      g_brew_child_pid = 0;
      return BREW_ERROR_MEMORY_ALLOCATION;
    }
  }

  int    status      = 0;
  bool   child_done  = false;
  bool   pipe_closed = !capture_output;
  time_t started_at  = time(NULL);

  while (!child_done || !pipe_closed) {
    if (capture_output && !pipe_closed) {
      while (true) {
        if (capacity - size <= 1) {
          size_t new_capacity = (capacity <= SIZE_MAX / 2) ? capacity * 2 : SIZE_MAX;
          if (new_capacity <= capacity) {
            free(buffer);
            close(pipefd[0]);
            brew_terminate_active_command();
            waitpid(pid, NULL, 0);
            g_brew_child_pid = 0;
            return BREW_ERROR_MEMORY_ALLOCATION;
          }
          char* new_buffer = (char*)realloc(buffer, new_capacity);
          if (!new_buffer) {
            free(buffer);
            close(pipefd[0]);
            brew_terminate_active_command();
            waitpid(pid, NULL, 0);
            g_brew_child_pid = 0;
            return BREW_ERROR_MEMORY_ALLOCATION;
          }
          buffer   = new_buffer;
          capacity = new_capacity;
        }

        ssize_t bytes_read = read(pipefd[0], buffer + size, capacity - size - 1);
        if (bytes_read > 0) {
          size += (size_t)bytes_read;
          continue;
        }
        if (bytes_read == 0) {
          close(pipefd[0]);
          pipefd[0]   = -1;
          pipe_closed = true;
          break;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;

        free(buffer);
        close(pipefd[0]);
        brew_terminate_active_command();
        waitpid(pid, NULL, 0);
        g_brew_child_pid = 0;
        return BREW_ERROR_COMMAND_EXECUTION;
      }
    }

    if (!child_done) {
      pid_t wait_result = waitpid(pid, &status, WNOHANG);
      if (wait_result == pid) {
        child_done = true;
      } else if (wait_result == -1 && errno != EINTR) {
        if (capture_output && pipefd[0] != -1) close(pipefd[0]);
        free(buffer);
        g_brew_child_pid = 0;
        return BREW_ERROR_COMMAND_EXECUTION;
      }
    }

    if (child_done && pipe_closed) break;

    time_t now = time(NULL);
    if (now != (time_t)-1 && started_at != (time_t)-1
        && now - started_at >= BREW_COMMAND_TIMEOUT_SECONDS) {
      brew_terminate_active_command();
      for (int i = 0; i < 10; ++i) {
        pid_t wait_result = waitpid(pid, &status, WNOHANG);
        if (wait_result == pid) {
          child_done = true;
          break;
        }
        nanosleep(&(struct timespec){.tv_sec = 0, .tv_nsec = 100000000}, NULL);
      }
      if (!child_done) {
        kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
      }

      if (capture_output && pipefd[0] != -1) close(pipefd[0]);
      free(buffer);
      g_brew_child_pid = 0;
      return BREW_ERROR_COMMAND_EXECUTION;
    }

    nanosleep(&(struct timespec){.tv_sec = 0, .tv_nsec = 100000000}, NULL);
  }

  g_brew_child_pid = 0;

  if (capture_output) {
    buffer[size]   = '\0';
    *output_buffer = buffer;
    if (buffer_size) *buffer_size = size;
  }

  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
    return BREW_SUCCESS;
  }

  // If the command failed but we captured output, we don't free it
  // so the caller might be able to inspect it. But in this design,
  // we'll just free it on error to keep things simple.
  if (output_buffer && *output_buffer) {
    free(*output_buffer);
    *output_buffer = NULL;
  }
  return BREW_ERROR_COMMAND_EXECUTION;
}

/**
 * @brief [Private] Resizes the package_list buffer to accommodate new data.
 *
 * Doubles the buffer size until it meets the required size, clamped to
 * @ref BREW_MAX_BUFFER_SIZE.
 *
 * @param brew        Pointer to the brew state structure.
 * @param needed_size The minimum required buffer size in bytes.
 * @return BREW_SUCCESS on success, BREW_ERROR_BUFFER_OVERFLOW if the limit is
 *         exceeded, or BREW_ERROR_MEMORY_ALLOCATION if realloc fails.
 */
[[nodiscard]] static inline brew_error_t _brew_resize_buffer(brew_t* brew, size_t needed_size) {
  if (!brew) return BREW_ERROR_INVALID_STATE;
  if (needed_size > BREW_MAX_BUFFER_SIZE) return BREW_ERROR_BUFFER_OVERFLOW;

  size_t new_size = brew->package_list_size;
  while (new_size < needed_size) {
    new_size *= 2;
  }
  if (new_size > BREW_MAX_BUFFER_SIZE) new_size = BREW_MAX_BUFFER_SIZE;

  if (new_size > brew->package_list_size) {
    char* new_buffer = (char*)realloc(brew->package_list, new_size);
    if (!new_buffer) return BREW_ERROR_MEMORY_ALLOCATION;
    brew->package_list      = new_buffer;
    brew->package_list_size = new_size;
  }
  return BREW_SUCCESS;
}

/**
 * @brief [Private] Constructs the filesystem path for the last-update timestamp file.
 *
 * Uses TMPDIR (or /tmp as fallback) to build a path like
 * "<tmpdir>/sketchybar-brew-check.last_update".
 *
 * @param buffer      Output buffer to write the path into.
 * @param buffer_size Size of the output buffer in bytes.
 * @return true if the path was written successfully, false on overflow or invalid input.
 */
[[nodiscard]] static inline bool _brew_last_update_path(char* buffer, size_t buffer_size) {
  if (!buffer || buffer_size == 0) return false;

  const char* tmpdir = getenv("TMPDIR");
  if (!tmpdir || tmpdir[0] == '\0') tmpdir = "/tmp";

  size_t tmpdir_len = strlen(tmpdir);
  const char* sep   = (tmpdir_len > 0 && tmpdir[tmpdir_len - 1] == '/') ? "" : "/";
  int written =
      snprintf(buffer, buffer_size, "%s%ssketchybar-brew-check.last_update", tmpdir, sep);

  return written > 0 && written < (int)buffer_size;
}

/**
 * @brief [Private] Loads the timestamp of the last successful `brew update` from disk.
 *
 * Reads the value stored by _brew_save_last_update() and returns it.
 *
 * @return The stored timestamp, or 0 if no file exists or the data is invalid.
 */
[[nodiscard]] static inline time_t _brew_load_last_update(void) {
  char path[PATH_MAX];
  if (!_brew_last_update_path(path, sizeof(path))) return 0;

  FILE* file = fopen(path, "r");
  if (!file) return 0;

  long long timestamp = 0;
  int       scanned   = fscanf(file, "%lld", &timestamp);
  fclose(file);

  if (scanned != 1 || timestamp <= 0) return 0;
  return (time_t)timestamp;
}

/**
 * @brief [Private] Persists the timestamp of the last successful `brew update` to disk.
 *
 * Writes the given timestamp to a file in TMPDIR for retrieval across daemon restarts.
 *
 * @param timestamp The timestamp to persist. Values <= 0 are ignored.
 *
 * @note The file is created with mode 0600 for privacy.
 */
static inline void _brew_save_last_update(time_t timestamp) {
  char path[PATH_MAX];
  if (timestamp <= 0 || !_brew_last_update_path(path, sizeof(path))) return;

  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd == -1) return;

  dprintf(fd, "%lld\n", (long long)timestamp);
  close(fd);
}

/**
 * @brief [Private] Queries the number of logical CPU cores.
 *
 * Uses sysctlbyname("hw.ncpu") to determine the logical core count for load
 * threshold calculations.
 *
 * @return The number of logical CPU cores, or 2 as a safe default on error.
 */
static inline int _get_cpu_core_count() {
  int    ncpu;
  size_t len = sizeof(ncpu);
  if (sysctlbyname("hw.ncpu", &ncpu, &len, NULL, 0) == 0 && ncpu > 0) {
    return ncpu;
  }
  return 2;  // Return a safe default.
}

#endif /* BREW_H */

//===---------------------------------------------------------------------------===//
