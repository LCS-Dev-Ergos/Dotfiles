# Kitty Terminal Configuration Guide

This is an optimized Kitty terminal configuration with advanced features, professional documentation, and modern performance tuning.

## Table of Contents

- [Overview](#overview)
- [Performance Optimizations](#performance-optimizations)
- [Visual Appearance](#visual-appearance)
- [Window Management](#window-management)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Advanced Features](#advanced-features)
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
- **Nerd Fonts Support**: Full icon and symbol support

#### Color Scheme

**Active Theme**: Tokyo Night Storm

- Background: `#1a1b26`
- Foreground: `#a9b1d6`
- Cursor: `#c0caf5`
- Selection: `#28344a`

**Alternative Theme**: Gruvbox Material (commented out)

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

#### Layout Management

| Shortcut          | Action                                        |
| ----------------- | --------------------------------------------- |
| `Cmd+Shift+L`     | Cycle through available layouts               |
| `Cmd+Shift+Enter` | Toggle stack layout (maximize current window) |
| `Ctrl+Shift+L`    | Next layout (alternative binding)             |

---

### Keyboard Shortcuts

#### Tabs and Windows

| Shortcut                | Action                       |
| ----------------------- | ---------------------------- |
| `Cmd+T`                 | New tab in current directory |
| `Cmd+N`                 | New OS window                |
| `Ctrl+Shift+T`          | New tab                      |
| `Ctrl+Shift+Q`          | Close current tab            |
| `Ctrl+Shift+Right/Left` | Navigate between tabs        |
| `Ctrl+Shift+./,`        | Move tab forward/backward    |

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

**Last Updated**: 2025-12-02
**Author**: LCS.Dev
**Optimized by**: Claude (Anthropic)
