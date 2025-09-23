#ifndef CPU_H
#define CPU_H

#include <mach/mach.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>

struct cpu {
  host_t                    host;
  mach_msg_type_number_t    count;
  host_cpu_load_info_data_t load;
  host_cpu_load_info_data_t prev_load;
  bool                      has_prev_load;

  int user_load;
  int sys_load;
  int total_load;
};

/**
 * Initializes a cpu structure
 *
 * @param cpu Pointer to the cpu structure to initialize
 */
static inline void cpu_init(struct cpu* cpu) {
  if (!cpu) return;

  cpu->host          = mach_host_self();
  cpu->count         = HOST_CPU_LOAD_INFO_COUNT;
  cpu->has_prev_load = false;

  // Explicitly initialize load values to zero
  cpu->user_load  = 0;
  cpu->sys_load   = 0;
  cpu->total_load = 0;
}

/**
 * Updates CPU statistics
 *
 * @param cpu Pointer to the cpu structure to update
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

    // Calculate the total delta to avoid division by zero
    uint32_t delta_total = delta_system + delta_user + delta_idle;

    if (delta_total > 0) {
      // Safely convert to double before division
      cpu->user_load  = (int)(((double)delta_user / (double)delta_total) * 100.0);
      cpu->sys_load   = (int)(((double)delta_system / (double)delta_total) * 100.0);
      cpu->total_load = cpu->user_load + cpu->sys_load;
    } else {
      // Avoid division by zero
      cpu->user_load  = 0;
      cpu->sys_load   = 0;
      cpu->total_load = 0;
    }
  }

  cpu->prev_load     = cpu->load;
  cpu->has_prev_load = true;
}

#endif /* CPU_H */
