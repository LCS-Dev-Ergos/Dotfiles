# =====------------------------------------------------------------------===== #
# ++++++++++++++++++++++++++++++ KITTY TAB BAR +++++++++++++++++++++++++++++++ #
# =====------------------------------------------------------------------===== #
#
# Custom tab bar for `tab_bar_style custom`. The layout, left to right:
#
#   badge   the current session (or host), replaced by the keyboard mode while
#           one is active, so the ctrl+shift+a prefix is always visible
#   tabs    index, an icon for the foreground process, the title, and markers
#           for bell, failed command, activity, progress, zoom and window
#           count; the active tab is a rounded pill in the theme's tab colors
#   status  active layout, load, free disk, battery and a memory pill (date
#           and clock can be switched back on), dropped from the least useful
#           end when the bar gets narrow
#
# Every color comes from the loaded theme (tab colors plus the 16 ANSI slots),
# so switching the theme (or `kitten @ set-colors`) restyles the bar as well.
#
# =====------------------------------------------------------------------===== #

import os
import re
import socket
import subprocess
import time
from typing import NamedTuple

from kitty.boss import get_boss
from kitty.constants import is_macos
from kitty.fast_data_types import Screen, add_timer, get_options, remove_timer, wcswidth
from kitty.rgb import alpha_blend
from kitty.session import most_recent_session
from kitty.tab_bar import DrawData, ExtraData, TabAccessor, TabBarData, as_rgb
from kitty.utils import color_as_int

if is_macos:
    from kitty.fast_data_types import cocoa_is_secure_input_enabled
else:

    def cocoa_is_secure_input_enabled() -> bool:
        return False


# =====----- Glyphs -----------------------------------------------------===== #

# Nerd Font codepoints by glyph name. They are spelled with chr() so the
# source reads the same in any font and no formatter rewrites them.
CAP_LEFT = chr(0xE0B6)  # pl-left_half_circle_thick
CAP_RIGHT = chr(0xE0B4)  # pl-right_half_circle_thick

ICON_SESSION = chr(0xF0328)  # md-layers
ICON_HOST = chr(0xF018D)  # md-console
ICON_MODE = chr(0xF030C)  # md-keyboard
ICON_BELL = chr(0xF009E)  # md-bell_ring
ICON_ACTIVITY = chr(0xF444)  # oct-dot_fill
ICON_ZOOM = chr(0xF0293)  # md-fullscreen
ICON_PROGRESS = chr(0xF0996)  # md-progress_clock
ICON_SECURE = chr(0xF023)  # fa-lock
ICON_FAILED = chr(0xF0159)  # md-close_circle
ICON_LAYOUT = chr(0xF0574)  # md-view_quilt
ICON_DATE = chr(0xF00ED)  # md-calendar
ICON_CLOCK = chr(0xF0150)  # md-clock_outline
ICON_MEMORY = chr(0xF035B)  # md-memory
ICON_LOAD = chr(0xF04C5)  # md-speedometer
ICON_DISK = chr(0xF02CA)  # md-harddisk
ICON_PROCESS = chr(0xF0C8B)  # md-application_brackets
ICON_SHELL = chr(0xF120)  # fa-terminal

# md-battery_10 ... md-battery_90, then md-battery for a full charge.
ICON_BATTERY_LEVELS = tuple(chr(c) for c in (*range(0xF007A, 0xF0083), 0xF0079))
ICON_BATTERY_CHARGING = chr(0xF0084)  # md-battery_charging
ICON_BATTERY_LOW = chr(0xF0083)  # md-battery_alert

# Foreground process -> icon. Names are normalized first (basename, lower
# case, trailing version stripped), so python3.13 and python both match.
_ICON_GROUPS = {
    chr(0xF36F): "nvim",  # linux-neovim
    chr(0xE62B): "vim vi",  # custom-vim
    chr(0xE702): "git lazygit tig gitui gh",  # dev-git
    chr(0xE73C): "python ipython uv pytest poetry pip",  # dev-python
    chr(0xE7A8): "cargo rustc rustup bacon",  # dev-rust
    chr(0xE718): "node npm npx pnpm yarn bun deno",  # dev-nodejs_small
    chr(0xE738): "java gradle mvn sbt scala",  # dev-java
    chr(
        0xF085
    ): "make cmake ninja meson clang gcc g++ clang++ cc c++ ccache",  # fa-gears
    chr(0xF08C0): "ssh mosh sshpass",  # md-ssh
    chr(0xF308): "docker podman lazydocker orb",  # linux-docker
    chr(0xF0A07): "htop btop btm top bottom glances",  # md-monitor_dashboard
    chr(0xF02D): "man less more bat tldr",  # fa-book
    chr(0xF07C): "yazi nnn ranger lf",  # fa-folder_open
    chr(0xF06A9): "claude codex gemini aider opencode",  # md-robot
    chr(0xF0574): "tmux herdr zellij",  # md-view_quilt
    ICON_SHELL: "zsh bash fish sh dash nu",
}
PROCESS_ICONS = {
    name: icon for icon, names in _ICON_GROUPS.items() for name in names.split()
}

ELLIPSIS = "…"
SEPARATOR = " │ "
SUPERSCRIPT = str.maketrans("0123456789", "⁰¹²³⁴⁵⁶⁷⁸⁹")

# Keyboard modes kitty pushes on its own get friendlier labels.
MODE_LABELS = {"__sequence__": "KEYS", "__visual_select__": "SELECT"}

# =====----- Tunables ---------------------------------------------------===== #

REFRESH_SECONDS = 1.0  # how often the status is checked; redraws only on change
BATTERY_TTL = 30.0  # seconds between battery samples
MEMORY_TTL = 5.0  # seconds between memory samples
LOAD_TTL = 5.0  # seconds between load average samples
DISK_TTL = 60.0  # seconds between free space samples
PROBE_TIMEOUT = 10.0  # seconds before a stuck probe command is killed
DISK_PATH = os.path.expanduser("~")  # the volume whose free space is shown
BADGE_MAX = 20  # cells for the session or mode label
COMPACT_BADGE_BELOW = 60  # bar width, in cells, under which the badge is icon-only
STATUS_GAP = 2  # minimum blank cells between the last tab and the status

# Status segments. Turning one off keeps its code and skips its sampling.
SHOW_LAYOUT = True
SHOW_LOAD = True
SHOW_DISK = True
SHOW_BATTERY = True
SHOW_MEMORY = True
SHOW_DATE = False
SHOW_CLOCK = False

# =====----- Palette ----------------------------------------------------===== #


class Palette(NamedTuple):
    bar: int
    text: int
    muted: int
    surface: int
    session: int
    mode: int
    on_accent: int
    info: int
    ok: int
    warn: int
    error: int


def _palette(draw_data: DrawData) -> Palette:
    # draw_data carries the tab colors after any `kitten @ set-colors` or
    # automatic theme switch; the ANSI slots come from the live options.
    opts = get_options()
    bar = draw_data.default_bg
    text = draw_data.inactive_fg

    def rgb(color) -> int:
        return as_rgb(color_as_int(color))

    return Palette(
        bar=rgb(bar),
        text=rgb(text),
        muted=rgb(alpha_blend(text, bar, 0.55)),
        surface=rgb(alpha_blend(opts.foreground, bar, 0.14)),
        session=rgb(opts.color5),
        mode=rgb(opts.color3),
        on_accent=rgb(draw_data.active_fg),
        info=rgb(opts.color6),
        ok=rgb(opts.color2),
        warn=rgb(opts.color3),
        error=rgb(opts.color1),
    )


# =====----- Text helpers -----------------------------------------------===== #


def _width(text: str) -> int:
    return max(0, wcswidth(text))


def _take(chars, room: int) -> str:
    out, used = [], 0
    for ch in chars:
        used += _width(ch)
        if used > room:
            break
        out.append(ch)
    return "".join(out)


def _abbreviate_path(path: str) -> str:
    """Fish-style: every directory but the last shrinks to its first letter."""
    parts = path.split("/")
    dirs = [p[:2] if p.startswith(".") else p[:1] for p in parts[:-1]]
    return "/".join([*dirs, parts[-1]])


def _fit(text: str, room: int) -> str:
    """Shorten text to room cells.

    A bare path (the shell integration title at a prompt) abbreviates its
    directories, ~/Dotfiles/home/kitty becoming ~/D/h/kitty, then falls back to
    just its last component. A path inside a longer title loses its middle, and
    everything else its end.
    """
    if _width(text) <= room:
        return text
    if room < 2:
        return ELLIPSIS[:room]
    if "/" in text and " " not in text:
        short = _abbreviate_path(text)
        if _width(short) <= room:
            return short
        last = ELLIPSIS + "/" + text.rstrip("/").rsplit("/", 1)[-1]
        return last if _width(last) <= room else _take(last, room - 1) + ELLIPSIS
    if "/" in text and room >= 5:
        # Both ends of a path carry meaning: where it lives and what it is.
        tail_room = (room - 1) // 2
        tail = _take(reversed(text), tail_room)[::-1]
        return _take(text, room - 1 - _width(tail)) + ELLIPSIS + tail
    return _take(text, room - 1) + ELLIPSIS


def _process_icon(live_tab) -> str:
    exe = live_tab.get_exe_of_active_window() if live_tab else ""
    name = os.path.basename(exe or "").lstrip("-").lower()
    name = re.sub(r"[\d.]+$", "", name) or name
    return PROCESS_ICONS.get(name, ICON_PROCESS if name else ICON_SHELL)


def _draw(screen: Screen, text: str, fg: int, bg: int, bold: bool = False) -> None:
    screen.cursor.fg = fg
    screen.cursor.bg = bg
    screen.cursor.bold = bold
    screen.draw(text)


def _draw_pill(
    screen: Screen, text: str, fg: int, bg: int, bar: int, bold: bool = True
) -> None:
    _draw(screen, CAP_LEFT, bg, bar)
    _draw(screen, text, fg, bg, bold)
    _draw(screen, CAP_RIGHT, bg, bar)


# =====----- Badge ------------------------------------------------------===== #

_hostname = ""


def _badge(os_window_id: int) -> tuple[str, str, str]:
    """Return (icon, label, kind) for the badge; kind is mode, session,
    recent or host."""
    global _hostname
    boss = get_boss()
    mode = boss.mappings.current_keyboard_mode_name
    if mode:
        return ICON_MODE, MODE_LABELS.get(mode) or mode.upper(), "mode"
    # Same rule kitty uses for the active session: the focused window's
    # session, else the one its tab was created in.
    tm = boss.os_window_map.get(os_window_id)
    tab = tm.active_tab if tm else None
    window = tab.active_window if tab else None
    session = (window.created_in_session_name if window else "") or (
        tab.created_in_session_name if tab else ""
    )
    if session:
        return ICON_SESSION, session, "session"
    # A tab outside any session (a plain new_tab, the startup tab) still shows
    # under `tab_bar_filter session:~`; name the session it is listed with.
    recent = most_recent_session()
    if recent:
        return ICON_SESSION, recent, "recent"
    if not _hostname:
        _hostname = socket.gethostname().split(".")[0] or "kitty"
    return ICON_HOST, _hostname, "host"


def _draw_badge(screen: Screen, draw_data: DrawData, pal: Palette) -> None:
    icon, label, kind = _badge(draw_data.os_window_id)
    # The badge sits inside tab 1's share of the bar, and that share shrinks
    # whenever another tab is active. Sizing it from the whole bar instead
    # keeps the name steady across tab switches; only a narrow bar drops it.
    text = (
        icon
        if screen.columns < COMPACT_BADGE_BELOW
        else f"{icon} {_fit(label, BADGE_MAX)}"
    )
    _draw(screen, " ", pal.bar, pal.bar)
    if kind == "recent":
        # Dimmed: this tab is not part of the session, only listed with it.
        _draw_pill(screen, text, pal.session, pal.surface, pal.bar)
    else:
        bg = pal.mode if kind == "mode" else pal.session
        _draw_pill(screen, text, pal.on_accent, bg, pal.bar)
    _draw(screen, " ", pal.bar, pal.bar)


# =====----- Tabs -------------------------------------------------------===== #


def _markers(tab: TabBarData, live_tab, pal: Palette) -> list[tuple[str, int]]:
    """Per-tab state glyphs, most urgent first, each with its inactive color."""
    markers = []
    if tab.needs_attention:
        markers.append((ICON_BELL, pal.error))
    window = live_tab.active_window if live_tab and not tab.is_active else None
    # Shell integration records each command's exit status. Flag a failure in
    # a tab you are not looking at; 130 is a ctrl+c, which you did yourself.
    if window is not None and window.last_cmd_exit_status not in (0, 130):
        markers.append((ICON_FAILED, pal.error))
    if tab.has_activity_since_last_focus and not tab.is_active:
        markers.append((ICON_ACTIVITY, pal.warn))
    if tab.num_of_windows_with_progress:
        progress = TabAccessor(tab.tab_id).progress_percent.strip()
        if progress:
            markers.append((f"{ICON_PROGRESS} {progress}", pal.info))
    if tab.is_active and cocoa_is_secure_input_enabled():
        markers.append((ICON_SECURE, pal.error))
    if tab.num_windows > 1 and tab.layout_name == "stack":
        # Only one window is visible; say so, or the others are easy to forget.
        markers.append((ICON_ZOOM, pal.info))
    return markers


def _draw_tab_body(
    draw_data: DrawData,
    screen: Screen,
    tab: TabBarData,
    room: int,
    index: int,
    pal: Palette,
) -> None:
    active = tab.is_active
    bg = as_rgb(draw_data.tab_bg(tab)) if active else pal.bar
    fg = as_rgb(draw_data.tab_fg(tab))
    muted = fg if active else pal.muted
    # Inactive tabs keep blank cells where the caps go, so a tab does not
    # shift its neighbours when it becomes active.
    cap_left, cap_right = (CAP_LEFT, CAP_RIGHT) if active else (" ", " ")

    if tab.tab_id < 0:
        # The synthetic "+" drop target kitty adds while a window is dragged.
        _draw(screen, cap_left, bg, pal.bar)
        _draw(screen, tab.title, fg, bg, active)
        _draw(screen, cap_right, bg, pal.bar)
        return

    live_tab = get_boss().tab_for_id(tab.tab_id)
    number = str(index)
    icon = _process_icon(live_tab)
    markers = _markers(tab, live_tab, pal)
    windows = str(tab.num_windows).translate(SUPERSCRIPT) if tab.num_windows > 1 else ""

    # Cells besides the title: caps, "N icon", the window count, and a space
    # before the title and before each marker.
    fixed = 2 + len(number) + 1 + _width(icon) + _width(windows)
    fixed += sum(1 + _width(text) for text, _ in markers)
    title_room = room - fixed - 1
    if draw_data.max_tab_title_length > 0:
        title_room = min(title_room, draw_data.max_tab_title_length)
    title = _fit(tab.title, title_room) if title_room >= 3 else ""
    if not title:
        # Too narrow for a title: keep the index and the most urgent marker.
        markers, windows = markers[:1], ""

    _draw(screen, cap_left, bg, pal.bar)
    _draw(screen, f"{number} ", muted, bg, active)
    _draw(screen, icon, fg, bg, active)
    if title:
        _draw(screen, f" {title}", fg, bg, active)
    if windows:
        _draw(screen, windows, muted, bg, active)
    for text, color in markers:
        _draw(screen, f" {text}", fg if active else color, bg, active)
    _draw(screen, cap_right, bg, pal.bar)


# =====----- Samplers ---------------------------------------------------===== #


class Sampler:
    """The latest result of a probe, refreshed at most every ttl seconds.

    A probe reads its answer directly, or, given a command, parses that
    command's output. The command runs in the background and is only polled
    here, so drawing never waits for it. A thread is no alternative: kitty's
    Python threads get little time between events, and one waiting on a probe
    can stall for seconds. A segment stays hidden until its first result.
    """

    def __init__(self, probe, ttl: float, command: list[str] | None = None) -> None:
        self._probe = probe
        self._ttl = ttl
        self._command = command
        self._process = None
        self._taken = float("-inf")
        self.value = None

    def get(self):
        now = time.monotonic()
        if self._process is not None:
            if self._process.poll() is not None:
                output = self._process.communicate()[0]
                self._process = None
                self._update(self._probe, output)
            elif now - self._taken > PROBE_TIMEOUT:
                self._process.kill()
        elif now - self._taken >= self._ttl:
            self._taken = now
            if self._command is None:
                self._update(self._probe)
            else:
                try:
                    self._process = subprocess.Popen(
                        self._command,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        text=True,
                    )
                except OSError:
                    self.value = None
        return self.value

    def _update(self, probe, *args) -> None:
        try:
            self.value = probe(*args)
        except Exception:  # noqa: BLE001
            # A failing probe only hides its segment; the bar must keep drawing.
            self.value = None


def _size(num_bytes: float) -> str:
    gib = num_bytes / 2**30
    if gib >= 1000:
        return f"{gib / 1024:.1f}T"
    return f"{gib:.1f}G" if gib < 100 else f"{gib:.0f}G"


def _parse_macos_memory(output: str) -> tuple[str, int]:
    # vm_stat's report, then sysctl's hw.memsize and pressure level.
    *vm_stat, total, pressure = output.splitlines()
    vm_stat = "\n".join(vm_stat)
    page = int(re.search(r"page size of (\d+) bytes", vm_stat).group(1))
    pages = {
        key.strip('"'): int(value)
        for key, value in re.findall(r"^(.+?):\s+(\d+)\.$", vm_stat, re.MULTILINE)
    }
    # Activity Monitor's "Memory Used": app memory (anonymous pages the system
    # cannot purge), wired memory, and what the compressor holds. Cached
    # files count as free, since macOS drops them as soon as it needs room.
    used = page * (
        pages["Anonymous pages"]
        - pages["Pages purgeable"]
        + pages["Pages wired down"]
        + pages["Pages occupied by compressor"]
    )
    # The kernel's own verdict (1 normal, 2 warning, 4 critical) says more than
    # a percentage: memory that is full but not under pressure is fine on macOS.
    return _memory_label(used, int(total)), {2: 1, 4: 2}.get(int(pressure), 0)


def _read_linux_memory() -> tuple[str, int]:
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, _, rest = line.partition(":")
            info[key] = int(rest.split()[0]) * 1024
    total = info["MemTotal"]
    used = total - info["MemAvailable"]
    ratio = used / total
    return _memory_label(used, total), 2 if ratio >= 0.9 else 1 if ratio >= 0.8 else 0


def _memory_label(used: int, total: int) -> str:
    return f"{_size(used)} used · {_size(total - used)} free"


def _read_load() -> tuple[str, int]:
    # The one-minute load average, judged against the number of cores.
    load = os.getloadavg()[0]
    per_core = load / (os.cpu_count() or 1)
    return f"{load:.1f}", 2 if per_core >= 1.0 else 1 if per_core >= 0.7 else 0


def _read_disk() -> tuple[str, int]:
    st = os.statvfs(DISK_PATH)
    free = st.f_bavail * st.f_frsize
    ratio = free / (st.f_blocks * st.f_frsize)
    return f"{_size(free)} free", 2 if ratio < 0.05 else 1 if ratio < 0.15 else 0


def _parse_pmset(output: str) -> tuple[int, bool] | None:
    # " -InternalBattery-0 (id=...)\t85%; charging; 1:02 remaining ..."
    match = re.search(r"InternalBattery.*?(\d+)%;\s*([^;]+)", output)
    if not match:
        return None
    state = match.group(2).strip().lower()
    on_power = "AC Power" in output or state in (
        "charging",
        "finishing charge",
        "charged",
    )
    return int(match.group(1)), on_power


def _read_sysfs_battery() -> tuple[int, bool] | None:
    base = "/sys/class/power_supply"
    try:
        names = sorted(n for n in os.listdir(base) if n.startswith("BAT"))
    except OSError:
        return None
    for name in names:
        try:
            with open(os.path.join(base, name, "capacity")) as f:
                percent = int(f.read().strip())
            with open(os.path.join(base, name, "status")) as f:
                status = f.read().strip().lower()
        except (OSError, ValueError):
            continue
        return percent, status in ("charging", "full", "not charging")
    return None


# macOS answers through vm_stat, sysctl and pmset; Linux reads /proc and /sys.
if is_macos:
    _memory = Sampler(
        _parse_macos_memory,
        MEMORY_TTL,
        [
            "/bin/sh",
            "-c",
            "/usr/bin/vm_stat && /usr/sbin/sysctl -n hw.memsize kern.memorystatus_vm_pressure_level",
        ],
    )
    _battery = Sampler(_parse_pmset, BATTERY_TTL, ["/usr/bin/pmset", "-g", "batt"])
else:
    _memory = Sampler(_read_linux_memory, MEMORY_TTL)
    _battery = Sampler(_read_sysfs_battery, BATTERY_TTL)
_load = Sampler(_read_load, LOAD_TTL)
_disk = Sampler(_read_disk, DISK_TTL)


# =====----- Status -----------------------------------------------------===== #


class Segment(NamedTuple):
    icon: str
    text: str
    icon_fg: int
    priority: int  # the lowest goes first when space runs out


def _sampled_segment(
    sampler: Sampler, icon: str, fg: int, priority: int, pal: Palette
) -> Segment | None:
    sample = sampler.get()
    if sample is None:
        return None
    text, severity = sample
    return Segment(icon, text, (fg, pal.warn, pal.error)[severity], priority)


def _battery_segment(pal: Palette) -> Segment | None:
    sample = _battery.get()
    if sample is None:
        return None
    percent, charging = sample
    if charging:
        icon, color = ICON_BATTERY_CHARGING, pal.ok
    elif percent <= 10:
        icon, color = ICON_BATTERY_LOW, pal.error
    else:
        icon = ICON_BATTERY_LEVELS[min(9, (percent - 1) // 10)]
        color = pal.error if percent <= 20 else pal.warn if percent <= 35 else pal.text
    return Segment(icon, f"{percent}%", color, 4)


def _status_segments(draw_data: DrawData, pal: Palette) -> list[Segment]:
    """The enabled segments, left to right; the last one is drawn as a pill."""
    segments = []
    if SHOW_LAYOUT:
        tm = get_boss().os_window_map.get(draw_data.os_window_id)
        tab = tm.active_tab if tm else None
        if tab is not None and len(tab) > 1:
            # The layout only matters once a tab is split.
            segments.append(Segment(ICON_LAYOUT, tab.current_layout.name, pal.info, 2))
    if SHOW_LOAD:
        segments.append(_sampled_segment(_load, ICON_LOAD, pal.info, 3, pal))
    if SHOW_DISK:
        segments.append(_sampled_segment(_disk, ICON_DISK, pal.info, 0, pal))
    if SHOW_BATTERY:
        segments.append(_battery_segment(pal))
    if SHOW_MEMORY:
        segments.append(_sampled_segment(_memory, ICON_MEMORY, pal.info, 5, pal))
    if SHOW_DATE:
        segments.append(Segment(ICON_DATE, time.strftime("%a %d %b"), pal.muted, 1))
    if SHOW_CLOCK:
        segments.append(Segment(ICON_CLOCK, time.strftime("%H:%M"), pal.text, 6))
    return [s for s in segments if s is not None]


def _status_width(segments: list[Segment]) -> int:
    # Plain segments end with a separator; the last one is a pill.
    body = sum(_width(s.icon) + 1 + _width(s.text) for s in segments)
    return body + _width(SEPARATOR) * (len(segments) - 1) + 2


def _draw_status(draw_data: DrawData, screen: Screen, pal: Palette) -> None:
    segments = _status_segments(draw_data, pal)
    # Keep the last cell free: after the last tab kitty clears from the cursor
    # to the end of the line, so anything drawn there would be erased.
    available = screen.columns - 1 - screen.cursor.x - STATUS_GAP
    while segments and _status_width(segments) > available:
        segments.remove(min(segments, key=lambda s: s.priority))
    if not segments:
        return

    start = screen.columns - 1 - _status_width(segments)
    _draw(screen, " " * (start - screen.cursor.x), pal.bar, pal.bar)
    *plain, last = segments
    for segment in plain:
        _draw(screen, segment.icon, segment.icon_fg, pal.bar)
        _draw(screen, f" {segment.text}", pal.text, pal.bar)
        _draw(screen, SEPARATOR, pal.muted, pal.bar)
    _draw(screen, CAP_LEFT, pal.surface, pal.bar)
    _draw(screen, last.icon, last.icon_fg, pal.surface)
    _draw(screen, f" {last.text}", pal.text, pal.surface, bold=True)
    _draw(screen, CAP_RIGHT, pal.surface, pal.bar)


# =====----- Refresh ----------------------------------------------------===== #

# A fresh token on every (re)load, so a config reload replaces the timer the
# previous copy of this module started instead of stacking a second one.
_MODULE_TOKEN = object()
_last_signature = None


def _tick(timer_id: int | None) -> None:
    # Everything the status shows that can change without kitty noticing:
    # the samples, the minute when a date or clock is shown, and the macOS
    # secure input state. Disabled segments are not sampled at all.
    global _last_signature
    samplers = (
        (SHOW_LOAD, _load),
        (SHOW_DISK, _disk),
        (SHOW_BATTERY, _battery),
        (SHOW_MEMORY, _memory),
    )
    signature = (
        *(sampler.get() for shown, sampler in samplers if shown),
        time.strftime("%Y%m%d%H%M") if SHOW_DATE or SHOW_CLOCK else None,
        cocoa_is_secure_input_enabled(),
    )
    if signature != _last_signature:
        _last_signature = signature
        for tm in get_boss().all_tab_managers:
            tm.mark_tab_bar_dirty()


def _ensure_timer() -> None:
    boss = get_boss()
    owner, timer_id = getattr(boss, "_dotfiles_tab_bar_timer", (None, None))
    if owner is _MODULE_TOKEN:
        return
    if timer_id is not None:
        remove_timer(timer_id)
    boss._dotfiles_tab_bar_timer = (
        _MODULE_TOKEN,
        add_timer(_tick, REFRESH_SECONDS, True),
    )


# =====----- Entry point ------------------------------------------------===== #


def draw_tab(
    draw_data: DrawData,
    screen: Screen,
    tab: TabBarData,
    before: int,
    max_tab_length: int,
    index: int,
    is_last: bool,
    extra_data: ExtraData,
) -> int:
    _ensure_timer()
    pal = _palette(draw_data)
    # Vertical tab bars call this once per row with is_last always set, so the
    # badge and the status belong to the horizontal bar only.
    horizontal = draw_data.tab_bar_edge in ("top", "bottom")

    if horizontal and index == 1:
        _draw_badge(screen, draw_data, pal)
    room = max_tab_length - (screen.cursor.x - before)
    _draw_tab_body(draw_data, screen, tab, room, index, pal)
    end = screen.cursor.x

    # kitty first calls draw_tab only to measure each tab (for_layout). The
    # status is drawn on the real pass, and the returned end excludes it, so
    # clicking the status does not select the last tab.
    if horizontal and is_last and not extra_data.for_layout:
        _draw_status(draw_data, screen, pal)
    screen.cursor.bold = False
    return end


# =====------------------------------------------------------------------===== #
# End of tab_bar.py
