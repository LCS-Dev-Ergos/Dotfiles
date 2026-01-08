# ============================================================================ #
# USER.ZSH - Personal Customizations for HyDE
# ============================================================================ #
#
# This file is loaded by conf.d/hyde/shell.zsh BEFORE plugin/prompt init.
# Your overrides here WILL take effect (unlike the old terminal.zsh flow).
#
# Available options:
#   HYDE_ZSH_NO_PLUGINS=1   - Skip HyDE's OMZ loading (use lib/20-omz.zsh instead)
#   HYDE_ZSH_PROMPT=0       - Skip HyDE's prompt (use lib/30-prompt.zsh instead)
#   HYDE_ZSH_COMPINIT_CHECK - Hours between compinit regeneration (default: 24)
#
# ============================================================================ #

# ================================ OVERRIDES ================================= #

# Use custom lib/modules instead of HyDE's plugin system.
# When set to 1: lib/20-omz.zsh handles OMZ (with macOS-specific plugins)
# When set to 0: HyDE shell.zsh handles OMZ (with HyDE-specific plugins)
HYDE_ZSH_NO_PLUGINS=1

# Use custom lib/30-prompt.zsh instead of HyDE's prompt.
# When set to 0/unset: lib/30-prompt.zsh handles prompt (with transient prompt)
# When set to 1: HyDE shell.zsh handles prompt (simpler, no transient)
HYDE_ZSH_PROMPT=0

# Optimize compinit - Only regenerate every 24 hours.
HYDE_ZSH_COMPINIT_CHECK=24

# ================================= PLUGINS ================================== #

# Custom plugins to merge with HyDE defaults (only if HYDE_ZSH_NO_PLUGINS=0).
if [[ "${HYDE_ZSH_NO_PLUGINS}" != "1" ]]; then
    plugins=(
        "sudo"
    )
fi

# ================================= STARTUP ================================== #

# Display startup art/info (only in interactive shells).
if [[ $- == *i* ]]; then
    if command -v pokego >/dev/null; then
        pokego --no-title -r 1,3,6
    elif command -v pokemon-colorscripts >/dev/null; then
        pokemon-colorscripts --no-title -r 1,3,6
    elif command -v fastfetch >/dev/null; then
        # do_render is defined in shell.zsh, check if available.
        if typeset -f do_render >/dev/null 2>&1 && do_render "image"; then
            fastfetch --logo-type kitty
        elif [[ -z "${do_render+x}" ]]; then
            # do_render not yet available, use simple check.
            fastfetch 2>/dev/null || true
        fi
    fi
fi
