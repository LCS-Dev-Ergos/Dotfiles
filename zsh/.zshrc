# =========================================================================== #
# +++++++++++++++++++++++++++ DETECT OPERATING SYSTEM +++++++++++++++++++++++ #
# =========================================================================== #

# Rileva il sistema operativo per caricare configurazioni specifiche
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
# +++++++++++++++++++++++++++ BASE CONFIGURATION ++++++++++++++++++++++++++++ #
# =========================================================================== #

# =============== Startup Commands =============== #
# fastfetch # Assicurati che sia installato su entrambi i sistemi

# =============== Helper Functions ============== #
# Function to check for duplicates in the PATH
check_path_dupes() {
  echo $PATH | tr ':' '\n' | sort | uniq -d
}

# Optimized function to configure the PATH in batch mode
setup_path() {
  # Initial base path (standard per sistemi UNIX-like)
  local base_path="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
  
  # Array per percorsi (dipendenti dall'OS)
  local prepend_dirs=()
  local append_dirs=()

  if [[ "$OS_TYPE" == 'macOS' ]]; then
    # --- Percorsi per macOS ---
    prepend_dirs=(
    "/opt/homebrew/bin"
    "$HOME/.local/bin"
    "/usr/local/bin"
    "/opt/homebrew/opt/llvm/bin"
  )
    append_dirs=(
    "$HOME/.nix-profile/bin"
    "/nix/var/nix/profiles/default/bin"
    "/run/current-system/sw/bin"
    "$HOME/.cabal/bin"
    "$HOME/.ghcup/bin"
    "$HOME/.ada/bin"
    "$HOME/.cargo/bin"
    "$GOPATH/bin"
    "$GOROOT/bin"
    "$HOME/.config/emacs/bin"
    "/opt/homebrew/opt/openjdk/bin" 
    "/usr/local/texlive/2025/bin/universal-darwin"
    "/Library/TeX/texbin"
    "$ANDROID_HOME/tools"
    "$ANDROID_HOME/tools/bin"
    "$ANDROID_HOME/platform-tools"
    "/usr/local/git/bin"
    "/usr/local/mysql/bin"
    "/opt/homebrew/opt/ncurses/bin"
    "$HOME/00_ENV/miniforge3/bin"
    "$HOME/00_ENV/miniforge3/condabin"
    "$HOME/.lcs-bin"
    "$HOME/Library/Application Support/JetBrains/Toolbox/scripts"
  )
  elif [[ "$OS_TYPE" == 'Linux' ]]; then
    # --- Percorsi per Linux ---
    prepend_dirs=(
      "/usr/local/bin"
      "$HOME/.local/bin"
      "/home/linuxbrew/.linuxbrew/bin"
    )
    append_dirs=(
      "$HOME/.nix-profile/bin"
      "/nix/var/nix/profiles/default/bin"
      "/run/current-system/sw/bin"
      "$HOME/.cabal/bin"
      "$HOME/.ghcup/bin"
      "$HOME/.ada/bin"
      "$HOME/.cargo/bin"
      "$GOPATH/bin"
      "$GOROOT/bin"
      "$HOME/.config/emacs/bin"
      "$HOME/.local/share/fnm"
      "$ANDROID_HOME/tools"
      "$ANDROID_HOME/tools/bin"
      "$ANDROID_HOME/platform-tools"
      "$HOME/00_ENV/miniforge3/bin"
      "$HOME/00_ENV/miniforge3/condabin"
      "$HOME/.lcs-bin"
    )
  fi

  local final_path="$base_path"
  
  # Aggiunge percorsi da anteporre (prepend)
  for dir in "${prepend_dirs[@]}"; do
    if [[ -d "$dir" && ":$final_path:" != *":$dir:"* ]]; then
      final_path="$dir:$final_path"
    fi
  done

  # Aggiunge percorsi da accodare (append)
  for dir in "${append_dirs[@]}"; do
    if [[ -d "$dir" && ":$final_path:" != *":$dir:"* ]]; then
      final_path="$final_path:$dir"
    fi
  done
  
  export PATH="$final_path"
}

# =========================================================================== #
# +++++++++++++++++++++++++++++ PATH CONFIGURATION ++++++++++++++++++++++++++ #
# =========================================================================== #

# Setup PATH in batch mode
setup_path

# =============== Terminal Variables ============= #
if [ "$TERM" = "xterm-kitty" ]; then
    export TERM=xterm-kitty
else
    export TERM=xterm-256color
fi

# Variabili d'ambiente specifiche per OS
if [[ "$OS_TYPE" == 'macOS' ]]; then
  # LLVM Flags (tipico per Homebrew su macOS)
export LDFLAGS="-L/opt/homebrew/opt/llvm/lib"
export CPPFLAGS="-I/opt/homebrew/opt/llvm/include"
  # C/C++ Libraries
  export CPATH=/opt/homebrew/include
  # OpenJDK
  export CPPFLAGS="-I/opt/homebrew/opt/openjdk/include"
fi

# Perl CPAN
eval "$(perl -I$HOME/00_ENV/perl5/lib/perl5 -Mlocal::lib=$HOME/00_ENV/perl5)"

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load
ZSH_THEME="robbyrussell"

# Set up XDG Base Directory Specification
export XDG_CONFIG_HOME="$HOME/.config"

# Set default editor
export EDITOR="nvim"

# =========================================================================== #
# +++++++++++++++++++++++++++++++ OH-MY-ZSH +++++++++++++++++++++++++++++++ #
# =========================================================================== #

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

# Cache di ZSH
export ZSH_COMPDUMP="$ZSH/cache/.zcompdump-$HOST"

# =========================================================================== #
# +++++++++++++++++++++++++++ ENVIRONMENT VARIABLES +++++++++++++++++++++++++ #
# =========================================================================== #

# ------------ Homebrew / Linuxbrew ------------- #
# Cerca Homebrew nei percorsi standard di macOS e Linux
if [ -x "/opt/homebrew/bin/brew" ]; then # macOS Apple Silicon
eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x "/usr/local/bin/brew" ]; then # macOS Intel
  eval "$(/usr/local/bin/brew shellenv)"
elif [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then # Linux
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# ------------ Nix ------------------ #
if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
  . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
elif [ -e "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
fi

# Note: Nix paths are already configured in the setup_path function

# =========================================================================== #
# +++++++++++++++++++++ LINGUAGGI E STRUMENTI DI SVILUPPO +++++++++++++++++++ #
# =========================================================================== #

# Haskell (ghcup-env) - Generalizzato con $HOME
[ -f "$HOME/.ghcup/env" ] && . "$HOME/.ghcup/env"

# GO Language 
export GOROOT=/usr/local/go
export GOPATH=$HOME/00_ENV/go

# ------------ Java - Gestione Intelligente di JAVA_HOME ------------ #

# Prima di tutto, diamo priorità a SDKMAN! se è installato.
if [[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]]; then
  # SDKMAN! trovato. Lasciamo che gestisca tutto.
  export SDKMAN_DIR="$HOME/.sdkman"
  source "$HOME/.sdkman/bin/sdkman-init.sh"
else
  # SDKMAN! non trovato. Usiamo la nostra logica di fallback per auto-rilevare Java.

  setup_java_home_fallback() {
    if [[ "$OS_TYPE" == 'macOS' ]]; then
      # Su macOS, usiamo l'utility fornita dal sistema
      if [ -x "/usr/libexec/java_home" ]; then
        export JAVA_HOME=$(/usr/libexec/java_home)
        export PATH="$JAVA_HOME/bin:$PATH"
      fi
    elif [[ "$OS_TYPE" == 'Linux' ]]; then
      local found_java_home=""

      # Metodo 1: Per sistemi basati su Debian/Ubuntu/Fedora (usa update-alternatives)
      if command -v update-alternatives &>/dev/null && command -v java &>/dev/null; then
        local java_path=$(readlink -f $(which java))
        if [[ -n "$java_path" ]]; then
          found_java_home="${java_path%/bin/java}"
        fi
      fi

      # Metodo 2: Per sistemi Arch Linux (usa archlinux-java)
      if [[ -z "$found_java_home" ]] && command -v archlinux-java &>/dev/null; then
          local java_env=$(archlinux-java get)
          if [[ -n "$java_env" ]]; then
              found_java_home="/usr/lib/jvm/$java_env"
          fi
      fi

      # Metodo 3: Fallback generico cercando in /usr/lib/jvm
      if [[ -z "$found_java_home" ]] && [[ -d "/usr/lib/jvm" ]]; then
          found_java_home=$(find /usr/lib/jvm -maxdepth 1 -type d -name "java-*-openjdk*" | sort -V | tail -n 1)
      fi
      
      # Esporta le variabili solo se abbiamo trovato un percorso valido
      if [[ -n "$found_java_home" && -d "$found_java_home" ]]; then
        export JAVA_HOME="$found_java_home"
        export PATH="$JAVA_HOME/bin:$PATH"
      else
        echo "⚠️  Attenzione: Impossibile determinare JAVA_HOME automaticamente e SDKMAN! non è installato."
        echo "    Per favore, installa Java e/o SDKMAN!, o imposta JAVA_HOME manualmente."
      fi
    fi
  }

  # Esegui la funzione di fallback
  setup_java_home_fallback
fi

# Android ADB (il percorso potrebbe variare su Linux)
export ANDROID_HOME="$HOME/Library/Android/Sdk" # macOS
if [[ "$OS_TYPE" == 'Linux' ]]; then
    # Linux
   export ANDROID_HOME="$HOME/Android/Sdk" 
fi

# FNM (Fast Node Manager)
if command -v fnm &>/dev/null; then
    eval "$(fnm env --use-on-cd --shell zsh)"
fi

# =========================================================================== #
# +++++++++++++++++++++++++++ GLOBAL VARIABLES ++++++++++++++++++++++++++++++ #
# =========================================================================== #
# Questi sono percorsi personali e dovrebbero funzionare se il volume è montato

# LCS.Data Volume
export LCS_Data="/Volumes/LCS.Data"
# Check if the volume is already mounted
if [ ! -d "$LCS_Data" ]; then
  echo "⚠️  Attenzione: Il volume LCS.Data non è montato"
elif [[ "$OS_TYPE" == 'Linux' ]]; then
    # Su Linux i volumi esterni vengono montati altrove, es. /media/utente/LCS.Data
    export LCS_Data="/media/$USER/LCS.Data"
    if [ ! -d "$LCS_Data" ]; then
        echo "⚠️  Attenzione: Il volume LCS.Data non sembra montato in $LCS_Data"
    fi
fi

# Configuration System Directory
export CONFIG_DIR="$HOME/.config"

# Clang-Format Configuration
export CLANG_FORMAT_CONFIG="$HOME/.config/clang-format/.clang-format"

# -------------------------------- BLOG ------------------------------------- #
# Variables for Blog Automation
export BLOG_POSTS_DIR="$LCS_Data/Blog/CS-Topics/content/posts/"
export BLOG_STATIC_IMAGES_DIR="$LCS_Data/Blog/CS-Topics/static/images"
export IMAGES_SCRIPT_PATH="$LCS_Data/Blog/Automatic-Updates/images.py"
export OBSIDIAN_ATTACHMENTS_DIR="$HOME/Documents/Obsidian-Vault/XSPC-Vault/Blog/images"

# =========================================================================== #
# ++++++++++++++++++++++ PERSONAL CONFIGURATION - THEMES ++++++++++++++++++++ #
# =========================================================================== #
# Questa sezione è quasi interamente cross-platform

# -------------------------------- VI-MODE ---------------------------------- #
bindkey -v

# Riduce il ritardo per il cambio modalità (0.1 secondi)
export KEYTIMEOUT=10
zle -N zle-keymap-select
zle -N zle-line-init
function zle-line-init() { zle -K viins }
function zle-keymap-select() {
  case $KEYMAP in
    viins) zle-line-init ;;
    vicmd) zle reset-prompt ;;
  esac
}

# -------------------------------- PROMPT ----------------------------------- #
# Oh My Posh - Prompt personalizzato
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
# +++++++++++++++++++++++++++ APPLICATIONS OPTIONS ++++++++++++++++++++++++++ #
# =========================================================================== #

# ------- Zoxide (better cd) -------- #
eval "$(zoxide init zsh)"

# ------------ ngrok & Angular (cross-platform) ---------------- #
if command -v ngrok &>/dev/null; then eval "$(ngrok completion)"; fi
if command -v ng &>/dev/null; then source <(ng completion script); fi

# -------------- PyENV -------------- #
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# >>> Conda initialize >>>
# !! Generalizzato con $HOME !!
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

# =========================================================================== #
# ++++++++++++++++++++++++++++++++ ALIASES +++++++++++++++++++++++++++++++++++ #
# =========================================================================== #

# --- Alias Comuni (Cross-Platform) ---
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."
alias ls="eza --color=always --long --git --icons=always"
eval $(thefuck --alias)
eval $(thefuck --alias fk)
alias cd="z"
alias c="clear"
alias ranger='TERM=screen-256color ranger'

# MySQL
alias mysql=/usr/local/mysql/bin/mysql
alias mysqladmin=/usr/local/mysql/bin/mysqladmin

# Clang-Format alias
alias clang-format='clang-format -style=file:$CLANG_FORMAT_CONFIG'

# --- Alias Specifici per OS ---
if [[ "$OS_TYPE" == 'macOS' ]]; then
  alias compile="clang++ -std=c++20 -O3 -march=native -flto=thin -ffast-math -I/usr/local/include"
  alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  alias mysql=/usr/local/mysql/bin/mysql
  alias mysqladmin=/usr/local/mysql/bin/mysqladmin
  alias gcc='gcc-15' # Usa gcc di Homebrew
alias lldb='/usr/bin/lldb'
elif [[ "$OS_TYPE" == 'Linux' ]]; then
  alias compile="g++ -std=c++20 -O3 -march=native -flto -ffast-math"
  alias gcc='gcc'
  alias lldb='lldb'
fi

# =========================================================================== #


#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"


# BEGIN opam configuration
# This is useful if you're using opam as it adds:
#   - the correct directories to the PATH
#   - auto-completion for the opam binary
# This section can be safely removed at any time if needed.
[[ ! -r '/Users/lcs-dev/.opam/opam-init/init.zsh' ]] || source '/Users/lcs-dev/.opam/opam-init/init.zsh' > /dev/null 2> /dev/null
# END opam configuration
