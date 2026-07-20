//===---------------------------------------------------------------------------===//
/**
 * @file cpu.h
 * @brief CPU utilization statistics library for macOS.
 *
 * This header provides a lightweight, self-contained C library for monitoring
 * CPU load on macOS. It reads host CPU statistics via Mach kernel interfaces
 * to compute user, system, and total load percentages.
 *
 * Key features:
 *  - Zero external dependencies (uses only macOS Mach APIs)
 *  - Delta-based CPU tick calculation for accurate load percentages
 *  - Safe division with zero-delta guards
 *  - Minimal memory footprint with stack-allocated structures
 *
 * Typical usage:
 *  1. Initialize with cpu_init()
 *  2. Periodically call cpu_update() to refresh statistics
 *  3. Access results via the cpu structure fields (user_load, sys_load, total_load)
 *
 * @note Designed for use in minimal environments like status bar applications.
 *
 * @author LCS.Dev
 * @date 2025-01-10
 */
 //===---------------------------------------------------------------------------===//

#ifndef CPU_H
#define CPU_H

#include <mach/mach.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>

//===-------------------------- MAIN DATA STRUCTURES ---------------------------===//

/**
 * @struct cpu
 * @brief Holds the state of CPU load monitoring.
 *
 * This structure tracks the Mach host port, raw CPU tick data from the kernel,
 * the previous sample for delta calculation, and the computed load percentages.
 */
struct cpu {
  host_t                    host;           /**< Mach host port for querying statistics. */
  mach_msg_type_number_t    count;          /**< Expected count of CPU load info elements. */
  host_cpu_load_info_data_t load;           /**< Current raw CPU tick counters from the kernel. */
  host_cpu_load_info_data_t prev_load;      /**< Previous raw CPU tick counters for delta calculation. */
  bool                      has_prev_load;  /**< True if prev_load contains valid data. */

  int user_load;   /**< Computed user-space CPU load percentage [0, 100]. */
  int sys_load;    /**< Computed system/kernel CPU load percentage [0, 100]. */
  int total_load;  /**< Computed total CPU load percentage (user + system) [0, 100]. */
};

/**
 * @brief Initializes a cpu structure.
 *
 * Acquires the Mach host self port, sets the expected info count, and zeroes
 * all load fields. The structure is prepared for its first call to cpu_update().
 *
 * @param cpu Pointer to the cpu structure to initialize.
 */
static inline void cpu_init(struct cpu* cpu) {
  if (!cpu) return;

  cpu->host          = mach_host_self();
  cpu->count         = HOST_CPU_LOAD_INFO_COUNT;
  cpu->has_prev_load = false;

  // Explicitly initialize load values to zero.
  cpu->user_load  = 0;
  cpu->sys_load   = 0;
  cpu->total_load = 0;
}

/**
 * @brief Updates CPU statistics and recomputes load percentages.
 *
 * Queries the Mach kernel for current CPU tick counters, computes the delta
 * against the previous sample, and derives user, system, and total load
 * percentages. On the first call, only the baseline is captured.
 *
 * @param cpu Pointer to the cpu structure to update.
 *
 * @note If the kernel query fails, the function logs to stderr and returns
 *       without modifying load values.
 * @warning The caller must ensure cpu_init() was called before the first update.
 */
static inline void cpu_update(struct cpu* cpu) {
  if (!cpu) return;

  kern_return_t error =
      host_statistics(cpu->host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu->load, &cpu->count);

  if (error != KERN_SUCCESS) {
    fprintf(stderr, "Error: Could not read cpu host statistics.\n");
    return;
  }

  if (cpu->has_prev_load) {
    uint32_t delta_user =
        cpu->load.cpu_ticks[CPU_STATE_USER] - cpu->prev_load.cpu_ticks[CPU_STATE_USER];

    uint32_t delta_system =
        cpu->load.cpu_ticks[CPU_STATE_SYSTEM] - cpu->prev_load.cpu_ticks[CPU_STATE_SYSTEM];

    uint32_t delta_idle =
        cpu->load.cpu_ticks[CPU_STATE_IDLE] - cpu->prev_load.cpu_ticks[CPU_STATE_IDLE];

    // Calculate the total delta to avoid division by zero.
    uint32_t delta_total = delta_system + delta_user + delta_idle;

    if (delta_total > 0) {
      // Safely convert to double before division.
      cpu->user_load  = (int)(((double)delta_user / (double)delta_total) * 100.0);
      cpu->sys_load   = (int)(((double)delta_system / (double)delta_total) * 100.0);
      cpu->total_load = cpu->user_load + cpu->sys_load;
    } else {
      // Avoid division by zero.
      cpu->user_load  = 0;
      cpu->sys_load   = 0;
      cpu->total_load = 0;
    }
  }

  cpu->prev_load     = cpu->load;
  cpu->has_prev_load = true;
}

#endif /* CPU_H */

//===---------------------------------------------------------------------------===//
