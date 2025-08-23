# .zprofile - Executed only for login shells. Sets up basic environment.

# ------- Export Fundamental Variables -------- #
# Lets .zshrc know this file has already been executed.
export ZPROFILE_HAS_RUN=true

# Default editor.
export EDITOR="nvim"
export VISUAL="$EDITOR"

# Language and localization settings.
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# History file.
export HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history

# History size in memory.
export HISTSIZE=10000

# History size on disk.
export SAVEHIST=50000

# Do not save duplicate entries in history.
setopt HIST_IGNORE_DUPS

# Do not save commands starting with a space.
setopt HIST_IGNORE_SPACE

# Share history between all sessions.
setopt SHARE_HISTORY

# Append to history file instead of overwriting.
setopt APPEND_HISTORY

# Expire duplicate entries first when trimming history.
setopt HIST_EXPIRE_DUPS_FIRST

# Do not record function definitions in history.
setopt HIST_NO_FUNCTIONS

# Do not record history for certain commands.
export HISTORY_IGNORE='ls:l:ll:bg:fg:history:clear:c'

# Less pager options.
export LESS="-R"

# --------- XDG Base Directory Setup ---------- #
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

# ------------ Initial PATH Setup ------------- #
# Adds standard user paths. Final PATH order handled by ".zshrc".
export PATH="$HOME/.local/bin:$PATH"

# --------------- Coursier PATH --------------- #
# Add Coursier bin to PATH, handling platform-specific paths.
if [[ "$OSTYPE" == "darwin"* ]]; then
    export PATH="$PATH:$HOME/Library/Application Support/Coursier/bin"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    export PATH="$PATH:$HOME/.local/share/coursier/bin"
fi

# NOTE: No need to source ~/.zshrc from here.
