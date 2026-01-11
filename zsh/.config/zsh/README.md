# Modular Zsh Configuration

---

## Overview

This directory contains the modular Zsh configuration, refactored from a monolithic 2000+ line `.zshrc` file into an organized and maintainable system.

### Structure

```path-tree
~/.config/zsh/
├── lib/                      # Core configuration modules
│   ├── 00-init.zsh           # Base configuration & platform detection
│   ├── 10-history.zsh        # History settings
│   ├── 20-omz.zsh            # Oh-My-Zsh initialization
│   ├── 30-prompt.zsh         # Prompt system (Starship/P10k/Minimal)
│   ├── 40-vi-mode.zsh        # Vi mode & keybindings
│   ├── 50-tools.zsh          # Modern tools (fzf, zoxide, yazi, atuin)
│   ├── 60-aliases.zsh        # Aliases & utility functions
│   ├── 70-ai-tools.zsh       # AI tools settings
│   ├── 75-variables.zsh      # Global variables & exports
│   ├── 80-languages.zsh      # Language managers (SDKMAN, pyenv, fnm)
│   ├── 85-completions.zsh    # Completion systems
│   ├── 90-path.zsh           # Final PATH assembly
│   ├── 95-lazy-scripts.zsh   # Lazy loader for scripts/
│   └── 96-lazy-cpp-tools.zsh # Lazy loader for cpp-tools/competitive.sh
│
├── scripts/                  # Custom user scripts (optional)
└── README.md                 # This file
```

---

### Loading Order

The numeric order of modules is **critical** for proper functionality:

1. **00-init.zsh** - Must be first: defines base variables (PLATFORM, colors)
2. **10-history.zsh** - History configuration
3. **20-omz.zsh** - Oh-My-Zsh (requires init variables)
4. **30-prompt.zsh** - Prompt system
5. **40-vi-mode.zsh** - Vi mode
6. **50-tools.zsh** - Modern tools with lazy-loading
7. **60-aliases.zsh** - Aliases and functions
8. **70-ai-tools.zsh** - AI tools settings
9. **75-variables.zsh** - Global variables
10. **80-languages.zsh** - Language managers
11. **85-completions.zsh** - Completions
12. **90-path.zsh** - Must be last among core modules: rebuilds final PATH
13. **95-lazy-scripts.zsh** - Lazy loader for `scripts/` (on-demand)
14. **96-lazy-cpp-tools.zsh** - Lazy loader for `cpp-tools/competitive.sh`

---

### Benefits of Modular Architecture

#### Maintainability

- Each file has a single responsibility (Single Responsibility Principle)
- Easy to find and modify specific configurations
- Isolated changes don't impact other modules

#### Performance

- Ability to profile individual modules
- Lazy-loading implemented where possible
- Easy to identify startup bottlenecks

#### Debugging

- Disable specific modules by commenting out the source line
- Isolated testing of functionality
- Simpler logging and troubleshooting

#### Portability

- Modules shareable across different machines
- Easy platform-specific adaptation
- Selective configuration backup

#### Version Control

- Smaller, focused commits
- More readable diffs
- More meaningful git history

---

### How to Customize

#### Modify an Existing Module

```bash
# Edit the specific module
nvim ~/.config/zsh/lib/60-aliases.zsh

# Reload configuration
source ~/.zshrc
```

#### Add Custom Scripts

Create scripts in `~/.config/zsh/scripts/`:

```bash
# Example: custom functions
cat > ~/.config/zsh/scripts/my-functions.sh << 'EOF'
#!/usr/bin/env zsh

my_custom_function() {
    echo "Custom function"
}
EOF

# Reload
source ~/.zshrc
```

**Note:** scripts in `scripts/` are lazy-loaded by default. To eager-load them
for debugging, start a shell with `ZSH_LAZY_SCRIPTS=0`. The C++ tools bundle
(`cpp-tools/competitive.sh`) is also lazy-loaded; disable that via
`ZSH_LAZY_CPP_TOOLS=0`.

Language managers (SDKMAN, pyenv, conda, rbenv, fnm) are now initialized on
first use; the first invocation of related commands may be slower.

Performance toggles:

- `ZSH_DISABLE_COMPFIX=true` skips compaudit (faster startup, less safety checks).
- `ZSH_COMPINIT_CHECK_HOURS=24` controls how often a full `compinit` runs.
- `ZSH_DEFER_FZF_GIT=1` defers `fzf-git.sh` loading until ZLE is idle.
- `ZSH_DEFER_COMPLETIONS=1` defers ng/ngrok completion generation until idle.
- `ZSH_DEFER_FABRIC=1` defers Fabric pattern loading until idle.
- `ZSH_DEFER_ORBSTACK=1` defers OrbStack shell integration until idle.
- `ZSH_LAZY_CPP_TOOLS=0` eager-loads `cpp-tools/competitive.sh`.
- `ZSH_FAST_START=1` loads only a minimal module set + basic prompt.

#### Temporarily Disable a Module

Comment out the corresponding line in the loader (`~/.zshrc`):

```zsh
# for config_module in "$ZSH_CONFIG_DIR/lib/"*.zsh(N); do
#     source "$config_module"
# done
```

Or rename the module:

```bash
mv ~/.config/zsh/lib/70-fabric.zsh ~/.config/zsh/lib/70-fabric.zsh.disabled
```

---

### Metrics

#### Before Refactoring

- Single file: `.zshrc` (2075 lines)
- Difficult maintenance
- Complex testing
- No separation of concerns

#### After Refactoring

- Main file: `.zshrc` (146 lines, -93%)
- 12 specialized modules
- Total: ~2371 lines (includes additional documentation)
- Load time: unchanged
- Maintainability: significantly improved

---

### Troubleshooting

#### Shell Won't Start

1. Use the backup configuration:

```bash
mv ~/.zshrc ~/.zshrc.broken
mv ~/.zshrc.backup-TIMESTAMP ~/.zshrc
source ~/.zshrc
```

1. Test single module:

```bash
zsh -c 'source ~/.config/zsh/lib/00-init.zsh && echo OK'
```

#### Identify the Problematic Module

```bash
for module in ~/.config/zsh/lib/*.zsh; do
    echo "Testing: $module"
    zsh -c "source $module" 2>&1 | head -5
done
```

#### Performance Issues

Profile loading times:

```bash
# Add at the beginning of each module:
# local start=$(date +%s%N)

# Add at the end:
# local end=$(date +%s%N)
# echo "Module $(basename $0): $((($end - $start) / 1000000))ms"
```

---

### Backup and Restore

#### Automatic Backup

A timestamped backup is automatically created before refactoring:

```bash
ls ~/.zshrc.backup-*
```

#### Manual Restore

```bash
# Restore most recent backup
latest_backup=$(ls -t ~/.zshrc.backup-* | head -1)
cp "$latest_backup" ~/.zshrc
source ~/.zshrc
```

---

### Best Practices

1. **Don't modify module order** without understanding dependencies
2. **Test changes** before committing
3. **Document customizations** in module comments
4. **Use `local`** for temporary variables in functions
5. **Follow existing style** for consistency

### References

- [Zsh Documentation](https://zsh.sourceforge.io/Doc/)
- [Oh-My-Zsh](https://github.com/ohmyzsh/ohmyzsh)
- [Starship Prompt](https://starship.rs/)

---

## Credits

Refactoring executed with a modular approach following these principles:

- Single Responsibility Principle
- Separation of Concerns
- Don't Repeat Yourself (DRY)
- Keep It Simple, Stupid (KISS)

---
