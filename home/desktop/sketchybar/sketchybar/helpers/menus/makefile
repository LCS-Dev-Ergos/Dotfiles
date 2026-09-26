# If CC is not defined, use clang
CC ?= clang

# If CFLAGS is not defined, use C23 with optimizations
CFLAGS ?= -std=c2x -O3 -Wall -Wextra -pedantic

bin/menus: menus.c | bin
	$(CC) $(CFLAGS) -F/System/Library/PrivateFrameworks/ -framework Carbon -framework SkyLight $< -o $@

bin:
	mkdir -p bin

clean:
	rm -rf bin

.PHONY: clean
