{
  config,
  lib,
  pkgs,
  ...
}:
let
  atuinDatabase = "${config.xdg.dataHome}/atuin/history.db";
in
{
  programs.atuin = {
    enable = true;
  };

  # Reject a generation whose Atuin binary cannot read the existing history
  # before Home Manager changes any symlinks. The candidate runs only against
  # a SQLite backup, so a failed activation can neither migrate nor corrupt
  # the real database.
  home.activation.checkAtuinDatabaseCompatibility = lib.hm.dag.entryBefore [ "linkGeneration" ] ''
    atuin_database=${lib.escapeShellArg atuinDatabase}
    if [[ -f "$atuin_database" ]]; then
      compatibility_directory="$(${pkgs.coreutils}/bin/mktemp -d "''${TMPDIR:-/tmp}/atuin-compatibility.XXXXXX")"
      cleanup() {
        ${pkgs.coreutils}/bin/rm -rf "$compatibility_directory"
      }
      trap cleanup EXIT HUP INT TERM

      ${pkgs.sqlite}/bin/sqlite3 "$atuin_database" ".backup '$compatibility_directory/history.db'"
      ${pkgs.coreutils}/bin/mkdir -p "$compatibility_directory/config"
      printf 'db_path = "%s"\n' "$compatibility_directory/history.db" \
        > "$compatibility_directory/config/config.toml"

      if ! ATUIN_CONFIG_DIR="$compatibility_directory/config" \
        ${lib.getExe config.programs.atuin.package} info >/dev/null 2>&1; then
        printf '%s\n' \
          'Atuin activation aborted: the candidate version cannot read the existing history database.' \
          'Update Atuin to a compatible version before switching generations.' \
          >&2
        exit 1
      fi
    fi
  '';

  # Atuin's startup, shell initialization, and ordinary read paths leave this
  # file unchanged. Deploy the reviewed TOML directly from the store so a Nix
  # generation owns configuration changes and rollback. `atuin config set` is
  # intentionally not the durable update path; edit this source and switch.
  xdg.configFile."atuin/config.toml".source = ./config.toml;

  # config.toml's [theme] name = "tokyonight" references this file; atuin
  # doesn't have a dedicated Home Manager option for it, so it's placed
  # directly at its expected path.
  xdg.configFile."atuin/themes/tokyonight.toml".source = ./themes/tokyonight.toml;
}
