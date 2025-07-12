# =========================================================================== #
# +++++++++++++++++++++++++++ BASE CONFIGURATION ++++++++++++++++++++++++++++ #
# =========================================================================== #

# If ZPROFILE_HAS_RUN variable doesn't exist, we're in a non-login shell
# (e.g., VS Code). Load our base configuration to ensure clean PATH setup.
if [[ -z "$ZPROFILE_HAS_RUN" ]]; then
    source "${ZDOTDIR:-$HOME}/.zprofile"
fi

# Enables the advanced features of VS Code's integrated terminal.
# Must be in .zshrc because it is run for each new interactive shell.
if [[ "$TERM_PROGRAM" == "vscode" ]]; then
    command -v code >/dev/null 2>&1 && . "$(code --locate-shell-integration-path zsh)"
fi

# =========================================================================== #
# ++++++++++++++++++++++++ EXECUTION AND OS DETECTION +++++++++++++++++++++++ #
# =========================================================================== #

# Export this variable to let .zshrc know that this file has already run.
# This is the crucial synchronization mechanism.
export ZPROFILE_HAS_RUN=true

# Detect operating system to load specific configurations
if [[ "$(uname)" == "Darwin" ]]; then
  PLATFORM="macOS"
  ARCH_LINUX=false
elif [[ "$(uname)" == "Linux" ]]; then
  PLATFORM="Linux"
  # Check if we're on Arch Linux
  if [[ -f "/etc/arch-release" ]]; then
    ARCH_LINUX=true
  else
    ARCH_LINUX=false
  fi
else
  PLATFORM="Other"
  ARCH_LINUX=false
fi

# --------------------------- Startup Commands ------------------------------ #
# Conditional startup commands based on platform
if [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Arch Linux specific startup commands
  command -v fastfetch >/dev/null 2>&1 && fastfetch
elif [[ "$PLATFORM" == "macOS" ]]; then
  # macOS specific startup command
  # command -v fastfetch >/dev/null 2>&1 && fastfetch
  true # placeholder
fi

# --------------------------- Terminal Variables ---------------------------- #
if [ "$TERM" = "xterm-kitty" ]; then
    export TERM=xterm-kitty
else
    export TERM=xterm-256color
fi

# +++++++++++++++++++++++++++++++ OH-MY-ZSH +++++++++++++++++++++++++++++++++ #

# Path to Oh-My-Zsh installation (platform specific)
if [[ "$PLATFORM" == "macOS" ]]; then
  export ZSH="$HOME/.oh-my-zsh"
elif [[ "$PLATFORM" == "Linux" ]]; then
  if [[ -d "/usr/share/oh-my-zsh" ]]; then
    export ZSH="/usr/share/oh-my-zsh"
  else
    export ZSH="$HOME/.oh-my-zsh"
  fi
fi

# Set custom directory if needed
ZSH_CUSTOM=${ZSH_CUSTOM:-$HOME/.config/zsh}

# Set name of the theme to load
ZSH_THEME=""

# Check for plugin availability on Arch Linux
if [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Make sure the ZSH_CUSTOM path is set correctly for Arch Linux
  ZSH_CUSTOM="/usr/share/oh-my-zsh/custom"
fi

# Common plugins for all platforms
# Note: zsh-syntax-highlighting must be the last plugin to work correctly
plugins=(
  git
  sudo
  extract
  colored-man-pages
)

# Platform-specific plugins
if [[ "$PLATFORM" == "macOS" ]]; then
  # macOS specific plugins
  plugins+=(
    zsh-autosuggestions
    zsh-syntax-highlighting
  )
elif [[ "$PLATFORM" == "Linux" && "$ARCH_LINUX" == true ]]; then
  # Arch Linux specific plugins
  plugins+=(
    fzf
    zsh-256color
    zsh-history-substring-search
    zsh-autosuggestions
    zsh-syntax-highlighting
  )
fi

# ZSH Cache
export ZSH_COMPDUMP="$ZSH/cache/.zcompdump-$HOST"

source $ZSH/oh-my-zsh.sh

# =========================================================================== #
# ++++++++++++++++++++++ PERSONAL CONFIGURATION - THEMES ++++++++++++++++++++ #
# =========================================================================== #

# +++++++++++++++++++++++++++ PROMPT CONFIGURATION ++++++++++++++++++++++++++ #

# Platform-specific prompt configuration
if [[ "$PLATFORM" == "macOS" ]]; then
  # macOS: Oh-My-Posh
  if command -v oh-my-posh >/dev/null 2>&1; then
    eval "$(oh-my-posh init zsh --config $XDG_CONFIG_HOME/oh-my-posh/lcs-dev.omp.json)"
  fi
elif [[ "$PLATFORM" == "Linux" ]]; then
  # Linux: PowerLevel10k with Oh-My-Posh fallback
  if [[ -f "/usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme" ]]; then
    source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme
    [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
  elif [[ -f "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme" ]]; then
    source "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme"
    [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
  elif command -v oh-my-posh >/dev/null 2>&1; then
    # Fallback to Oh-My-Posh if PowerLevel10k is not available
    eval "$(oh-my-posh init zsh --config $XDG_CONFIG_HOME/oh-my-posh/lcs-dev.omp.json)"
  fi
fi

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

# ------------------------------ COLORS & FZF ------------------------------- #
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
# ++++++++++++++++++++++++++++++++ ALIASES ++++++++++++++++++++++++++++++++++ #
# =========================================================================== #

# ------ Common Aliases (Cross-Platform) ------ #
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."
alias c="clear"
alias md='mkdir -p'

# Tools
alias ranger="TERM=screen-256color ranger"
alias clang-format="clang-format -style=file:$CLANG_FORMAT_CONFIG"
alias fnm-clean='echo "Pulizia delle sessioni fnm orfane..." &&
                 rm -rf ~/.local/state/fnm_multishells/* && echo "Pulizia completata."'

# thefuck alias (corrects mistyped commands)
if command -v thefuck >/dev/null 2>&1; then
    eval $(thefuck --alias)
    eval $(thefuck --alias fk)
fi

# ------- Zoxide (smarter cd) ------- #
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
    alias cd="z"
fi

# ---------- OS-Specific Functions and Aliases ---------- #
if [[ "$PLATFORM" == 'macOS' ]]; then
  # -------- macOS Specific --------- #
  alias compile="clang++ -std=c++20 -O3 -march=native -flto=thin -ffast-math -I/opt/homebrew/include"
  alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  command -v eza >/dev/null 2>&1 && alias ls="eza --color=always --long --git --icons=always"
  
  function brew() {
    command brew "$@"
    if [[ $* =~ "upgrade" ]] || [[ $* =~ "update" ]] || [[ $* =~ "outdated" ]]; then
      # Ensure sketchybar is available before calling it
      command -v sketchybar >/dev/null 2>&1 && sketchybar --trigger brew_update
    fi
  }

  # -------- macOS utilities -------- #
  alias flushdns="sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
  alias battery="pmset -g batt"
  alias sleep="pmset sleepnow"
  alias lock="pmset displaysleepnow"
  alias emptytrash="rm -rfv ~/.Trash; find /Volumes -name '.Trashes' -type d -execdir sudo rm -rf {} + 2>/dev/null"
  alias ports="sudo lsof -i -P | grep LISTEN"
  alias path="echo \$PATH | tr ':' '\n'"
  alias topdir="du -h -d 1 | sort -hr"
  alias localip="ipconfig getifaddr en0"

elif [[ "$PLATFORM" == 'Linux' ]]; then
  # ----- Common Linux Aliases ------ #
  alias compile="g++ -std=c++20 -O3 -march=native -flto -ffast-math"

  # -------- Linux utilities -------- # 
  alias update="sudo apt update && sudo apt upgrade"
  alias install="sudo apt install"
  alias search="apt search"
  alias remove="sudo apt remove"
  alias autoremove="sudo apt autoremove"
  alias services="systemctl list-units --type=service"
  alias logs="journalctl -f"
  alias ports="ss -tuln"
  alias firewall="sudo ufw status"
  alias ip="curl -s ifconfig.me"
  alias localip="hostname -I | awk '{print \$1}'"
  alias path="echo -e \${PATH//:/\\n}"
  alias topdir="du -h --max-depth=1 | sort -hr"
  alias qr="qrencode -t ansiutf8"
  alias mounted="mount | column -t"
  alias listening="netstat -tuln"
  alias openports="nmap -sT -O localhost"

  # ----- Arch Linux Specific ------- #
  if [[ "$ARCH_LINUX" == true ]]; then
    # Command not found handler for pacman
    function command_not_found_handler {
      local purple='\e[1;35m' bright='\e[0;1m' green='\e[1;32m' reset='\e[0m'
      printf 'zsh: command not found: %s\n' "$1"
      local entries=( ${(f)"$(/usr/bin/pacman -F --machinereadable -- "/usr/bin/$1")"} )
      if (( ${#entries[@]} )); then
        printf "${bright}$1${reset} may be found in the following packages:\n"
        local pkg
        for entry in "${entries[@]}" ; do
          local fields=( ${(0)entry} )
          if [[ "$pkg" != "${fields[2]}" ]]; then
            printf "${purple}%s/${bright}%s ${green}%s${reset}\n" "${fields[1]}" "${fields[2]}" "${fields[3]}"
          fi
          printf '    /%s\n' "${fields[4]}"
          pkg="${fields[2]}"
        done
      fi
      return 127
    }
    
    # Automatic detection of AUR helper
    if pacman -Qi yay &>/dev/null; then
      aurhelper="yay"
    elif pacman -Qi paru &>/dev/null; then
      aurhelper="paru"
    fi
    
    # 'in' function for intelligent installation from official repos and AUR
    function in {
      local -a inPkg=("$@")
      local -a arch=()
      local -a aur=()
      
      for pkg in "${inPkg[@]}"; do
        if pacman -Si "${pkg}" &>/dev/null; then
          arch+=("${pkg}")
        else
          aur+=("${pkg}")
        fi
      done
      
      if [[ ${#arch[@]} -gt 0 ]]; then
        sudo pacman -S --needed "${arch[@]}"
      fi
      
      if [[ ${#aur[@]} -gt 0 ]] && [[ -n "$aurhelper" ]]; then
        ${aurhelper} -S --needed "${aur[@]}"
      fi
    }
    
    # Aliases for package management on Arch
    if [[ -n "$aurhelper" ]]; then
      alias un='$aurhelper -Rns'
      alias up='$aurhelper -Syu'
      alias pl='$aurhelper -Qs'
      alias pa='$aurhelper -Ss'
      alias pc='$aurhelper -Sc'
      alias po='pacman -Qtdq | $aurhelper -Rns -'
    fi
    
    # Aliases for 'eza' on Arch (overrides generic Linux ones)
    command -v eza >/dev/null 2>&1 && {
      alias l='eza -lh --icons=auto'
      alias ls='eza -1 --icons=auto'
      alias ll='eza -lha --icons=auto --sort=name --group-directories-first'
      alias ld='eza -lhD --icons=auto'
      alias lt='eza --icons=auto --tree'
    }

    # Other aliases for Arch
    command -v kitten >/dev/null 2>&1 && alias ssh='kitten ssh'
    command -v code >/dev/null 2>&1 && alias vc='code'
  fi
fi

# -------- Cross-Platform Dev. Aliases -------- #
alias gst="git status"
alias gaa="git add ."
alias gcm="git commit -m"
alias gp="git push"
alias gl="git log --oneline -10"
alias gd="git diff"
alias gb="git branch"
alias gco="git checkout"
alias gcb="git checkout -b"
alias gpl="git pull"
alias gf="git fetch"
alias greset="git reset --hard HEAD"
alias gclean="git clean -fd"

# ------ Productivity Aliases ------- #
alias c="clear"
alias cd="z"
alias ls="eza --color=always --long --git --icons=always"
alias ll="ls -la"
alias l="ls -l"
alias md="mkdir -p"
alias count="wc -l"
alias size="du -sh"
alias size-all="du -sh .[^.]* * 2>/dev/null"
alias biggest="du -hs * | sort -hr | head -10"
alias epoch="date +%s | xargs -I {} sh -c 'echo \"Unix timestamp: {}\"; 
             echo \"Human readable: \$(date -d @{} 2>/dev/null || date -r {} 2>/dev/null)\"'"
alias ping="ping -c 5"
alias reload="source ~/.zshrc"
alias edit="$EDITOR ~/.zshrc"

# ----- OS-specific environment variables ----- #
if [[ "$OS_TYPE" == 'macOS' ]]; then
  # Force the use of system binaries to avoid conflicts.
  export LD=/usr/bin/ld
  export AR=/usr/bin/ar
  # Activate these flags if you intend to use Homebrew's LLVM
  export CPATH="/opt/homebrew/include"
  export LDFLAGS="-L/opt/homebrew/opt/llvm/lib"
  export CPPFLAGS="-I/opt/homebrew/opt/llvm/include"
fi

# =========================================================================== #
# ++++++++++++++++++++++++++++ GLOBAL VARIABLES +++++++++++++++++++++++++++++ #
# =========================================================================== #

# GO Language
export GOROOT="/usr/local/go"
export GOPATH=$HOME/00_ENV/go

# Android Home for Platform Tools
export ANDROID_HOME="$HOME/Library/Android/Sdk"

# Clang-Format Configuration
export CLANG_FORMAT_CONFIG="$HOME/.config/clang-format/.clang-format"

# OpenSSL for some Python packages (specific to environments that require it)
if [[ "$PLATFORM" == "Linux" ]]; then
    export CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1
fi

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

# --------------- Blog -------------- #
export BLOG_POSTS_DIR="$LCS_Data/Blog/CS-Topics/content/posts/"
export BLOG_STATIC_IMAGES_DIR="$LCS_Data/Blog/CS-Topics/static/images"
export IMAGES_SCRIPT_PATH="$LCS_Data/Blog/Automatic-Updates/images.py"
export OBSIDIAN_ATTACHMENTS_DIR="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images"

# =========================================================================== #
# +++++++++++++++++++++++ STATIC ENVIRONMENT MANAGERS +++++++++++++++++++++++ #
# =========================================================================== #

# --------------- Nix --------------- #
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
  . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# ------- Homebrew / Linuxbrew ------ #
# Search for Homebrew in standard macOS and Linux paths
if [ -x "/opt/homebrew/bin/brew" ]; then # macOS Apple Silicon
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x "/usr/local/bin/brew" ]; then # macOS Intel
  eval "$(/usr/local/bin/brew shellenv)"
elif [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then # Linux
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# ------- Haskell (ghcup-env) ------- #
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"

# -------------- Opam --------------- #
[[ ! -r "$HOME/.opam/opam-init/init.zsh" ]] || source "$HOME/.opam/opam-init/init.zsh" > /dev/null 2> /dev/null

# =========================================================================== #
# ++++++++++++++++++++++ DYNAMIC ENVIRONMENT MANAGERS  ++++++++++++++++++++++ #
# =========================================================================== #

# ===================== LANGUAGES AND DEVELOPMENT TOOLS ===================== #

# --------------------- Java - Smart JAVA_HOME Management ------------------- #
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

# -------------- PyENV -------------- #
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# -------------- CONDA -------------- #
# >>> Conda initialize >>>
__conda_init() {
    local conda_path=""
    # Arch specific path
    if [[ "$PLATFORM" == 'Linux' && -f "/opt/miniconda3/bin/conda" ]]; then
        conda_path="/opt/miniconda3/bin/conda"
    # User path (macOS or other Linux)
    elif [[ -f "$HOME/00_ENV/miniforge3/bin/conda" ]]; then
        conda_path="$HOME/00_ENV/miniforge3/bin/conda"
    fi

    if [[ -n "$conda_path" ]]; then
        __conda_setup="$("$conda_path" 'shell.zsh' 'hook' 2> /dev/null)"
        if [ $? -eq 0 ]; then
            eval "$__conda_setup"
        else
            local conda_dir=$(dirname $(dirname "$conda_path"))
            if [ -f "$conda_dir/etc/profile.d/conda.sh" ]; then
                . "$conda_dir/etc/profile.d/conda.sh"
            else
                export PATH="$(dirname "$conda_path"):$PATH"
            fi
        fi
        unset __conda_setup
    fi
}
__conda_init
unset -f __conda_init
# <<< Conda initialize <<<

# ------------ Perl CPAN ------------ #
eval "$(perl -I$HOME/00_ENV/perl5/lib/perl5 -Mlocal::lib=$HOME/00_ENV/perl5)"

# ----- FNM (Fast Node Manager) ----- #
if command -v fnm &>/dev/null; then
  # Clean up any existing orphan directories before starting
  fnm_cleanup_orphans() {
    local fnm_multishells_dir="$HOME/.local/state/fnm_multishells"
    if [ -d "$fnm_multishells_dir" ]; then
      # Remove directories older than 60 minutes
      find "$fnm_multishells_dir" -mindepth 1 -type l -mmin +60 -exec rm -rf {} + 2>/dev/null
    fi
  }
  
  # Run cleanup before initialization
  fnm_cleanup_orphans

  # Set a global default version if it doesn't exist
  if ! fnm default >/dev/null 2>&1; then
    latest_installed=$(fnm list | grep -o 'v[0-9.]*' | sort -V | tail -n 1)
    if [ -n "$latest_installed" ]; then
      fnm default "$latest_installed"
    fi
  fi

  # Initialize fnm
  eval "$(fnm env --use-on-cd --shell zsh)"

  # Hook for cleanup on shell exit
  _fnm_cleanup_on_exit() {
    if [ -n "$FNM_MULTISHELL_PATH" ] && [ -d "$FNM_MULTISHELL_PATH" ]; then
      rm -rf "$FNM_MULTISHELL_PATH"
    fi
  }
  autoload -U add-zsh-hook
  add-zsh-hook zshexit _fnm_cleanup_on_exit
fi

# =========================================================================== #
# +++++++++++++++++++++++++++ COMPLETIONS (LAST) ++++++++++++++++++++++++++++ #
# =========================================================================== #

# ------------ ngrok ---------------- #
command -v ngrok &>/dev/null && eval "$(ngrok completion)"

# ----------- Angular CLI ----------- #
command -v ng &>/dev/null && source <(ng completion script)

# =========================================================================== #
# +++++++++++++++++ FINAL PATH REORDERING AND CLEANUP +++++++++++++++++++++++ #
# =========================================================================== #
# This runs LAST. It takes the messy PATH and rebuilds it in the desired order.
# This guarantees that shims have top priority and the order is consistent.

build_final_path() {
  # Store original PATH for debugging
  local original_path="$PATH"
  
  # Define the desired final order of directories in the PATH
  local -a path_template
  if [[ "$OS_TYPE" == 'macOS' ]]; then
    path_template=(
      # ----- DYNAMIC SHIMS (TOP PRIORITY) ---- #
      "$HOME/.pyenv/shims"
      
      # ----- STATIC SHIMS & LANGUAGE BINS ---- #
      "$PYENV_ROOT/bin"
      "$HOME/.opam/ocaml-compiler/bin"
      "$HOME/.sdkman/candidates/java/current/bin"
      
      # ----- FNM (Current session only) ------ #
      "$FNM_MULTISHELL_PATH/bin"

      # -------------- Homebrew --------------- #
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
      "/opt/homebrew/opt/llvm/bin"

      # ------------ System Tools ------------- #
      "/usr/local/bin" "/usr/bin" "/bin"
      "/usr/sbin" "/sbin"

      # ----- User and App-Specific Paths ----- #
      "$HOME/.local/bin"
      "$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin"
      "$HOME/.ghcup/bin" "$HOME/.cabal/bin"
      "$HOME/.cargo/bin"
      "$HOME/.ada/bin"
      "$HOME/00_ENV/perl5/bin"
      "$HOME/00_ENV/miniforge3/condabin" "$HOME/00_ENV/miniforge3/bin"
      "$GOPATH/bin" "$GOROOT/bin"
      "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/cmdline-tools/latest/bin"
      
      # ------------- Other Paths ------------- #
      "$HOME/.config/emacs/bin"
      "/usr/local/mysql/bin"
      "/opt/homebrew/opt/ncurses/bin"
      "/Library/TeX/texbin"
      "/usr/local/texlive/2025/bin/universal-darwin"
      "$HOME/Library/Application Support/JetBrains/Toolbox/scripts"
      "$HOME/.lcs-bin"
    )
  elif [[ "$OS_TYPE" == 'Linux' ]]; then
    path_template=(
      # ----- DYNAMIC SHIMS (TOP PRIORITY) ---- #
      "$HOME/.pyenv/shims"
      
      # ----- STATIC SHIMS & LANGUAGE BINS ---- #
      "$PYENV_ROOT/bin"
      "$HOME/.sdkman/candidates/java/current/bin"
      "$HOME/.opam/ocaml-compiler/bin"
      
      # ----- FNM (Current session only) ------ #
      "$FNM_MULTISHELL_PATH/bin"

      # ------------ System Tools ------------- #
      "/usr/local/bin" "/usr/bin" "/bin"
      "/usr/local/sbin" "/usr/sbin" "/sbin"

      # -------------- Linuxbrew -------------- #
      "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin"

      # ----- User and App-Specific Paths ----- #
      "$HOME/.local/bin"
      "$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin"
      "$HOME/.ghcup/bin" "$HOME/.cabal/bin"
      "$HOME/.cargo/bin"
      "$HOME/.ada/bin"
      "$GOPATH/bin" "$GOROOT/bin"
      "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/cmdline-tools/latest/bin"
      
      # ------------- Other Paths ------------- #
      "$HOME/.config/emacs/bin"
      "$HOME/.lcs-bin"
    )
  fi
  
  # Create new PATH with only existing directories
  local -a new_path_array=()
  for dir in "${path_template[@]}"; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      new_path_array+=("$dir")
    fi
  done
  
  # Add any directories from original PATH that weren't in template
  # (like VS Code extensions, etc.)
  local -a original_path_array=("${(@s/:/)original_path}")
  for dir in "${original_path_array[@]}"; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      # Check if this directory is already in our new path
      local found=false
      for existing in "${new_path_array[@]}"; do
        if [[ "$dir" == "$existing" ]]; then
          found=true
          break
        fi
      done
      
      # Skip FNM orphan directories
      if [[ "$dir" == *"fnm_multishells"* && "$dir" != "$FNM_MULTISHELL_PATH/bin" ]]; then
        continue
      fi
      
      if [[ "$found" == false ]]; then
        new_path_array+=("$dir")
      fi
    fi
  done
  
  # Convert array to PATH string
  local IFS=':'
  export PATH="${new_path_array[*]}"
  
  # Remove duplicates using typeset -U
  typeset -U PATH
}

# Run the PATH rebuilding function
build_final_path
unset -f build_final_path

# Background cleanup of old FNM directories
if command -v fnm &>/dev/null; then
  # Use 'at' to schedule a reliable, detached cleanup job. This avoids issues with shell exit signals (SIGHUP)
  # The job will run 1 minute from now, ensuring it's out of the critical startup path
  echo 'find "$HOME/.local/state/fnm_multishells" -mindepth 1 -type l -mmin +60 -exec rm -rf {} + 2>/dev/null' | at -M now + 1 minute 2>/dev/null
fi