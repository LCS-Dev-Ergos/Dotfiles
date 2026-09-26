_: {
  programs.oh-my-posh = {
    enable = true;
    # Not using settings = builtins.fromJSON ...: one theme segment has a
    # template field whose value is the JSON escape sequence for a NUL
    # character. That's valid JSON and something oh-my-posh's own Go
    # parser handles fine, but Nix strings cannot contain NUL bytes at
    # all -- fromJSON hard-errors trying to decode it. Linking the raw
    # file sidesteps Nix's string handling entirely.
    # zsh's prompt fallback chain (starship -> oh-my-posh -> p10k -> plain)
    # always picks starship first when it's available, which it is. Every
    # enableXIntegration stays off so Home Manager doesn't auto-wire a
    # second, conflicting prompt initializer into fish/nushell alongside
    # starship's already-active one.
    enableZshIntegration = false;
    enableFishIntegration = false;
    enableNushellIntegration = false;
    enableBashIntegration = false;
  };

  xdg.configFile."oh-my-posh/lcs-dev.omp.json".source = ./lcs-dev.omp.json;
}
