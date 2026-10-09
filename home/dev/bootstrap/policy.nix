# Literal argv and ownership policy. Runtime paths are bound by the executor.
{
  # Manager CLI floors: the declared argv relies on these releases' options.
  # Runtime selections have no floor; native managers own downgrades too.
  managerMinimums = {
    node = "1.39.0";
    python = "2.0.0";
    ocaml = "2.1.0";
  };
  timeouts = {
    node = 1800;
    python = 7200;
    ocaml = 7200;
    repository = 1800;
  };
  commands = {
    # Name the upstream explicitly; an inherited mirror setting must not
    # redirect the download.
    nodeInstall = [
      "--fnm-dir"
      "{staging}"
      "--node-dist-mirror"
      "https://nodejs.org/dist"
      "install"
      "{version}"
      "--progress"
      "never"
    ];
    nodeDefault = [
      "--fnm-dir"
      "{root}"
      "default"
      "{version}"
    ];
    pythonDefault = [
      "global"
      "{version}"
    ];
    opamDefault = [
      "switch"
      "set"
      "{switch}"
    ];
    opamRemove = [
      "switch"
      "remove"
      "{switch}"
    ];
    opamHooks = [
      "init"
      "--reinit"
      "--bare"
      "--no-setup"
      "--no-opamrc"
      "--enable-shell-hook"
      "--shell=zsh"
    ];
    pythonDefinitions = [
      "install"
      "--list"
    ];
    pythonInstall = [
      "install"
      "{version}"
    ];
    pythonRehash = [ "rehash" ];
    opamCommon = [
      "--cli=2.1"
      "--root"
      "{root}"
      "--no-self-upgrade"
      "--color=never"
      "--yes"
    ];
    opamInit = [
      "init"
      "--bare"
      "--no-setup"
      "--no-opamrc"
      "--enable-shell-hook"
      "--shell=zsh"
    ];
    opamCreate = [
      "switch"
      "create"
      "{switch}"
      "ocaml-base-compiler.{version}"
      "--no-switch"
      "--no-depexts"
      "--require-checksums"
    ];
  };
}
