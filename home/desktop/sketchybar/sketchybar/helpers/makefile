# If CC is not defined, use clang
CC ?= clang

# If CFLAGS is not defined, use C23 with optimizations
CFLAGS ?= -std=c2x -O3 -Wall -Wextra -pedantic

all:
	@if [ ! -d menus ]; then \
		echo "Error: directory 'menus' not found"; \
		exit 1; \
	fi
	(cd menus && $(MAKE) CC="$(CC)" CFLAGS="$(CFLAGS)")

clean:
	@if [ -d menus ]; then \
		(cd menus && $(MAKE) clean); \
	fi

.PHONY: all clean
