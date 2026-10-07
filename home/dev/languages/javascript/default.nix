{
  lib,
  pkgs,
  runtimeManagerBackend,
  nativeFnmReady,
  ...
}:
{
  # Stable non-interactive fallback; an active FNM multishell remains
  # higher-priority for projects that deliberately select another Node.
  #
  # Codex and OpenCode are deliberately absent here: Codex is its own
  # standalone binary in ~/.local/bin, OpenCode an npm global install
  # (opencode-ai) at ~/.local/share/npm-global; both sit ahead of the Nix
  # profile on PATH, so their releases update directly instead of through a
  # flake bump. scripts/opencode-update.sh is retained but no longer wired
  # into any module.
  #
  # Native hosts transfer FNM only after the replacement has been verified.
  # Keep the old manager during this explicit transition. NixOS consumers
  # select the nixpkgs backend and retain its platform-compatible package.
  home.packages = [
    pkgs.nodejs_24
  ]
  ++ lib.optionals (runtimeManagerBackend == "nixpkgs" || !nativeFnmReady) [ pkgs.fnm ];
}
