{ pkgs, ... }:
{
  # Stable non-interactive fallback; an active FNM multishell remains
  # higher-priority for projects that deliberately select another Node.
  #
  # Codex and OpenCode are deliberately absent here: both are npm global
  # installs (@openai/codex, opencode-ai) at ~/.local/share/npm-global,
  # already ahead of the Nix profile on PATH, so their releases update
  # directly instead of through a flake bump. scripts/opencode-update.sh
  # is retained but no longer wired into any module.
  home.packages = [ pkgs.nodejs_24 ];
}
