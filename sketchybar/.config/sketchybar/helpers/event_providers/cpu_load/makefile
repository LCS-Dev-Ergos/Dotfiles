# If CC is not defined, use clang
CC ?= clang

# If CFLAGS is not defined, use C23 with optimizations
CFLAGS ?= -std=c2x -O3 -Wall -Wextra -pedantic

bin/cpu_load: cpu_load.c cpu.h ../sketchybar.h | bin
	$(CC) $(CFLAGS) $< -o $@

bin:
	mkdir -p bin

clean:
	rm -rf bin

.PHONY: clean
