# Kitty Terminal Configuration Guide

This is an optimized Kitty terminal configuration with advanced features, professional documentation, and modern performance tuning.

## Table of Contents

- [Overview](#overview)
- [Performance Optimizations](#performance-optimizations)
- [Visual Appearance](#visual-appearance)
- [Window Management](#window-management)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Advanced Features](#advanced-features)
- [Sessions](#sessions)
- [Shell Integration](#shell-integration)
- [Troubleshooting](#troubleshooting)

---

### Overview

This configuration provides:

- **High Performance**: Optimized repaint and input delays for smooth operation
- **Modern UI**: Semi-transparent background with native macOS rounded corners
- **Advanced Layouts**: 7 window layouts, splits by default
- **Powerful Hints**: URL, path, and text extraction with visual hints
- **Remote Control**: Live configuration reload without restart
- **Shell Integration**: Custom functions and aliases for enhanced workflow

---

### Performance Optimizations

#### Frame Rate and Responsiveness

```conf
repaint_delay 8         # ~125 FPS rendering
input_delay 1           # Minimal input latency
sync_to_monitor yes     # Prevents screen tearing
```

#### Terminal Capabilities

- **True Color Support**: 24-bit RGB colors
- **CSI U Key Encoding**: Enhanced keyboard protocol
- **Image Scaling**: Native support for inline images
- **Kitty Graphics Protocol**: Advanced graphics rendering

---

### Visual Appearance

#### Typography

- **Font Family**: CaskaydiaCove Nerd Font Mono
- **Font Size**: 14.5pt
- **Nerd Fonts Support**: Mappings are per-platform (`platform/macos.conf` | `platform/linux.conf`), so Linux can keep them disabled when the fonts aren’t installed.

#### Color Scheme

**Active Theme**: Tokyo Night Storm (`themes/tokyo-night.conf`; enable via `include ./themes/…` in `kitty.conf`)

- Background: `#1a1b26`
- Foreground: `#a9b1d6`
- Cursor: `#c0caf5`
- Selection: `#28344a`

The tab bar takes every color from the active theme; see [Custom Tab Bar](#custom-tab-bar).

**Alternative Theme**: Gruvbox (see `themes/gruvbox.conf`; switch the `include` in `kitty.conf` to use it)

#### Transparency

```conf
background_opacity 0.95          # 95% opacity
background_blur 60               # macOS blur effect
dynamic_background_opacity yes   # Adjustable at runtime
```

**Note**: Full transparency with blur requires removing the titlebar. Current configuration uses `titlebar-only` to maintain rounded corners with light transparency.

#### Window Decorations

- **Titlebar Style**: Native macOS system style
- **Rounded Corners**: Enabled via titlebar-only mode
- **Window Padding**: 16px uniform padding
- **Border Colors**: Tokyo Night theme colors

---

### Window Management

#### Available Layouts

1. **Splits** (default): split the focused window with `Cmd+D` / `Cmd+Shift+D`
2. **Tall**: Main pane on left, stack on right
3. **Fat**: Main pane on top, stack on bottom
4. **Grid**: Automatic grid arrangement
5. **Horizontal**: Side-by-side splits
6. **Vertical**: Top-bottom splits
7. **Stack**: Full-screen single window (toggle mode)

#### Window Splitting

| Shortcut      | Action                              |
| ------------- | ----------------------------------- |
| `Cmd+D`       | Split side by side (splits layout)  |
| `Cmd+Shift+D` | Split top to bottom (splits layout) |
| `Cmd+Shift+[` | Focus previous window               |
| `Cmd+Shift+]` | Focus next window                   |
| `Cmd+Shift+R` | Start interactive window resizing   |

#### Window Navigation

| Shortcut                  | Action                  |
| ------------------------- | ----------------------- |
| `Ctrl+Shift+1-9`, `0`     | Jump to window 1-10     |
| `Ctrl+Shift+]` / `[`      | Next / previous window  |
| `Ctrl+Shift+F` / `B`      | Move window forward/back |
| `` Ctrl+Shift+` ``        | Move window to the top  |

#### Layout Management

| Shortcut          | Action                                        |
| ----------------- | --------------------------------------------- |
| `Cmd+Shift+L`     | Cycle through available layouts               |
| `Cmd+Shift+Enter` | Toggle stack layout (maximize current window) |
| `Ctrl+Shift+L`    | Next layout (alternative binding)             |

---

### Keyboard Shortcuts

**Platform note**  
On Linux, shortcuts that use `Cmd` on macOS are mapped to `Super` (Windows key). Key letters stay the same; only the modifier changes. Common bindings (Ctrl/Alt/Shift) are identical across platforms.

#### Tabs and Windows

| Shortcut                | Action                       |
| ----------------------- | ---------------------------- |
| `Cmd+T`                 | New tab in current directory |
| `Cmd+N`                 | New OS window                |
| `Ctrl+Shift+T`          | New tab in current directory |
| `Ctrl+Shift+Q`          | Close current tab            |
| `Ctrl+Shift+Right/Left` | Navigate between tabs        |
| `Ctrl+Shift+./,`        | Move tab forward/backward    |

#### Tab Prefix (tmux style)

Press `Ctrl+Shift+A`, release, then one key. While kitty waits for that key the
tab bar badge turns into a yellow **PREFIX** pill. The mode ends after one
action, on any other key, on `Esc`, or after 2 seconds. `Ctrl+A` stays with
herdr and `Ctrl+Q` with tmux, so the three prefixes never collide.

| Key after the prefix | Action                                   |
| -------------------- | ---------------------------------------- |
| `1-9`, `0`           | Jump to tab 1-10                         |
| `N` / `P`            | Next / previous tab                      |
| `C`                  | New tab in the current directory         |
| `W`                  | Pick a tab from a list                   |
| `,`                  | Rename the current tab                   |
| `L`                  | Next layout                              |
| `Z` or `Enter`       | Toggle the stack layout (zoom)           |
| `S`                  | Pick a session from `sessions/`          |
| Arrows               | Focus the neighbouring window            |
| `Shift` + arrows     | Move the window in that direction        |
| `R`                  | Resize the window interactively          |
| `X`                  | Close the window (asks first)            |
| `H`                  | Scrollback in the pager                  |
| `=` / `-`            | Background opacity +5% / -5%             |
| `D`                  | Default background opacity               |

On macOS skhd captures `Ctrl+Shift+H/J/K/L` for yabai, so the prefix's `H` and
`L` are the way to reach the scrollback pager and the next layout there.

Unfinished multi-key sequences such as `Cmd+Shift+S>...` give up after 3 seconds
(`map_timeout`).

#### Text Navigation

| Shortcut         | Action                 |
| ---------------- | ---------------------- |
| `Alt+Left/Right` | Move by word           |
| `Cmd+Left/Right` | Move to line start/end |

#### Clipboard Operations

| Shortcut       | Action               |
| -------------- | -------------------- |
| `Cmd+C`        | Copy to clipboard    |
| `Cmd+V`        | Paste from clipboard |
| `Ctrl+Shift+S` | Paste from selection |
| `Shift+Insert` | Paste from selection |

#### Scrolling

| Shortcut                  | Action                   |
| ------------------------- | ------------------------ |
| `Ctrl+Shift+Up/Down`      | Scroll line by line      |
| `Ctrl+Shift+K/J`          | Scroll line (Vim-style)  |
| `Ctrl+Shift+Page Up/Down` | Scroll page by page      |
| `Ctrl+Shift+Home/End`     | Jump to top/bottom       |
| `Ctrl+Shift+H`            | Show scrollback in pager |

#### Font Size Control

| Shortcut                | Action                |
| ----------------------- | --------------------- |
| `Ctrl+Shift+Plus/Equal` | Increase font size    |
| `Ctrl+Shift+Minus`      | Decrease font size    |
| `Ctrl+Shift+Backspace`  | Reset to default size |

#### Configuration Management

| Shortcut        | Action               |
| --------------- | -------------------- |
| `Ctrl+Shift+F5` | Reload configuration |
| `Ctrl+Shift+F6` | Debug configuration  |

---

### Advanced Features

#### Opacity Control

Dynamic background opacity adjustment:

| Shortcut               | Action                               |
| ---------------------- | ------------------------------------ |
| `Cmd+Shift+A` then `M` | Increase opacity by 5% (More opaque) |
| `Cmd+Shift+A` then `L` | Decrease opacity by 5% (Less opaque) |
| `Cmd+Shift+A` then `1` | Set opacity to 100%                  |
| `Cmd+Shift+A` then `D` | Reset to default opacity             |

**Usage**: Press `Cmd+Shift+A`, release, then press the second key.

### Hints Kitten

Visual hints for extracting URLs, paths, and text:

#### Basic Hints

| Shortcut               | Action                             |
| ---------------------- | ---------------------------------- |
| `Cmd+Shift+E`          | Show all hints (URLs, paths, etc.) |
| `Cmd+Shift+P` then `F` | Show path hints                    |
| `Cmd+Shift+P` then `L` | Show line hints                    |
| `Cmd+Shift+P` then `W` | Show word hints                    |
| `Cmd+Shift+P` then `H` | Show hash hints                    |

#### Advanced Hints

| Shortcut               | Action                 |
| ---------------------- | ---------------------- |
| `Cmd+Shift+O` then `U` | Open URL in browser    |
| `Cmd+Shift+O` then `P` | Open path in editor    |
| `Cmd+Shift+O` then `L` | Copy line to clipboard |
| `Cmd+Shift+O` then `W` | Copy word to clipboard |

**Custom Alphabet**: `asdfghjklqwertyuiopzxcvbnm` (optimized for touch typing)

#### Unicode Input

| Shortcut      | Action                        |
| ------------- | ----------------------------- |
| `Cmd+Shift+U` | Open Unicode character picker |

Search for Unicode characters by name or code point.

#### File Transfer (SSH)

| Shortcut               | Action                  |
| ---------------------- | ----------------------- |
| `Cmd+Shift+F` then `S` | Transfer files over SSH |

Requires Kitty's SSH kitten to be properly configured.

#### Scrollback Search

| Shortcut      | Action                     |
| ------------- | -------------------------- |
| `Cmd+Shift+/` | Search scrollback with fzf |

**Requirement**: `fzf` must be installed (`brew install fzf`)

Opens an interactive overlay to search through scrollback history.

#### Panel Management

| Shortcut      | Action                 |
| ------------- | ---------------------- |
| `Cmd+Shift+Z` | Toggle fullscreen      |
| `Cmd+Shift+M` | Toggle window maximize |

---

### Sessions

Kitty sessions provide a native alternative to tmux for managing project workspaces. Sessions define reusable terminal layouts with predefined windows, tabs, and working directories.

#### Session Overview

Sessions are text-based configuration files (`.kitty-session`) that specify:

- Window layouts (tall, grid, stack, etc.)
- Tab organization
- Working directories
- Commands to execute on startup
- Window titles and focus

**Key Advantages over Tmux**:

- Native integration with Kitty (no external multiplexer overhead)
- Instant context switching between projects
- Visual session indicators in tab bar (Tokyo Night blue: `#7aa2f7`)
- Seamless integration with Kitty's window management
- Portable, relocatable session files

#### Available Sessions

| Session File               | Description                                        | Keymap          |
| -------------------------- | -------------------------------------------------- | --------------- |
| `dotfiles.kitty-session`   | Dotfiles management with config editing            | `Cmd+Shift+S>D` |
| `dev-python.kitty-session` | Python development with REPL, testing, virtualenvs | `Cmd+Shift+S>P` |
| `dev-java.kitty-session`   | Java development with Maven/Gradle, JUnit          | `Cmd+Shift+S>J` |
| `dev-rust.kitty-session`   | Rust development with Cargo, Clippy, benchmarks    | `Cmd+Shift+S>R` |
| `dev-cpp.kitty-session`    | C/C++ development with sanitizers, Valgrind        | `Cmd+Shift+S>C` |
| `ssh-dev.kitty-session`    | SSH remote server connections and monitoring       | `Cmd+Shift+S>H` |
| `monitoring.kitty-session` | System monitoring, logs, and service management    | `Cmd+Shift+S>M` |

#### Session Management Keybindings

**Session Switching** (prefix: `Cmd+Shift+S`):

| Shortcut               | Action                             |
| ---------------------- | ---------------------------------- |
| `Cmd+Shift+S` then `D` | Switch to Dotfiles session         |
| `Cmd+Shift+S` then `P` | Switch to Python development       |
| `Cmd+Shift+S` then `J` | Switch to Java development         |
| `Cmd+Shift+S` then `R` | Switch to Rust development         |
| `Cmd+Shift+S` then `C` | Switch to C/C++ development        |
| `Cmd+Shift+S` then `H` | Switch to SSH remote connections   |
| `Cmd+Shift+S` then `M` | Switch to Monitoring session       |
| `Cmd+Shift+S` then `L` | Jump to previous session (Last)    |
| `Cmd+Shift+S` then `X` | Close current session              |
| `Cmd+Shift+S` then `S` | Save current session (relocatable) |
| `Ctrl+Shift+A` then `S` | Pick any session from `sessions/`  |

**Usage**: Press `Cmd+Shift+S`, release, then press the session key.

#### Session Styling

- **Session badge**: the purple pill at the left edge of the tab bar names the
  active session. A tab outside any session shows the most recent session in a
  dimmed pill, since the filter still lists it there; the host name appears
  only before any session has been opened
- **Tab filtering**: only tabs from the current session are displayed
  (`tab_bar_filter session:~ or session:^$`)

#### Session File Locations

All session files are stored in:

```bash
~/.config/kitty/sessions/
```

#### Creating Custom Sessions

Session files use declarative syntax:

```conf
# Basic layout
layout tall
cd ~/my-project

# Create windows
launch --title "Editor" --cwd=current zsh
launch --title "Build" --cwd=current zsh
launch --title "Tests" --cwd=current zsh

# Set initial focus
focus

# Create new tab
new_tab Testing
cd ~/my-project/tests
launch --title "Test Runner" --cwd=current zsh

# Focus first tab
focus_tab 1
```

**Key directives**:

- `layout [name]` - Set window layout (tall, grid, stack, etc.)
- `cd [path]` - Change working directory
- `launch [options]` - Create new window
- `new_tab [title]` - Create new tab
- `focus` - Focus the previously created window
- `focus_tab [index]` - Set active tab (1-indexed)

#### Launching Sessions

**From keyboard**: Use the keybindings above

**From command line**:

```bash
kitty --session ~/.config/kitty/sessions/dev-python.kitty-session
```

**Automatically on startup** (in `kitty.conf`):

```conf
startup_session ~/.config/kitty/sessions/dotfiles.kitty-session
```

#### Saving Sessions

Save your current workspace as a session:

```bash
# Press Cmd+Shift+S then S
# Or use kitty @ command:
kitty @ save-as-session --use-foreground-process --relocatable ~/my-session.kitty-session
```

**Options**:

- `--relocatable` - Use relative paths for portability
- `--use-foreground-process` - Preserve running programs (requires shell integration)
- `--base-dir [path]` - Save to specific directory
- `--match [pattern]` - Filter which windows to save

#### Customizing Session Paths

Edit session files to point to your project directories:

```bash
# Edit C++ session to use your project path
cd ~/.config/kitty/sessions/
vim dev-cpp.kitty-session
```

Change the `cd` directives to your actual project locations:

```diff
- cd ~/Projects/cpp
+ cd /path/to/your/cpp/project
```

#### Session Documentation

For comprehensive session features, see:

- [Official Sessions Documentation](https://sw.kovidgoyal.net/kitty/sessions/)

---

### Shell Integration

#### Custom Functions

#### `kreload`

Reload Kitty configuration without restarting the terminal.

```bash
kreload
```

**Features**:

- Validates `KITTY_PID` environment variable
- Sends `SIGUSR1` signal for live reload
- Provides colored success/error feedback
- Works in both standalone and tmux sessions

**Output**:

```shell
✓ Kitty configuration reloaded
```

#### `kedit`

Open Kitty configuration in your default editor.

```bash
kedit
```

Uses `$EDITOR` environment variable (defaults to vim/nvim).

### Remote Control

Kitty listens on a Unix socket for remote control commands:

```bash
# List all windows
kitty @ ls

# Set background opacity
kitty @ set-background-opacity 0.9

# Create new window with split
kitty @ launch --location=vsplit

# Send text to active window
kitty @ send-text "echo Hello\n"
```

**Socket Location**: `$TMPDIR/kitty-<pid>` (exported as `$KITTY_LISTEN_ON`)

`allow_remote_control socket-only` accepts commands on that socket and refuses
control sequences printed to the terminal, so a program's output (including over
SSH) cannot drive kitty.

#### Command Notifications

`notify_on_cmd_finish invisible 15` sends a desktop notification when a command
that ran for 15 seconds or more finishes in a tab you are not looking at.

---

### Troubleshooting

#### Opacity Not Working

**Symptom**: Background opacity or blur not visible.

**Solution**: macOS requires either:

1. **Option A**: Remove titlebar completely

   ```conf
   hide_window_decorations yes
   background_opacity 0.85
   background_blur 64
   ```

2. **Option B**: Use light transparency with titlebar (current config)

   ```conf
   hide_window_decorations titlebar-only
   background_opacity 0.95
   ```

#### TERM Variable Issues in Tmux

**Symptom**: `$TERM` shows `tmux-256color` instead of `xterm-kitty`.

**Solution**: Already configured in `tmux.conf`:

```conf
set -ga update-environment 'TERM'
set -ga update-environment 'TERM_PROGRAM'
```

Reload tmux configuration: `Prefix + r` (the prefix is `Ctrl+Q`)

#### Font Icons Not Displaying

**Symptom**: Missing icons or boxes instead of symbols.

**Solution**: Install Nerd Fonts:

```bash
brew tap homebrew/cask-fonts
brew install font-caskaydia-cove-nerd-font
```

Restart Kitty after installation.

#### Hints Not Working

**Symptom**: Hints kitten shows errors or nothing happens.

**Possible Causes**:

1. Invalid regex patterns in text
2. No matching content on screen
3. Kitten not properly installed

**Solution**: Verify kitten installation:

```bash
kitty +kitten hints --help
```

#### Scrollback Search Not Working

**Symptom**: `Cmd+Shift+/` does nothing or shows error.

**Solution**: Install `fzf`:

```bash
brew install fzf
```

#### Configuration Not Reloading

**Symptom**: `kreload` command fails or shows error.

**Solution**:

1. Verify you're running in Kitty:

   ```bash
   echo $KITTY_PID
   ```

2. Check if Kitty is listening:

   ```bash
   kitty @ ls
   ```

3. Restart shell to reload functions:

   ```bash
   source ~/.zshrc
   ```

---

### Additional Resources

- **Official Documentation**: <https://sw.kovidgoyal.net/kitty/conf/>
- **Kitty Kittens**: <https://sw.kovidgoyal.net/kitty/kittens/>
- **Remote Control**: <https://sw.kovidgoyal.net/kitty/remote-control/>
- **Tokyo Night Theme**: <https://github.com/davidmathers/tokyo-night-kitty-theme>

---

### Configuration Files

- **Main Config**: `~/.config/kitty/kitty.conf`
- **Shell Aliases**: `~/.config/zsh/lib/60-aliases.zsh`
- **Tmux Integration**: `~/.config/tmux/tmux.conf`

---

## Custom Tab Bar

File: [`tab_bar.py`](tab_bar.py), loaded by `tab_bar_style custom`.

```text
 (demo)  (1 [] ~/Dotfiles²)  2 N nvim kitty.conf  3 [] cargo build² 42% []   [] tall | 4.6 | 283G free | 100% | ([] 13.3G used · 2.7G free)
```

### Layout

- **Badge**: the current session name in a purple pill, or the host name when
  no session is active. It turns into a yellow `PREFIX` pill while the tab prefix
  waits, and shows `KEYS` while a multi-key sequence is pending.
- **Tabs**: index, an icon for the foreground process (nvim, git, python,
  cargo, ssh, docker, AI agents, ...), the title, and markers. The active tab
  is a rounded pill in the theme's active tab colors; inactive tabs are plain
  text, so switching tabs never shifts the bar.
- **Markers**: bell (red), last command failed (red, inactive tabs only; a
  ctrl+c does not count), unseen activity (yellow dot), progress reported with
  OSC 9;4, macOS Secure Input (lock), zoom (stack layout hiding other windows),
  and a superscript window count.
- **Status**: the active layout (only when the tab is split), the one-minute
  load average, free space on the home volume, battery, and a memory pill
  (used and free). Load, disk and memory turn yellow or red under strain: load
  against the core count, disk below 15% and 5% free, memory by the kernel's
  pressure level on macOS and by percentage on Linux. When space runs out the
  disk goes first, then the layout, the load and the battery.
- Date and clock are still implemented but off. Each segment has a `SHOW_*`
  switch at the top of `tab_bar.py`; the last enabled one becomes the pill.

### Implementation Notes

- Colors come from the theme: tab colors plus ANSI slots 1-6, so switching the
  theme or running `kitten @ set-colors` restyles the bar too.
- Titles are shortened to `tab_title_max_length` and to the space kitty gives
  each tab. A shell's directory title shrinks fish-style (`~/D/h/kitty`, then
  `…/kitty`); other paths lose their middle, other titles their end.
- On a bar narrower than 60 cells the badge shows only its icon; otherwise
  it keeps the full name whichever tab is active.
- On macOS memory comes from `vm_stat` and `sysctl` every 5 seconds (used as
  Activity Monitor counts it: app, wired and compressed memory) and the
  battery from `pmset` every 30. These commands run in the background and are
  polled, never waited for; Linux reads `/proc/meminfo` and
  `/sys/class/power_supply` directly. Load and disk are plain system calls.
- A one-second timer redraws the bar only when a sample, the minute (while
  date or clock is shown) or the Secure Input state changes. A config reload
  replaces the timer instead of adding a second one.
- Glyph codepoints are listed by Nerd Font name at the top of the file.

---

**Last Updated**: 2026-09-25
**Author**: LCS.Dev
**Optimized by**: Claude (Anthropic)
