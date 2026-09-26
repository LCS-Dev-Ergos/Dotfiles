_: {
  # Platform-neutral layer imported by every host. Each category directory
  # imports only its cross-platform modules; a module may remain there only
  # when its platform-specific options/packages are gated internally.
  # Platform-only modules, whatever their category, are selected by
  # darwin.nix or linux.nix. desktop/ holds nothing but those, so it has no
  # default.nix of its own.
  imports = [
    ./cli
    ./dev
    ./editors
    ./file-managers
    ./multiplexers
    ./ricing
    ./shells
    ./terminals
  ];
}
