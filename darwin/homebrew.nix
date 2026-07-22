_: {
  # Captured via `brew bundle dump` against the live system (2026-07-20).
  # The vscode/go/cargo/uv stanzas that command also emits have no
  # nix-darwin equivalent and aren't tracked here.
  #
  # cleanup = "none" is deliberate: it declares this inventory without
  # touching anything not yet listed. Switch to "uninstall"/"zap" only once
  # every live cask/tap/formula is confirmed present below -- those modes
  # remove whatever's installed but undeclared.
  #
  # Absent on purpose, now Nix/Home Manager-owned: aspell, atuin, bandwhich,
  # bat, bc, bottom, btop, cava, cbonsai, cmatrix, csvlens, direnv, duf, eza,
  # fastfetch, fd, fish, fswatch, fzf, gh, git, git-delta, glab, glow, gum,
  # jq, just, lazydocker, lazygit, lld, llvm, nnn, nushell, oh-my-posh, procs,
  # pstree, shellcheck, starship, tealdeer, television, tmux, tree, w3m,
  # wget, yazi, zoxide, ueberzugpp. llvm/lld left for a real bug, not just
  # ownership -- see home/llvm. `rust` was never declared here to begin with
  # (a pre-migration leftover). `brew uninstall llvm lld rust` is still a
  # manual follow-up; cleanup = "none" won't do it for us.
  #
  # Also absent, but not Nix takeovers: `coreutils` is only a build input for
  # activation scripts and Doom's separate `coreutils-prefixed` package,
  # never used interactively; `stow` has no Nix equivalent -- Home Manager's
  # declarative file placement replaced it.
  #
  # Deliberate Homebrew holdouts: `ripgrep` (codex/droid/opencode depend on
  # it; Nix still owns the interactive `rg` on PATH), `gcc` (hdf5, open-mpi,
  # libmatio, vips and ueberzugpp need its gfortran at runtime, and
  # emacs-plus's native-comp links against its libgccjit -- Nix's gcc15 still
  # wins on PATH for interactive/project use, see home/gcc), `neovim`/`zsh`
  # (binary ownership is a separate decision from Home Manager deploying
  # their configs), and GUI apps in general.
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
      "autoconf"
      "automake"
      "bash"
      "bear"
      "beautysh"
      "ccache"
      "clamav"
      "clang-format"
      "cmake"
      "cmake-docs"
      "coursier"
      "cpanminus"
      "cppman"
      "cronboard"
      "cunit"
      "discount"
      "djvu2pdf"
      "djvulibre"
      "dolphie"
      "doxygen"
      "erlang"
      "exiftool"
      "fabric-ai"
      "felixkratz/formulae/borders"
      "felixkratz/formulae/sketchybar"
      "findutils"
      "fnm"
      "fzf-make"
      "gawk"
      "gcc"
      "gdb"
      "git-filter-repo"
      "gleam"
      "global"
      "gnu-sed"
      "gnu-time"
      "go"
      "googletest"
      "gpatch"
      "graelo/tap/pumas"
      "graphviz"
      "gromgit/brewtils/taproom"
      "hako/tap/oeis-tui"
      "hashcat"
      "hcxtools"
      "hugo"
      "icu4c@77"
      "icu4c@78"
      "imagemagick"
      "jbreckmckye/formulae/daylight"
      "jordond/tap/jolt"
      "julien-cpsn/atac/atac"
      "libgccjit"
      "libsixel"
      "libvterm"
      "llmfit"
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
      "node"
      "nowplaying-cli"
      "oci-cli"
      "ocrmypdf"
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
      "smartmontools"
      "swi-prolog"
      "switchaudio-osx"
      "teamookla/speedtest/speedtest"
      "terror/tap/just-lsp"
      "tesseract-lang"
      "tex-fmt"
      "thefuck"
      "unar"
      "universal-ctags"
      "uv"
      "veeso/termscp/termscp"
      "zackelia/formulae/bclm"
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
