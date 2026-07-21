{ ... }:
{
  # Captured via `brew bundle dump` against the live system (2026-07-20):
  # taps/brews/casks only -- Homebrew Bundle's vscode/go/cargo/uv stanzas
  # have no nix-darwin equivalent and aren't tracked here.
  #
  # cleanup = "none" is deliberate: it declares this inventory without
  # touching anything not yet listed. Do not change to "uninstall"/"zap"
  # until every current cask/tap/formula is confirmed captured here --
  # those modes remove whatever's installed but undeclared, which would
  # delete real applications if this audit missed something.
  #
  # Some of these formulae (git, stow, atuin, bat, direnv, eza, fd, fzf,
  # ripgrep, starship, tealdeer, zoxide, tmux, neovim, fish, nushell) are
  # now also declared via Nix/Home Manager modules elsewhere in this repo.
  # Both sources installing the same tool is harmless (the Nix copy already
  # wins on PATH) and is left as-is here; deciding whether to eventually
  # drop the Homebrew copies is separate follow-up work, same as the
  # broader "retire Stow" step.
  homebrew = {
    enable = true;

    onActivation.cleanup = "none";
    # Suppresses the "Using <formula>" line brew bundle otherwise prints for
    # every already-installed dependency on every switch -- pure noise here
    # since cleanup = "none" means nothing gets removed either way. Actual
    # errors/installs still print.
    onActivation.extraFlags = [ "--quiet" ];

    taps = [
      {
        name = "alexsjones/llmfit";
        clone_target = "https://github.com/AlexsJones/homebrew-llmfit";
        trusted = true;
      }
      {
        name = "anomalyco/tap";
        trusted = true;
      }
      {
        name = "asmvik/formulae";
        clone_target = "https://github.com/asmvik/homebrew-formulae.git";
        trusted = true;
      }
      {
        name = "d12frosted/emacs-plus";
        trusted = true;
      }
      {
        name = "felixkratz/formulae";
        clone_target = "https://github.com/FelixKratz/homebrew-formulae";
      }
      "graelo/tap"
      {
        name = "gromgit/brewtils";
        trusted = true;
      }
      "hako/tap"
      "homebrew/cask"
      "homebrew/core"
      "jbreckmckye/formulae"
      "jordond/tap"
      "jstkdng/programs"
      "julien-cpsn/atac"
      {
        name = "kilo-org/tap";
        clone_target = "https://github.com/Kilo-Org/homebrew-tap";
        trusted = true;
      }
      {
        name = "nikitabobko/tap";
        trusted = true;
      }
      "oven-sh/bun"
      {
        name = "reyamira/tap";
        clone_target = "https://github.com/reyamira/homebrew-tap.git";
        trusted = true;
      }
      {
        name = "romkatv/powerlevel10k";
        trusted = true;
      }
      "serkanyersen/dotstate"
      "teamookla/speedtest"
      "terror/tap"
      "veeso/termscp"
      "zackelia/formulae"
    ];

    brews = [
      "ansible"
      "ansible-lint"
      "asmvik/formulae/skhd"
      "asmvik/formulae/yabai"
      "aspell"
      "atuin"
      "autoconf"
      "automake"
      "bandwhich"
      "bash"
      "bat"
      {
        name = "bc";
        link = true;
      }
      "bear"
      "beautysh"
      "bottom"
      "btop"
      "cava"
      "cbonsai"
      "ccache"
      "clamav"
      "clang-format"
      "cmake"
      "cmake-docs"
      "cmatrix"
      "coreutils"
      "coursier"
      "cpanminus"
      "cppman"
      "cronboard"
      "csvlens"
      "cunit"
      "direnv"
      "discount"
      "djvu2pdf"
      "djvulibre"
      "dolphie"
      "doxygen"
      "duf"
      "erlang"
      "exiftool"
      "eza"
      "fabric-ai"
      "fastfetch"
      "fd"
      "felixkratz/formulae/borders"
      "felixkratz/formulae/sketchybar"
      "findutils"
      "fish"
      "fnm"
      "fswatch"
      "fzf"
      "fzf-make"
      "gawk"
      "gcc"
      "gdb"
      "gh"
      "git"
      "git-delta"
      "git-filter-repo"
      "glab"
      "gleam"
      "global"
      "glow"
      "gnu-sed"
      "gnu-time"
      "go"
      "googletest"
      "gpatch"
      "graelo/tap/pumas"
      "graphviz"
      "gromgit/brewtils/taproom"
      "gum"
      "hako/tap/oeis-tui"
      "hashcat"
      "hcxtools"
      "hugo"
      "icu4c@77"
      "icu4c@78"
      "imagemagick"
      "jbreckmckye/formulae/daylight"
      "jordond/tap/jolt"
      "jq"
      "jstkdng/programs/ueberzugpp"
      "julien-cpsn/atac/atac"
      "just"
      "lazydocker"
      "lazygit"
      "libgccjit"
      "libsixel"
      "libvterm"
      "lld"
      "llmfit"
      "llvm"
      "lua"
      "make"
      "man-db"
      "mit-scheme"
      "models"
      "msgpack"
      "mypy"
      "neovim"
      "ninja"
      "nmap"
      "nnn"
      "node"
      "nowplaying-cli"
      "nushell"
      "oci-cli"
      "ocrmypdf"
      "oh-my-posh"
      "opam"
      "opencode"
      {
        name = "openjdk@21";
        link = true;
      }
      "oven-sh/bun/bun"
      "pandoc"
      "pdfcpu"
      "perl"
      "php"
      "pipes-sh"
      "pkgconf"
      "plantuml"
      "powerlevel10k"
      "procs"
      "pstree"
      "pyenv"
      "qpdf"
      "qrencode"
      "raylib"
      "rbenv"
      "reaver"
      "redis"
      "ripgrep"
      "ruby"
      "ruff"
      "serkanyersen/dotstate/dotstate"
      "sesh"
      "sevenzip"
      "shellcheck"
      "smartmontools"
      "starship"
      "stow"
      "swi-prolog"
      "switchaudio-osx"
      "tealdeer"
      "teamookla/speedtest/speedtest"
      "television"
      "terror/tap/just-lsp"
      "tesseract-lang"
      "tex-fmt"
      "thefuck"
      "tmux"
      "tree"
      "unar"
      "universal-ctags"
      "uv"
      "veeso/termscp/termscp"
      "w3m"
      "wget"
      "yazi"
      "zackelia/formulae/bclm"
      "zoxide"
      "zsh"
    ];

    casks = [
      "1password-cli@beta"
      "battery"
      "calibre"
      "codex"
      "copilot-cli"
      "d12frosted/emacs-plus/emacs-plus-app"
      "dotnet-sdk"
      "droid"
      "font-caskaydia-cove-nerd-font"
      "font-computer-modern"
      "font-fira-code"
      "font-fira-code-nerd-font"
      "font-hack-nerd-font"
      "font-iosevka-nerd-font"
      "font-jetbrains-mono-nerd-font"
      "font-monaspice-nerd-font"
      "font-noto-sans-symbols-2"
      "font-sf-mono"
      "font-sf-pro"
      "font-symbols-only-nerd-font"
      "ghostty"
      "git-credential-manager"
      "iterm2"
      "kitty"
      "localsend"
      "neovide-app"
      "ngrok"
      "nikitabobko/tap/aerospace"
      "prince"
      "racket"
      "raycast"
      "sf-symbols"
      "supacode"
      "temurin@21"
      "warp"
      "wireshark-app"
      "xquartz"
    ];
  };
}
