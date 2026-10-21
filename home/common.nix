_: {
  # Platform-neutral layer imported by every host. Each category directory
  # imports only its cross-platform modules; a module may remain there only
  # when its platform-specific options/packages are gated internally.
  # Platform-only modules, whatever their category, are selected by
  # darwin.nix or linux.nix; desktop/shared holds the common font policy.
  imports = [
    ./apps
    ./cli
    ./dev
    ./desktop/shared/fonts
    ./editors
    ./file-managers
    ./multiplexers
    ./ricing
    ./shells
    ./terminals
  ];
}
