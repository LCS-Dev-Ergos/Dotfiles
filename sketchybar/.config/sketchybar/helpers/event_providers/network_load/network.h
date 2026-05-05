//===---------------------------------------------------------------------------===//
/**
 * @file network.h
 * @brief Network interface statistics library for macOS.
 *
 * This header provides a lightweight, self-contained C library for monitoring
 * network interface throughput on macOS. It reads kernel-managed interface MIB
 * data to compute real-time upload and download speeds with automatic unit
 * scaling.
 *
 * Key features:
 *  - Zero external dependencies (uses only POSIX and macOS system calls)
 *  - Automatic byte-rate to human-readable unit conversion
 *  - Time-delta based throughput calculation
 *  - Minimal memory footprint with stack-allocated structures
 *
 * Typical usage:
 *  1. Initialize with network_init()
 *  2. Periodically call network_update() to refresh statistics
 *  3. Access results via the network structure fields
 *
 * @note Designed for use in minimal environments like status bar applications.
 *
 * @author LCS.Dev
 * @date 2025-01-10
 */
//===---------------------------------------------------------------------------===//

#ifndef NETWORK_H
#define NETWORK_H

#include <errno.h>
#include <math.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/sysctl.h>

//===-------------------------------- CONSTANTS --------------------------------===//

/**
 * @brief Human-readable unit labels for network throughput.
 *
 * Indexed by the @ref unit enumeration. Each string includes a leading space
 * where appropriate for alignment.
 */
static const char unit_str[3][6] = {
    {" Bps"},
    {"KBps"},
    {"MBps"},
};

/**
 * @enum unit
 * @brief Enumeration of supported network throughput units.
 */
enum unit { UNIT_BPS, UNIT_KBPS, UNIT_MBPS };

/**
 * @struct network
 * @brief Holds the state of network interface monitoring.
 *
 * Tracks the kernel MIB row index, raw interface statistics, timing information
 * for delta calculations, and computed upload/download speeds with units.
 */
struct network {
  uint32_t         row;       /**< Kernel MIB row index for the interface. */
  struct ifmibdata data;      /**< Raw interface statistics from the kernel. */
  struct timeval   tv_nm1;    /**< Timestamp of the previous sample. */
  struct timeval   tv_n;      /**< Timestamp of the current sample. */
  struct timeval   tv_delta;  /**< Computed delta between current and previous sample. */

  int       up;         /**< Computed upload speed in the current unit. */
  int       down;       /**< Computed download speed in the current unit. */
  enum unit up_unit;    /**< Unit of measurement for upload speed. */
  enum unit down_unit;  /**< Unit of measurement for download speed. */
};

/**
 * @brief Retrieves raw network interface data from the kernel MIB.
 *
 * Uses sysctl to query general interface statistics for the given row index.
 *
 * @param net_row The kernel MIB row index of the interface.
 * @param data    Pointer to an ifmibdata structure to populate.
 * @return 0 on success, -1 on failure.
 *
 * @warning This is a low-level helper; callers should validate @p data is non-NULL.
 */
[[nodiscard]] static inline int ifdata(uint32_t net_row, struct ifmibdata* data) {
  if (!data) return -1;

  static size_t  size          = sizeof(struct ifmibdata);
  static int32_t data_option[] = {CTL_NET,      PF_LINK, NETLINK_GENERIC,
                                  IFMIB_IFDATA, 0,       IFDATA_GENERAL};
  data_option[4]               = net_row;

  int result = sysctl(data_option, 6, data, &size, NULL, 0);
  return (result < 0) ? -1 : 0;
}

/**
 * @brief Initializes a network structure for a named interface.
 *
 * Iterates over all system network interfaces to locate the one matching
 * @p ifname, then captures an initial timestamp and MIB data.
 *
 * @param net    Pointer to the network structure to initialize.
 * @param ifname The name of the network interface to monitor (e.g., "en0").
 * @return 0 on success, -1 if the interface is not found or sysctl fails.
 *
 * @note The caller must ensure @p net and @p ifname are valid pointers.
 */
[[nodiscard]] static inline int network_init(struct network* net, char* ifname) {
  if (!net || !ifname) return -1;

  memset(net, 0, sizeof(struct network));

  static int count_option[]  = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT};
  uint32_t   interface_count = 0;
  size_t     size            = sizeof(uint32_t);

  if (sysctl(count_option, 5, &interface_count, &size, NULL, 0) < 0) {
    fprintf(stderr, "Error getting the number of interfaces: %s\n", strerror(errno));
    return -1;
  }

  bool interface_found = false;
  for (uint32_t i = 0; i < interface_count; i++) {
    if (ifdata(i, &net->data) < 0) continue;

    if (strcmp(net->data.ifmd_name, ifname) == 0) {
      net->row        = i;
      interface_found = true;
      break;
    }
  }

  if (!interface_found) {
    fprintf(stderr, "Interface '%s' not found\n", ifname);
    return -1;
  }

  // Initialize timeval structures.
  gettimeofday(&net->tv_n, NULL);
  net->tv_nm1 = net->tv_n;

  return 0;
}

/**
 * @brief Updates network throughput statistics.
 *
 * Captures the current time and interface byte counters, computes the time
 * delta since the last call, and derives upload and download speeds. Results
 * are stored in the @p net structure with automatic unit scaling.
 *
 * @param net Pointer to the network structure to update.
 *
 * @note If the time delta is outside the valid range [1e-6, 1e2] seconds,
 *       the update is skipped to avoid spurious values.
 * @warning The caller must have previously called network_init() on @p net.
 */
static inline void network_update(struct network* net) {
  if (!net) return;

  // Update timestamps
  if (gettimeofday(&net->tv_n, NULL) < 0) {
    fprintf(stderr, "Error getting timestamp: %s\n", strerror(errno));
    return;
  }

  timersub(&net->tv_n, &net->tv_nm1, &net->tv_delta);
  net->tv_nm1 = net->tv_n;

  // Save previous values.
  uint64_t ibytes_nm1 = net->data.ifmd_data.ifi_ibytes;
  uint64_t obytes_nm1 = net->data.ifmd_data.ifi_obytes;

  // Get new data.
  if (ifdata(net->row, &net->data) < 0) {
    fprintf(stderr, "Error getting interface data\n");
    return;
  }

  // Calculate time scale.
  double time_scale = (net->tv_delta.tv_sec + 1e-6 * net->tv_delta.tv_usec);

  // Check that the time is in a reasonable range.
  static const double MIN_VALID_TIME = 1e-6;
  static const double MAX_VALID_TIME = 1e2;

  if (time_scale < MIN_VALID_TIME || time_scale > MAX_VALID_TIME) {
    return;
  }

  // Calculate speeds in bytes per second.
  double delta_ibytes = (double)(net->data.ifmd_data.ifi_ibytes - ibytes_nm1) / time_scale;
  double delta_obytes = (double)(net->data.ifmd_data.ifi_obytes - obytes_nm1) / time_scale;

  // Avoid log of negative or zero values.
  double exponent_ibytes = (delta_ibytes > 0) ? log10(delta_ibytes) : 0;
  double exponent_obytes = (delta_obytes > 0) ? log10(delta_obytes) : 0;

  // Set units for download (incoming bytes).
  if (exponent_ibytes < 3) {
    net->down_unit = UNIT_BPS;
    net->down      = (int)delta_ibytes;
  } else if (exponent_ibytes < 6) {
    net->down_unit = UNIT_KBPS;
    net->down      = (int)(delta_ibytes / 1000.0);
  } else {  // exponent_ibytes < 9
    net->down_unit = UNIT_MBPS;
    net->down      = (int)(delta_ibytes / 1000000.0);
  }

  // Set units for upload (outgoing bytes).
  if (exponent_obytes < 3) {
    net->up_unit = UNIT_BPS;
    net->up      = (int)delta_obytes;
  } else if (exponent_obytes < 6) {
    net->up_unit = UNIT_KBPS;
    net->up      = (int)(delta_obytes / 1000.0);
  } else {  // exponent_obytes < 9
    net->up_unit = UNIT_MBPS;
    net->up      = (int)(delta_obytes / 1000000.0);
  }
}

#endif /* NETWORK_H */

//===---------------------------------------------------------------------------===//
