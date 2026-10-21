#!/bin/bash
# =====--------------------------------------------------------------------=====
# HYDE HISTORICAL BATTERY SUSPEND
#
# Retain the former battery-only suspend helper for policy review. This script
# is not deployed or executed by the optional HyDE overlay.
# =====--------------------------------------------------------------------=====

# Conditional suspend script for hypridle.
# Suspends the system only when running on battery power (AC unplugged).

# Check if AC adapter is online (1 = plugged in, 0 = unplugged).
if [ "$(cat /sys/class/power_supply/ADP0/online)" -eq 0 ]; then
    # AC is offline (on battery), proceed with suspend.
    systemctl suspend
fi

# If AC is online (plugged in), do nothing and exit.
