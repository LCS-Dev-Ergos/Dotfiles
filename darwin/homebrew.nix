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
  # Absent on purpose, now Nix/Home Manager-owned: ansible, ansible-lint,
  # aspell, atac, atuin, bandwhich, bash, bat, bc, bear, beautysh, bottom,
  # btop, bun, cava, cbonsai, ccache, clang-format, cmatrix, codex, cppman,
  # csvlens, direnv, duf, eza, exiftool, fastfetch, fd, findutils, fish,
  # fswatch, fzf, gh, git, git-delta, git-filter-repo, glab, glow, gnu-sed,
  # gnu-time, gpatch, gum, jolt, jq, just, just-lsp, lazydocker, lazygit,
  # lld, llmfit, llvm, nnn, node, nowplaying-cli, nushell, oh-my-posh,
  # opencode, pipes-sh, procs, pstree, qpdf, ripgrep, ruff, sesh, sevenzip,
  # shellcheck, starship, switchaudio-osx, tealdeer, television, tex-fmt,
  # tmux, tree, universal-ctags, uv, w3m, wget, yazi, zoxide.
  #
  # llvm/lld left for a real bug, not just ownership -- see home/llvm. `rust`
  # was never declared here to begin with (a pre-migration leftover).
  # cleanup = "none" leaves all retired formulae installed until the Nix
  # replacements have been activated and a dependency-aware manual cleanup is
  # confirmed. The unused Darwin ueberzugpp installation is retired rather
  # than replaced; its Nix package and configuration remain Linux-only.
  #
  # Also absent, but not Nix takeovers: `coreutils` is only a build input for
  # activation scripts and Doom's separate `coreutils-prefixed` package,
  # never used interactively; `stow` has no Nix equivalent -- Home Manager's
  # declarative file placement replaced it.
  #
  # Open font casks are also absent: nix-darwin installs CM Unicode, Fira Code,
  # the selected Nerd Font families, and Noto Sans Symbols 2. Apple SF fonts
  # remain Homebrew-owned because their licenses are proprietary.
  #
  # Deliberate Homebrew holdouts: `gcc` (hdf5, open-mpi, libmatio and vips
  # need its gfortran at runtime, and emacs-plus's native-comp links against
  # its libgccjit -- Nix's gcc15 still wins on PATH for interactive/project
  # use, see home/gcc), `neovim` (binary ownership is a separate decision
  # from Home Manager deploying its config), and GUI apps in general. `zsh`
  # stays declared only until the Nix login shell (users.users.<name>.shell)
  # has soaked through real sessions; remove it here and uninstall manually
  # afterwards.
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
      {
        name = "nikitabobko/tap";
        trusted = true;
      }
      "serkanyersen/dotstate"
      "teamookla/speedtest"
      "veeso/termscp"
      "zackelia/formulae"
    ];

    brews = [
      "asmvik/formulae/skhd"
      "asmvik/formulae/yabai"
      "autoconf"
      "automake"
      "clamav"
      "cmake"
      "cmake-docs"
      "coursier"
      "cpanminus"
      "cronboard"
      "cunit"
      "discount"
      "djvu2pdf"
      "djvulibre"
      "dolphie"
      "doxygen"
      "erlang"
      "fabric-ai"
      "felixkratz/formulae/borders"
      "felixkratz/formulae/sketchybar"
      "fnm"
      "fzf-make"
      "gawk"
      "gcc"
      "gdb"
      "gleam"
      "global"
      "go"
      "googletest"
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
      "libgccjit"
      "libsixel"
      "libvterm"
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
      "oci-cli"
      "ocrmypdf"
      "opam"
      {
        name = "openjdk@21";
        link = true;
      }
      "pandoc"
      "pdfcpu"
      "perl"
      "php"
      "pkgconf"
      "plantuml"
      "powerlevel10k"
      "pyenv"
      "qrencode"
      "raylib"
      "rbenv"
      "reaver"
      "redis"
      "ruby"
      "serkanyersen/dotstate/dotstate"
      "smartmontools"
      "swi-prolog"
      "teamookla/speedtest/speedtest"
      "tesseract-lang"
      "thefuck"
      # Locked nixpkgs marks unar available on Darwin, but its Objective-C
      # linker currently crashes when building the aarch64-darwin package.
      "unar"
      # The locked Darwin build fails at link time and also injects a
      # Homebrew Samba library path, so this is not a clean Nix owner yet.
      "veeso/termscp/termscp"
      "zackelia/formulae/bclm"
      "zsh"
    ];

    casks = [
      "1password-cli@beta"
      "battery"
      "calibre"
      "copilot-cli"
      "d12frosted/emacs-plus/emacs-plus-app"
      "dotnet-sdk"
      "font-sf-mono"
      "font-sf-pro"
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
