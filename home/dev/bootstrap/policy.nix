# Literal argv and ownership policy. Runtime paths are bound by the executor.
{ baseline }:
{
  repositoryName = "lcs-baseline-${baseline.ocaml.revision}-nix";
  upstreamName = "lcs-upstream";
  upstreamUrl = "https://opam.ocaml.org";
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
    nodeInstall = [
      "--fnm-dir"
      "{staging}"
      "--node-dist-mirror"
      "{mirror}"
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
    opamHooks = [
      "init"
      "--reinit"
      "--bare"
      "--no-setup"
      "--no-opamrc"
      "--enable-shell-hook"
      "--shell=zsh"
    ];
    pythonBuild = [
      "{definition}"
      "{target}"
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
      "{name}"
      "{url}"
    ];
    opamCreate = [
      "switch"
      "create"
      "{switch}"
      "ocaml-base-compiler.{version}"
      "--no-switch"
      "--no-depexts"
      "--require-checksums"
      "--repositories={name}"
    ];
    opamRegister = [
      "repository"
      "add"
      "{name}"
      "{url}"
      "--dont-select"
    ];
    opamSelectSwitch = [
      "repository"
      "set-repos"
      "{name}"
      "--on-switches={switch}"
    ];
    opamSelectDefault = [
      "repository"
      "set-repos"
      "{name}"
      "--set-default"
    ];
    opamList = [
      "repository"
      "list"
      "--short"
    ];
    opamListAll = [
      "repository"
      "list"
      "--all"
    ];
  };
}
