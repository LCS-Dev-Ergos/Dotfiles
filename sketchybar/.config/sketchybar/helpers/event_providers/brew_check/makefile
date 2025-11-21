# Use clang as the C compiler
CC ?= clang

# Use C23 standard with optimizations - override any external flags
CFLAGS ?= -std=c2x -O3 -Wall -Wextra -pedantic

bin/brew_check: brew_check.c brew.h ../sketchybar.h | bin
	$(CC) $(CFLAGS) $< -o $@

bin:
	mkdir -p bin

clean:
	rm -rf bin

.PHONY: clean
