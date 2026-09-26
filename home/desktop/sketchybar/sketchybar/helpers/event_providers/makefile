#Version C23
C_STD = -std=c2x

# Specifies the compiler to use
CC = gcc
CFLAGS = $(C_STD) -O3 -Wall -Wextra -pedantic

all:
	$(MAKE) -C cpu_load CFLAGS="$(CFLAGS)" CC="$(CC)"
	$(MAKE) -C network_load CFLAGS="$(CFLAGS)" CC="$(CC)"
	$(MAKE) -C brew_check CFLAGS="$(CFLAGS)" CC="$(CC)"

clean:
	$(MAKE) -C cpu_load clean
	$(MAKE) -C network_load clean
	$(MAKE) -C brew_check clean

.PHONY: all clean
