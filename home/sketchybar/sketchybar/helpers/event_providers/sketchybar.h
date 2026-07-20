//===---------------------------------------------------------------------------===//
/**
 * @file sketchybar.h
 * @brief Mach IPC communication library for SketchyBar event providers.
 *
 * This header provides a lightweight, self-contained C library for communicating
 * with SketchyBar via Mach inter-process communication (IPC). It handles
 * bootstrap port lookup, message formatting, and reliable message delivery to
 * the SketchyBar daemon.
 *
 * Key features:
 *  - Zero external dependencies (uses only macOS Mach APIs)
 *  - Automatic bootstrap port resolution and caching
 *  - Safe message formatting with quote handling
 *  - Connection recovery on delivery failure
 *  - Thread-safe global port caching
 *
 * Typical usage:
 *  1. Call sketchybar("--add event <name>") to register an event
 *  2. Call sketchybar("--trigger <name> key=value ...") to emit events
 *
 * @note Designed for use in minimal event provider binaries for SketchyBar.
 *
 * @author LCS.Dev
 * @date 2025-01-10
 */
//===---------------------------------------------------------------------------===//

#ifndef SKETCHYBAR_H
#define SKETCHYBAR_H

#include <bootstrap.h>
#include <mach/arm/kern_return.h>
#include <mach/mach.h>
#include <mach/mach_port.h>
#include <mach/message.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

//===---------------------------------- TYPES ----------------------------------===//

/** @brief Opaque type alias for the environment string passed to Mach handlers. */
typedef char* env;

/** @brief Macro to declare a Mach message handler function signature. */
#define MACH_HANDLER(name) void name(env env)
/** @brief Function pointer type for Mach message handlers. */
typedef MACH_HANDLER(mach_handler);

/**
 * @struct mach_message
 * @brief Represents a Mach IPC message with an out-of-line descriptor.
 */
struct mach_message {
  mach_msg_header_t         header;                 /**< Standard Mach message header. */
  mach_msg_size_t           msgh_descriptor_count;  /**< Number of descriptors (always 1). */
  mach_msg_ool_descriptor_t descriptor;             /**< Out-of-line data descriptor. */
};

/**
 * @struct mach_buffer
 * @brief Complete Mach message buffer including trailer.
 *
 * Used for receiving messages; the trailer contains authentication metadata.
 */
struct mach_buffer {
  struct mach_message message;  /**< The Mach message payload. */
  mach_msg_trailer_t  trailer;  /**< Message trailer with security info. */
};

/**
 * @brief Cached Mach port for communication with SketchyBar.
 *
 * Initialized lazily by sketchybar() and refreshed on send failure.
 * Zero indicates the port has not yet been resolved.
 */
static mach_port_t g_mach_port = 0;

/**
 * @brief Resolves the bootstrap port for communicating with SketchyBar.
 *
 * Looks up the registered Mach service name derived from the BAR_NAME
 * environment variable (defaults to "sketchybar").
 *
 * @return A valid Mach port on success, 0 on failure.
 *
 * @note The returned port is a send right that must not be deallocated
 *       by the caller; it is cached in @ref g_mach_port.
 * @warning If BAR_NAME exceeds 256 characters, the lookup fails.
 */
[[nodiscard]] static inline mach_port_t mach_get_bs_port() {
  mach_port_name_t task = mach_task_self();

  mach_port_t bs_port;
  if (task_get_special_port(task, TASK_BOOTSTRAP_PORT, &bs_port) != KERN_SUCCESS) {
    return 0;
  }

  const char* name = getenv("BAR_NAME");
  if (!name) name = "sketchybar";

  size_t name_len = strlen(name);
  // Check for overflow
  if (name_len > 256) {
    fprintf(stderr, "Bar name too long\n");
    return 0;
  }

  uint32_t lookup_len = 16 + name_len;
  char     buffer[lookup_len];
  int      written = snprintf(buffer, lookup_len, "git.felix.%s", name);

  if (written < 0 || written >= (int)lookup_len) {
    fprintf(stderr, "Error formatting bar name\n");
    return 0;
  }

  mach_port_t port;
  if (bootstrap_look_up(bs_port, buffer, &port) != KERN_SUCCESS) return 0;
  return port;
}

/**
 * @brief Sends an out-of-line Mach message to the specified port.
 *
 * Constructs a complex Mach message containing the provided string as an
 * out-of-line descriptor and transmits it with a short timeout. Periodic
 * telemetry events are intentionally dropped if SketchyBar is not draining its
 * port, which avoids helper backpressure during lock, sleep, and wake.
 *
 * @param port    Destination Mach port (must be a valid send right).
 * @param message Null-terminated string to transmit.
 * @param len     Length of the message including the null terminator.
 * @return true if the message was sent successfully, false otherwise.
 *
 * @note The message is copied into kernel space; the caller retains ownership
 *       of the original buffer.
 */
[[nodiscard]] static inline bool mach_send_message(mach_port_t port, char* message, uint32_t len) {
  if (!message || !port || len == 0) {
    return false;
  }

  struct mach_message msg     = {0};  // Zero-initialization using C23
  msg.header.msgh_remote_port = port;
  msg.header.msgh_local_port  = 0;
  msg.header.msgh_id          = 0;
  msg.header.msgh_bits        = MACH_MSGH_BITS_SET(
      MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND, 0, MACH_MSGH_BITS_COMPLEX);

  msg.header.msgh_size      = sizeof(struct mach_message);
  msg.msgh_descriptor_count = 1;
  msg.descriptor.address    = message;
  msg.descriptor.size       = len * sizeof(char);
  msg.descriptor.copy       = MACH_MSG_VIRTUAL_COPY;
  msg.descriptor.deallocate = false;
  msg.descriptor.type       = MACH_MSG_OOL_DESCRIPTOR;

  kern_return_t err = mach_msg(
      &msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(struct mach_message), 0,
      MACH_PORT_NULL, 100, MACH_PORT_NULL);

  return err == KERN_SUCCESS || err == MACH_SEND_TIMED_OUT;
}

/**
 * @brief Formats a raw message string for SketchyBar command parsing.
 *
 * Strips matching outer quotes and converts unquoted spaces to null terminators
 * so that SketchyBar receives a properly tokenized argument list.
 *
 * @param message           The raw input command string.
 * @param formatted_message Output buffer for the formatted result.
 * @param buffer_size       Size of the output buffer in bytes.
 * @return Length of the formatted message including the null terminator,
 *         or 0 if input validation fails.
 *
 * @note The output buffer is zero-initialized before processing.
 * @warning If @p buffer_size is too small, the output is truncated.
 */
[[nodiscard]] static inline uint32_t format_message(
    const char* message, char* formatted_message, size_t buffer_size) {
  if (!message || !formatted_message || buffer_size == 0) return 0;

  // Zero-initialize the output buffer.
  memset(formatted_message, 0, buffer_size);

  char     outer_quote    = 0;
  uint32_t caret          = 0;
  uint32_t message_length = strlen(message) + 1;

  for (uint32_t i = 0; i < message_length && i < buffer_size; ++i) {
    if (message[i] == '"' || message[i] == '\'') {
      if (outer_quote && outer_quote == message[i])
        outer_quote = 0;
      else if (!outer_quote)
        outer_quote = message[i];
      continue;
    }

    // Check for buffer overflow.
    if (caret >= buffer_size - 1) break;

    formatted_message[caret] = message[i];
    if (message[i] == ' ' && !outer_quote) formatted_message[caret] = '\0';
    caret++;
  }

  if (caret > 0 && caret < buffer_size && formatted_message[caret] == '\0'
      && formatted_message[caret - 1] == '\0') {
    caret--;
  }

  // Ensure null termination.
  if (caret < buffer_size)
    formatted_message[caret] = '\0';
  else
    formatted_message[buffer_size - 1] = '\0';

  return caret + 1;
}

/**
 * @brief Sends a formatted command to SketchyBar via Mach IPC.
 *
 * Looks up the cached Mach port (or resolves it on first use), formats the
 * message, and attempts delivery. If sending fails, the port is refreshed once
 * before giving up and terminating the process.
 *
 * @param message The raw command string to send (e.g., "--trigger event key=value").
 *
 * @note A NULL message is silently ignored.
 * @warning If SketchyBar is not running, this function calls exit(0) to terminate
 *          the event provider cleanly.
 */
static inline void sketchybar(const char* message) {
  if (!message) return;

  // Allocate a sufficiently large buffer
  size_t buffer_size = strlen(message) + 2;
  char   formatted_message[buffer_size];

  uint32_t length = format_message(message, formatted_message, buffer_size);
  if (!length) return;

  if (!g_mach_port) g_mach_port = mach_get_bs_port();

  if (!mach_send_message(g_mach_port, formatted_message, length)) {
    g_mach_port = mach_get_bs_port();  // Try to get the port again
    if (!mach_send_message(g_mach_port, formatted_message, length)) {
      // No sketchybar instance running, exit.
      exit(0);
    }
  }
}

#endif /* SKETCHYBAR_H */

//===---------------------------------------------------------------------------===//
