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

typedef char* env;

#define MACH_HANDLER(name) void name(env env)
typedef MACH_HANDLER(mach_handler);

struct mach_message {
  mach_msg_header_t         header;
  mach_msg_size_t           msgh_descriptor_count;
  mach_msg_ool_descriptor_t descriptor;
};

struct mach_buffer {
  struct mach_message message;
  mach_msg_trailer_t  trailer;
};

static mach_port_t g_mach_port = 0;

/**
 * Gets the bootstrap port for communication with sketchybar
 *
 * @return The mach port, 0 if it fails
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
 * Sends a message to the specified port
 *
 * @param port Destination mach port
 * @param message Message to send
 * @param len Length of the message
 * @return true if sending succeeded, false otherwise
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
      &msg.header, MACH_SEND_MSG, sizeof(struct mach_message), 0, MACH_PORT_NULL,
      MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);

  return err == KERN_SUCCESS;
}

/**
 * Formats a message for sketchybar, correctly handling quotes
 *
 * @param message Input message
 * @param formatted_message Buffer for the formatted message
 * @param buffer_size Buffer size
 * @return Length of the formatted message (including null terminator)
 */
[[nodiscard]] static inline uint32_t format_message(
    const char* message, char* formatted_message, size_t buffer_size) {
  if (!message || !formatted_message || buffer_size == 0) return 0;

  // Zero-initialize the output buffer
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

    // Check for buffer overflow
    if (caret >= buffer_size - 1) break;

    formatted_message[caret] = message[i];
    if (message[i] == ' ' && !outer_quote) formatted_message[caret] = '\0';
    caret++;
  }

  if (caret > 0 && caret < buffer_size && formatted_message[caret] == '\0'
      && formatted_message[caret - 1] == '\0') {
    caret--;
  }

  // Ensure null termination
  if (caret < buffer_size)
    formatted_message[caret] = '\0';
  else
    formatted_message[buffer_size - 1] = '\0';

  return caret + 1;
}

/**
 * Sends a message to sketchybar
 *
 * @param message Message to send
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
