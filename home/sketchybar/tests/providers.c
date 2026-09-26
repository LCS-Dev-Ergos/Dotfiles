//===---------------------------------------------------------------------------===//
/**
 * @file providers.c
 * @brief Regression checks for the CPU and network event provider libraries.
 *
 * Exercises the pure computations of cpu.h and network.h, the SketchyBar
 * message tokenizer, and one real network sample on the loopback interface.
 * No message is sent to SketchyBar.
 *
 * Usage: providers
 */
//===---------------------------------------------------------------------------===//

#include <assert.h>

#include "../sketchybar/helpers/event_providers/cpu_load/cpu.h"
#include "../sketchybar/helpers/event_providers/network_load/network.h"
#include "../sketchybar/helpers/event_providers/sketchybar.h"

/**
 * @brief Builds a CPU tick sample.
 *
 * @param user   User ticks.
 * @param system System ticks.
 * @param idle   Idle ticks.
 * @param nice   Nice ticks.
 * @return The sample in the kernel's layout.
 */
static host_cpu_load_info_data_t ticks(uint32_t user, uint32_t system, uint32_t idle,
                                       uint32_t nice) {
  host_cpu_load_info_data_t sample   = {0};
  sample.cpu_ticks[CPU_STATE_USER]   = user;
  sample.cpu_ticks[CPU_STATE_SYSTEM] = system;
  sample.cpu_ticks[CPU_STATE_IDLE]   = idle;
  sample.cpu_ticks[CPU_STATE_NICE]   = nice;
  return sample;
}

/**
 * @brief Checks load percentages, including nice time and counter wrap.
 */
static void test_cpu_load(void) {
  struct cpu cpu = {0};

  host_cpu_load_info_data_t previous = ticks(100, 100, 100, 100);
  host_cpu_load_info_data_t current  = ticks(120, 110, 150, 120);
  cpu_compute_load(&cpu, &previous, &current);
  assert(cpu.user_load == 40 && cpu.sys_load == 10 && cpu.total_load == 50);

  previous = ticks(UINT32_MAX - 9, 0, 0, 0);
  current  = ticks(10, 0, 80, 0);
  cpu_compute_load(&cpu, &previous, &current);
  assert(cpu.user_load == 20 && cpu.total_load == 20);

  cpu_compute_load(&cpu, &current, &current);
  assert(cpu.user_load == 0 && cpu.sys_load == 0 && cpu.total_load == 0);
}

/**
 * @brief Checks unit selection at each boundary and for negative input.
 */
static void test_network_scale(void) {
  int       value = -1;
  enum unit unit  = UNIT_MBPS;

  network_scale(-5.0, &value, &unit);
  assert(value == 0 && unit == UNIT_BPS);
  network_scale(999.0, &value, &unit);
  assert(value == 999 && unit == UNIT_BPS);
  network_scale(1000.0, &value, &unit);
  assert(value == 1 && unit == UNIT_KBPS);
  network_scale(2.5e6, &value, &unit);
  assert(value == 2 && unit == UNIT_MBPS);
}

/**
 * @brief Checks that a restarted interface counter produces no rate spike.
 *
 * Samples the loopback interface, pretends the previous sample was larger
 * than the current counters, and expects the stored rates to stay unchanged.
 */
static void test_network_counter_restart(void) {
  struct network net;
  assert(network_init(&net, "lo0") == 0);

  net.up = net.down = 7;
  net.data.ifmd_data.ifi_ibytes = UINT64_MAX;
  net.data.ifmd_data.ifi_obytes = UINT64_MAX;
  net.tv_nm1.tv_sec -= 1;
  network_update(&net);
  assert(net.up == 7 && net.down == 7);
  assert(strcmp(net.data.ifmd_name, "lo0") == 0);

  // A row that now names another interface is looked up again.
  net.row += 1;
  network_update(&net);
  assert(strcmp(net.data.ifmd_name, "lo0") == 0);

  // Expected to print a diagnostic.
  assert(network_init(&net, "an-interface-name-that-is-too-long") == -1);
}

/**
 * @brief Checks that quoted arguments survive tokenization.
 */
static void test_format_message(void) {
  char     buffer[64];
  uint32_t length = format_message("--trigger 'a b' c", buffer, sizeof(buffer));
  assert(length == 16);
  assert(strcmp(buffer, "--trigger") == 0);
  assert(strcmp(buffer + 10, "a b") == 0);
  assert(strcmp(buffer + 14, "c") == 0);
}

int main(void) {
  test_cpu_load();
  test_network_scale();
  test_network_counter_restart();
  test_format_message();
  puts("event provider libraries: PASS");
  return 0;
}

//===---------------------------------------------------------------------------===//
