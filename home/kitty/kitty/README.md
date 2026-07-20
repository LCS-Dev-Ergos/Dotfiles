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
- **Advanced Layouts**: 6 different window layouts for multitasking
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
- Tab Bar: `#16161e` with powerline style

**Tab Bar Styling**:

- Active tab: Bold cyan (`#7dcfff`) on elevated background (`#1f2335`)
- Inactive tabs: Lighter gray (`#787c99`) with fade effect on main background
- Tab bar background: Elevated dark (`#1f2335`) with increased margins for visibility
- Session indicator: Bright cyan (`#7dcfff`)
- Process name: Teal (`#73daca`)
- Title: Yellow-orange (`#e0af68`)
- Separator color: Blue accent (`#7aa2f7`)

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

1. **Tall**: Main pane on left, stack on right
2. **Fat**: Main pane on top, stack on bottom
3. **Grid**: Automatic grid arrangement
4. **Horizontal**: Side-by-side splits
5. **Vertical**: Top-bottom splits
6. **Stack**: Full-screen single window (toggle mode)

#### Window Splitting

| Shortcut      | Action                            |
| ------------- | --------------------------------- |
| `Cmd+D`       | Split window vertically           |
| `Cmd+Shift+D` | Split window horizontally         |
| `Cmd+Shift+[` | Focus previous window             |
| `Cmd+Shift+]` | Focus next window                 |
| `Cmd+Shift+R` | Start interactive window resizing |

#### Tmux-Style Window Navigation

Navigate between windows using `Ctrl+A` prefix (similar to tmux):

| Shortcut            | Action               |
| ------------------- | -------------------- |
| `Ctrl+A` then `1-9` | Jump to window 1-9   |
| `Ctrl+A` then `0`   | Jump to window 10    |
| `Ctrl+A` then `N`   | Next window          |
| `Ctrl+A` then `P`   | Previous window      |
| `Ctrl+A` then `C`   | Create new window    |
| `Ctrl+A` then `W`   | Close current window |

**Usage**: Press `Ctrl+A`, release, then press the window key.

**Alternative**: Use `Ctrl+Shift+1-9` for direct window access without prefix.

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
| `Ctrl+Shift+T`          | New tab                      |
| `Ctrl+Shift+Q`          | Close current tab            |
| `Ctrl+Shift+Right/Left` | Navigate between tabs        |
| `Ctrl+Shift+./,`        | Move tab forward/backward    |

#### Tmux-Style Tab Navigation

Navigate between tabs using `Ctrl+A + Shift` prefix (similar to tmux window navigation):

| Shortcut                  | Action            |
| ------------------------- | ----------------- |
| `Ctrl+A` then `Shift+1-9` | Jump to tab 1-9   |
| `Ctrl+A` then `Shift+N`   | Next tab          |
| `Ctrl+A` then `Shift+P`   | Previous tab      |
| `Ctrl+A` then `Shift+T`   | Create new tab    |
| `Ctrl+A` then `Shift+W`   | Close current tab |

**Usage**: Press `Ctrl+A`, release, then press `Shift` + key.

**Note**:

- Windows (panes): `Ctrl+A` + `1-9` (lowercase)
- Tabs: `Ctrl+A` + `Shift+1-9` (uppercase)

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

**Usage**: Press `Cmd+Shift+S`, release, then press the session key.

#### Session Styling

Sessions are visually indicated in the tab bar with Tokyo Night colors:

- **Session name**: Blue (`#7aa2f7`) prefix before tab title
- **Tab filtering**: Only tabs from current session are displayed
- **Maximum session name length**: 20 characters

Example tab title format:

```text
dotfiles 1: (nvim) kitty.conf
```

Where `dotfiles` is the session indicator in blue.

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

**Socket Location**: `unix:/tmp/kitty`

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

Reload tmux configuration: `Prefix + R` (default: `Ctrl+A` then `R`)

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

### Features

Powerline-styled tab bar with live system widgets using Tokyo Night colors:

- **Battery Status**: Shows charging icon () or standard battery icon () with percentage
- **Date Display**: Current date with calendar icon () in format "DD Mon YYYY"
- **Time Display**: Current time with clock icon () in 24-hour format

### Implementation

File: [`tab_bar.py`](tab_bar.py)

The tab bar uses:

- `draw_tab_with_powerline()` for native Kitty tab rendering
- macOS-compatible system calls (`pmset` for battery)
- Automatic cell dropping if terminal width insufficient
- 2-second refresh interval for live updates

### Widget Configuration

Toggle widgets in [`tab_bar.py`](tab_bar.py#L27-L30):

```python
SHOW_BATTERY = True  # Battery percentage and charging status
SHOW_DATE = True     # Current date
SHOW_CLOCK = True    # Current time
```

### Powerline Separators

- First widget:  (powerline separator from default bg to tab bg)
- Subsequent widgets:  (thin separator within tab bg)

### Color Scheme

Widgets use colors from `draw_data` for theme consistency:

- Background: `draw_data.inactive_bg`
- Foreground: `draw_data.inactive_fg`
- Default background: `draw_data.default_bg`

---

**Last Updated**: 2025-12-03
**Author**: LCS.Dev
**Optimized by**: Claude (Anthropic)
