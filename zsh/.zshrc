# =========================================================================== #
# +++++++++++++++++++++++++++ BASE CONFIGURATION ++++++++++++++++++++++++++++ #
# =========================================================================== #

# --------- Startup Commands -------- #
# fastfetch

# =========================================================================== #
# +++++++++++++++++++++++++++ DETECT OPERATING SYSTEM +++++++++++++++++++++++ #
# =========================================================================== #

# Detect operating system to load specific configurations
case "$(uname -s)" in
    Darwin)
        export OS_TYPE='macOS'
        ;;
    Linux)
        export OS_TYPE='Linux'
        ;;
    *)
        export OS_TYPE='Other'
        ;;
esac

# =========================================================================== #
# +++++++++++++++++++++++++++ ENVIRONMENT MANAGERS ++++++++++++++++++++++++++ #
# =========================================================================== #

# ---------------------- Nix -------------------- #
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
  . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# ------------ Homebrew / Linuxbrew ------------- #
# Search for Homebrew in standard macOS and Linux paths
if [ -x "/opt/homebrew/bin/brew" ]; then # macOS Apple Silicon
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x "/usr/local/bin/brew" ]; then # macOS Intel
  eval "$(/usr/local/bin/brew shellenv)"
elif [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then # Linux
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# OS-specific environment variables
if [[ "$OS_TYPE" == 'macOS' ]]; then
  # Force the use of system binaries to avoid conflicts.
  export LD=/usr/bin/ld
  export AR=/usr/bin/ar
  # Activate these flags if you intend to use Homebrew's LLVM
  export LDFLAGS="-L/opt/homebrew/opt/llvm/lib"
  export CPPFLAGS="-I/opt/homebrew/opt/llvm/include"
  export CPATH="/opt/homebrew/include"
fi

# Function for brew update with notification (specific to macOS with sketchybar)
if [[ "$OS_TYPE" == 'macOS' ]]; then
  function brew() {
    command brew "$@"
    if [[ $* =~ "upgrade" ]] || [[ $* =~ "update" ]] || [[ $* =~ "outdated" ]]; then
      sketchybar --trigger brew_update
    fi
  }
fi

# =========================================================================== #
# +++++++++++++++++++++ LANGUAGES AND DEVELOPMENT TOOLS +++++++++++++++++++++ #
# =========================================================================== #

# Haskell (ghcup-env)
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"

# GO Language
export GOROOT="/usr/local/go"

# FNM (Fast Node Manager)
if command -v fnm &>/dev/null; then
    eval "$(fnm env --use-on-cd --shell zsh)"
fi

# -------------- PyENV -------------- #
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# >>> Conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('$HOME/00_ENV/miniforge3/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "$HOME/00_ENV/miniforge3/etc/profile.d/conda.sh" ]; then
        . "$HOME/00_ENV/miniforge3/etc/profile.d/conda.sh"
    else
        export PATH="$HOME/00_ENV/miniforge3/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< Conda initialize <<<

# ----- Perl CPAN ----- #
eval "$(perl -I$HOME/00_ENV/perl5/lib/perl5 -Mlocal::lib=$HOME/00_ENV/perl5)"

# ----- OPAM ----- #
# This section can be safely removed at any time if needed.
[[ ! -r "$HOME/.opam/opam-init/init.zsh" ]] || source "$HOME/.opam/opam-init/init.zsh" > /dev/null 2> /dev/null 

# ------------ Java - Smart JAVA_HOME Management ------------ #

# First, prioritize SDKMAN! if it is installed.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
  # SDKMAN! found. Let it manage everything.
  export SDKMAN_DIR="$HOME/.sdkman"
  source "$HOME/.sdkman/bin/sdkman-init.sh"
else
  # SDKMAN! not found. Use the fallback logic to auto-detect Java.
  setup_java_home_fallback() {
    if [[ "$OS_TYPE" == 'macOS' ]]; then
      # On macOS, use the system-provided utility
      if [ -x "/usr/libexec/java_home" ]; then
        export JAVA_HOME=$(/usr/libexec/java_home)
        export PATH="$JAVA_HOME/bin:$PATH"
      fi
    elif [[ "$OS_TYPE" == 'Linux' ]]; then
      local found_java_home=""
      # Method 1: For Debian/Ubuntu/Fedora based systems (uses update-alternatives)
      if command -v update-alternatives &>/dev/null && command -v java &>/dev/null; then
        local java_path=$(readlink -f $(which java))
        if [[ -n "$java_path" ]]; then
          found_java_home="${java_path%/bin/java}"
        fi
      fi
      # Method 2: For Arch Linux systems (uses archlinux-java)
      if [[ -z "$found_java_home" ]] && command -v archlinux-java &>/dev/null; then
          local java_env=$(archlinux-java get)
          if [[ -n "$java_env" ]]; then
              found_java_home="/usr/lib/jvm/$java_env"
          fi
      fi
      # Method 3: Generic fallback by searching in /usr/lib/jvm
      if [[ -z "$found_java_home" ]] && [[ -d "/usr/lib/jvm" ]]; then
          found_java_home=$(find /usr/lib/jvm -maxdepth 1 -type d -name "java-*-openjdk*" | sort -V | tail -n 1)
      fi  
      # Export variables only if we found a valid path
      if [[ -n "$found_java_home" && -d "$found_java_home" ]]; then
        export JAVA_HOME="$found_java_home"
        export PATH="$JAVA_HOME/bin:$PATH"
      else
        echo "⚠️ Warning: Unable to automatically determine JAVA_HOME and SDKMAN! is not installed."
        echo "   Please install Java and/or SDKMAN!, or set JAVA_HOME manually."
      fi
    fi
  }
  # Execute the fallback function
  setup_java_home_fallback
fi

# =========================================================================== #
# ++++++++++++++++++++++ PERSONAL CONFIGURATION - THEMES ++++++++++++++++++++ #
# =========================================================================== #

# --------------------------- Terminal Variables ---------------------------- #
if [ "$TERM" = "xterm-kitty" ]; then
    export TERM=xterm-kitty
else
    export TERM=xterm-256color
fi

# Set up XDG Base Directory Specification
export XDG_CONFIG_HOME="$HOME/.config"

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load
ZSH_THEME="robbyrussell"

# Set default editor
export EDITOR="nvim"


# +++++++++++++++++++++++++++++++ OH-MY-ZSH +++++++++++++++++++++++++++++++++ #

# Would you like to use another custom folder than $ZSH/custom?
ZSH_CUSTOM=$HOME/.config/zsh

# Which plugins would you like to load?
# Note: zsh-syntax-highlighting must be the last plugin to work correctly
plugins=(
    git
    sudo
    extract
    colored-man-pages
    zsh-autosuggestions
    zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# ZSH Cache
export ZSH_COMPDUMP="$ZSH/cache/.zcompdump-$HOST"

# -------------------------------- VI-MODE ---------------------------------- #
# Enable vi mode
bindkey -v

# Reduce mode change delay (0.1 seconds)
export KEYTIMEOUT=1

# Simplified and more efficient logic to update prompt based on mode
function zle-line-init() { zle -K viins }
function zle-keymap-select() {
  case $KEYMAP in
    viins) zle-line-init ;;
    vicmd) zle reset-prompt ;;
  esac
}
zle -N zle-line-init
zle -N zle-keymap-select

# -------------------------------- PROMPT ----------------------------------- #
# Oh My Posh - Custom prompt
eval "$(oh-my-posh init zsh --config $XDG_CONFIG_HOME/oh-my-posh/lcs-dev.omp.json)"

# --------------------------------- COLORS ---------------------------------- #
# --------------- FZF --------------- #
# Set up fzf key bindings and fuzzy completion
eval "$(fzf --zsh)"

_gen_fzf_default_opts() {
# ---------- Setup FZF theme -------- #
# Scheme name: Tokyo Night

local color00='#1a1b26'  # background
local color01='#16161e'  # darker background
local color02='#2f3549'  # selection background
local color03='#414868'  # comments
local color04='#787c99'  # dark foreground
local color05='#a9b1d6'  # foreground
local color06='#c0caf5'  # light foreground
local color07='#cfc9c2'  # lighter foreground
local color08='#f7768e'  # red
local color09='#ff9e64'  # orange
local color0A='#e0af68'  # yellow
local color0B='#9ece6a'  # green
local color0C='#2ac3de'  # cyan
local color0D='#7aa2f7'  # blue
local color0E='#bb9af7'  # purple
local color0F='#cfc9c2'  # grey/white

export FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS"\
" --color=bg+:$color01,bg:$color00,spinner:$color0C,hl:$color0D"\
" --color=fg:$color04,header:$color0D,info:$color0A,pointer:$color0C"\
" --color=marker:$color0C,fg+:$color06,prompt:$color0A,hl+:$color0D"
}

_gen_fzf_default_opts

# ------ Use fd instead of fzf ------ #
export FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"

# Use fd (https://github.com/sharkdp/fd) for listing path candidates.
_fzf_compgen_path() {
  fd --hidden --exclude .git . "$1"
}

# Use fd to generate the list for directory completion
_fzf_compgen_dir() {
  fd --type=d --hidden --exclude .git . "$1"
}

source ~/.config/fzf-git/fzf-git.sh

export FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :500 {}'"
export FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"

# Advanced customization of fzf options via _fzf_comprun function
_fzf_comprun() {
  local command=$1
  shift

  case "$command" in
    cd)           fzf --preview 'eza --tree --color=always {} | head -200'   "$@" ;;
    export|unset) fzf --preview "eval 'echo $'{}"         "$@" ;;
    ssh)          fzf --preview 'dig {}'                  "$@" ;;
    *)            fzf --preview "bat -n --color=always --line-range :500 {}" "$@" ;;
  esac
}

# --------- Bat (better cat) -------- #
export BAT_THEME=tokyonight_night

# =========================================================================== #
# +++++++++++++++++++++++++++ SOURCE COMMANDS +++++++++++++++++++++++++++++++ #
# =========================================================================== #

# ------------ ngrok ---------------- #
if command -v ngrok &>/dev/null; then
    eval "$(ngrok completion)"
fi

# ----------- Angular CLI ----------- #
if command -v ng &>/dev/null; then
    source <(ng completion script)
fi

# ------- Zoxide (smarter cd) ------- #
eval "$(zoxide init zsh)"

# =========================================================================== #
# +++++++++++++++++++++++++++ GLOBAL VARIABLES ++++++++++++++++++++++++++++++ #
# =========================================================================== #

# ----------- Directories ----------- #
# LCS.Data Volume
if [[ "$OS_TYPE" == 'macOS' ]]; then
    export LCS_Data="/Volumes/LCS.Data"
    if [ ! -d "$LCS_Data" ]; then
        echo "⚠️ Warning: LCS.Data volume is not mounted"
    fi
elif [[ "$OS_TYPE" == 'Linux' ]]; then
    export LCS_Data="/media/$USER/LCS.Data"
    if [ ! -d "$LCS_Data" ]; then
        echo "⚠️ Warning: LCS.Data volume does not appear to be mounted in $LCS_Data"
    fi
fi

# Clang-Format Configuration
export CLANG_FORMAT_CONFIG="$HOME/.config/clang-format/.clang-format"

# ----- Blog ----- #
export BLOG_POSTS_DIR="$LCS_Data/Blog/CS-Topics/content/posts/"
export BLOG_STATIC_IMAGES_DIR="$LCS_Data/Blog/CS-Topics/static/images"
export IMAGES_SCRIPT_PATH="$LCS_Data/Blog/Automatic-Updates/images.py"
export OBSIDIAN_ATTACHMENTS_DIR="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images"

# =========================================================================== #
# ++++++++++++++++++++++++++++++++ ALIASES ++++++++++++++++++++++++++++++++++ #
# =========================================================================== #

# ----- Common Aliases (Cross-Platform) ----- #
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

# Eza (modern ls replacement)
alias ls="eza --color=always --long --git --icons=always"

# thefuck alias (corrects mistyped commands)
eval $(thefuck --alias)       # Creates the "fuck" alias
eval $(thefuck --alias fk)    # Creates the shorter "fk" alias

# Zoxide (smart cd replacement)
alias cd="z"

# Clang-Format alias
alias clang-format='clang-format -style=file:$CLANG_FORMAT_CONFIG'

# ----- OS-Specific Aliases ----- #
if [[ "$OS_TYPE" == 'macOS' ]]; then
  alias compile="clang++ -std=c++20 -O3 -march=native -flto=thin -ffast-math -I/usr/local/include"
  alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  alias gcc='gcc-15' # Use Homebrew's gcc
  alias lldb='/usr/bin/lldb'
elif [[ "$OS_TYPE" == 'Linux' ]]; then
  alias compile="g++ -std=c++20 -O3 -march=native -flto -ffast-math"
  alias gcc='gcc'
  alias lldb='lldb'
fi

alias c="clear"
alias ranger='TERM=screen-256color ranger'

# =========================================================================== #
# ++++++++++++++++++++++ PATH FINALIZER (RUNS LAST) +++++++++++++++++++++++++ #
# =========================================================================== #
# This function runs last to ensure correct PATH order, resolve conflicts
# (e.g., /usr/bin/ar vs homebrew) and remove duplicate entries.

fix_path_order() {
  # 1. Define the desired priority order for key directories
  #    that cause conflicts or need high priority.
  local -a desired_path_order=()

  # Build the list of desired paths based on the operating system
  if [[ "$OS_TYPE" == 'macOS' ]]; then
      desired_path_order=(
      # ----- Version Managers (shims) ----- #
      "$HOME/.pyenv/shims"
      
      # ----- Dynamic FNM directories ----- #
      "$(echo "$PATH" | tr ':' '\n' | grep 'fnm_multishells')"
      "$HOME/.sdkman/candidates/java/current/bin"
      
      # ----- System Tools ----- #
      "/usr/bin"
      "/bin"
      "/usr/sbin"
      "/sbin"

      # ----- Homebrew ----- #
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"

      # ----- Homebrew LLVM (for clang++, clang-format, etc.) ----- #
      "/opt/homebrew/opt/llvm/bin"
      
      # ----- User and App-Specific Paths (macOS) ----- #
      "$HOME/.local/bin" "/usr/local/bin"
      "$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin"
      "$HOME/.ghcup/bin" "$HOME/.cabal/bin"
      "$HOME/.cargo/bin"
      "$HOME/.ada/bin"
      "$GOPATH/bin" "$GOROOT/bin"
      "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/tools" "$ANDROID_HOME/tools/bin"
      "$HOME/00_ENV/miniforge3/condabin" "$HOME/00_ENV/miniforge3/bin"

      # ----- Other Paths ----- #
      "$HOME/.config/emacs/bin"
      "/usr/local/mysql/bin"
      "/opt/homebrew/opt/ncurses/bin"
      "/Library/TeX/texbin" "/usr/local/texlive/2025/bin/universal-darwin"
      "$HOME/Library/Application Support/JetBrains/Toolbox/scripts"
      "$HOME/.lcs-bin"
    )
    elif [[ "$OS_TYPE" == 'Linux' ]]; then
      desired_path_order=(
      # ----- Version Managers (shims) ----- #
      "$HOME/.pyenv/shims"
      "$(echo "$PATH" | tr ':' '\n' | grep 'fnm_multishells')"
      "$HOME/.sdkman/candidates/java/current/bin"
      
      # ----- System Tools ----- #
      "/usr/local/bin" "/usr/local/sbin"
      "/usr/bin" "/bin" "/usr/sbin" "/sbin"

      # ----- Linuxbrew ------ #
      "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin"

      "$HOME/.local/bin"
      # ----- User and App-Specific Paths (Linux) ----- #
      "$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin"
      "$HOME/.ghcup/bin" "$HOME/.cabal/bin" 
      "$HOME/.cargo/bin"
      "$HOME/.ada/bin"
      "$GOPATH/bin" "$GOROOT/bin"
      "$HOME/00_ENV/miniforge3/condabin" "$HOME/00_ENV/miniforge3/bin"
      "$HOME/.config/emacs/bin"
      "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/tools" "$ANDROID_HOME/tools/bin"
      "$HOME/.lcs-bin"
      )
    fi

  # Use `typeset -U` to create an array that automatically removes duplicates.
  typeset -U path_array
  path_array=()

  # Iterate over our ordered list and add only existing directories.
  for p in "${desired_path_order[@]}"; do
    if [[ -d "$p" ]]; then
      path_array+=("$p")
    fi
  done

  # Rebuild and export the final, clean, and ordered PATH.
  export PATH="${(j/:/)path_array}"
}

# Execute the function to finalize the PATH
fix_path_order
unset -f fix_path_order # Cleans the function from the environment
