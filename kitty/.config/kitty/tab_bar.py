# ============================================================================ #
# ++++++++++++++++++++++++++ Kitty Tab Bar Configs +++++++++++++++++++++++++++ #
# ============================================================================ #

import datetime
import subprocess
import re
from kitty.boss import get_boss
from kitty.fast_data_types import Screen, add_timer, get_options
from kitty.utils import color_as_int
from kitty.tab_bar import (
    DrawData,
    ExtraData,
    Formatter,
    TabBarData,
    as_rgb,
    draw_attributed_string,
    draw_title,
)

# ++++++++++++++++++++++++++++++ Configuration +++++++++++++++++++++++++++++++ #

REFRESH_TIME = 1.0

# Icons.
ICON_BATTERY = ""
ICON_BATTERY_CHARGING = ""
ICON_CLOCK = ""
ICON_CALENDAR = ""
ICON_CPU = ""
ICON_WINDOW = ""
ICON_LAYOUT = ""
ICON_CUSTOM = " LCS.Dev 󰔃"

# Powerline symbols.
SEPARATOR_SYMBOL = ""
SEPARATOR_LEFT_HARD = ""
SEPARATOR_LEFT_SOFT = ""

# ++++++++++++++++++++++++++++++++++ State +++++++++++++++++++++++++++++++++++ #

timer_id = None
battery_cache = {"status": "", "time": 0}
_prev_bg = 0  # Global state for tab background continuity.

# +++++++++++++++++++++++++++++++++ Helpers ++++++++++++++++++++++++++++++++++ #

def get_battery_status():
    """Get battery status with caching."""
    now = datetime.datetime.now().timestamp()
    if now - battery_cache["time"] < 5.0 and battery_cache["status"]:
        return battery_cache["status"]

    try:
        command = ["pmset", "-g", "batt"]
        result = subprocess.run(command, capture_output=True, text=True, timeout=0.5)

        if result.returncode != 0:
            return ""

        output = result.stdout
        if "InternalBattery" not in output:
            return ""

        percent_match = re.search(r"(\d+)%", output)
        percent = int(percent_match.group(1)) if percent_match else 0

        status = "discharging"
        if "charging" in output.lower():
            status = "charging"
        elif "charged" in output.lower():
            status = "charged"
        elif "finishing charge" in output.lower():
            status = "charging"

        icon = ICON_BATTERY
        if status == "charging":
            icon = ICON_BATTERY_CHARGING

        battery_cache["status"] = (percent, status, icon)
        battery_cache["time"] = now
        return battery_cache["status"]

    except Exception:
        return ""

def _redraw_tab_bar(timer_id):
    for tm in get_boss().all_tab_managers:
        tm.mark_tab_bar_dirty()

# ++++++++++++++++++++++++++ Drawing - Right Status ++++++++++++++++++++++++++ #

def draw_right_status(draw_data: DrawData, screen: Screen) -> None:
    opts = get_options()

    # Theme Colors.
    color_bg = as_rgb(color_as_int(opts.tab_bar_background))

    # Widget Colors.
    bg_clock = as_rgb(color_as_int(opts.color16))  # Orange
    fg_clock = as_rgb(color_as_int(opts.color0))

    bg_date = as_rgb(color_as_int(opts.color8))    # Grey
    fg_date = as_rgb(color_as_int(opts.color15))   # White Text

    bg_batt = as_rgb(color_as_int(opts.color18))   # Darker Grey/Black
    fg_batt = as_rgb(color_as_int(opts.color15))

    cells = []

    # 1. Battery.
    batt_data = get_battery_status()
    if batt_data:
        percent, status, icon = batt_data
        cells.append((f"{icon} {percent}%", fg_batt, bg_batt))

    # 2. Date.
    now = datetime.datetime.now()
    date_str = now.strftime(f"{ICON_CALENDAR} %d %b")
    cells.append((date_str, fg_date, bg_date))

    # 3. Clock.
    time_str = now.strftime(f"{ICON_CLOCK} %H:%M")
    cells.append((time_str, fg_clock, bg_clock))

    # Layout Logic.
    draw_attributed_string(Formatter.reset, screen)

    while cells:
        required_width = sum(len(c[0]) + 3 for c in cells)
        if screen.cursor.x + required_width < screen.columns:
            break
        cells.pop(0)

    if not cells:
        return

    # Padding.
    current_x = screen.cursor.x
    total_width = sum(len(c[0]) + 2 for c in cells) + len(cells)
    padding = screen.columns - current_x - total_width

    if padding > 0:
        screen.cursor.bg = color_bg
        screen.draw(" " * padding)

    # Draw Cells.
    prev_bg = color_bg

    for content, fg, bg in cells:
        screen.cursor.fg = bg
        screen.cursor.bg = prev_bg
        screen.draw(SEPARATOR_SYMBOL)

        screen.cursor.fg = fg
        screen.cursor.bg = bg
        screen.draw(f" {content} ")

        prev_bg = bg

    screen.cursor.bg = 0
    screen.cursor.fg = 0

# ++++++++++++++++++++++++ Drawing - Tabs (Left Side) ++++++++++++++++++++++++ #

def draw_tab(
    draw_data: DrawData,
    screen: Screen,
    tab: TabBarData,
    before: int,
    max_title_length: int,
    index: int,
    is_last: bool,
    extra_data: ExtraData,
) -> int:
    global timer_id, _prev_bg
    if timer_id is None:
        timer_id = add_timer(_redraw_tab_bar, REFRESH_TIME, True)

    opts = get_options()

    # Colors.
    tab_bg = as_rgb(color_as_int(opts.tab_bar_background))

    # Active Tab Colors.
    active_bg = as_rgb(color_as_int(opts.color4)) # Blue
    active_fg = as_rgb(color_as_int(opts.color0)) # Dark text

    # Inactive Tab Colors.
    inactive_bg = as_rgb(color_as_int(opts.tab_bar_background))
    inactive_fg = as_rgb(color_as_int(opts.inactive_tab_foreground))

    # Custom Icon Colors.
    icon_bg = as_rgb(color_as_int(opts.color4)) # Blue
    icon_fg = as_rgb(color_as_int(opts.color0))

    # Determine current tab background.
    current_bg = active_bg if tab.is_active else inactive_bg
    current_fg = active_fg if tab.is_active else inactive_fg

    # ------------------------------------------------------------------------
    # 1) First Tab Handling (Draw Custom Icon).
    # ------------------------------------------------------------------------
    if index == 1:
        # Draw the custom icon block
        screen.cursor.bg = icon_bg
        screen.cursor.fg = icon_fg
        screen.draw(ICON_CUSTOM)

        # Initialize previous background to the icon's background
        _prev_bg = icon_bg

    # ------------------------------------------------------------------------
    # 2) Separator Logic (Previous -> Current).
    # ------------------------------------------------------------------------
    # If colors differ, use Hard Separator. If same, use Soft Separator.
    if _prev_bg != current_bg:
        screen.cursor.fg = _prev_bg
        screen.cursor.bg = current_bg
        screen.draw(SEPARATOR_LEFT_HARD)
    else:
        # Same background, use soft separator for visual break
        screen.cursor.fg = inactive_fg # Use a lighter color for the separator
        screen.cursor.bg = current_bg
        screen.draw(f" {SEPARATOR_LEFT_SOFT}")

    # ------------------------------------------------------------------------
    # 3) Tab Content.
    # ------------------------------------------------------------------------
    screen.cursor.bg = current_bg
    screen.cursor.fg = current_fg
    screen.draw(f" {index} {ICON_WINDOW} ")

    # Use native draw_title for correct truncation/rendering.
    draw_title(draw_data, screen, tab, index)
    screen.draw(" ")

    # Update global state.
    _prev_bg = current_bg

    # ------------------------------------------------------------------------
    # 4) Last Tab Handling (Current -> Bar Background).
    # ------------------------------------------------------------------------
    if is_last:
        # Always draw a hard separator to close the tab bar.
        screen.cursor.fg = current_bg
        screen.cursor.bg = tab_bg
        screen.draw(SEPARATOR_LEFT_HARD)

        # Draw the right status bar.
        draw_right_status(draw_data, screen)

    return screen.cursor.x

# ============================================================================ #
# End of tab_bar.py
