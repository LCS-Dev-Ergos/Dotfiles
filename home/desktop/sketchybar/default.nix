{
  config,
  externalSources,
  lib,
  pkgs,
  ...
}:
let
  sketchybar = pkgs.callPackage ./package.nix { };
  nowplaying = pkgs.callPackage ../../cli/cli-tools/nowplaying-cli.nix { };
  statwell = config.services.statwell.package;
  sbarLua = pkgs.stdenv.mkDerivation {
    pname = "sbarlua";
    version = "unstable-2026-03-06";
    src = externalSources.sbarLua;

    dontConfigure = true;
    postPatch = ''
      substituteInPlace makefile \
        --replace-fail 'clang $(CFLAGS)' '$(CC) $(CFLAGS)'
    '';
    buildPhase = ''
      runHook preBuild
      mkdir -p bin
      make -C lua-5.5.0/src CC=cc SYSCFLAGS=-DLUA_USE_MACOSX liblua.a lua
      cp lua-5.5.0/src/liblua.a bin/liblua.a
      make CC=cc bin/sketchybar.so
      runHook postBuild
    '';
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      LUA_CPATH="$PWD/bin/?.so" lua-5.5.0/src/lua -e 'assert(require("sketchybar"))'
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      install -D -m 0755 bin/sketchybar.so "$out/lib/sketchybar.so"
      install -D -m 0755 lua-5.5.0/src/lua "$out/bin/lua"
      runHook postInstall
    '';
  };

  sketchybarAppFont = pkgs.fetchurl {
    url = "https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.5/sketchybar-app-font.ttf";
    hash = "sha256-nfJVICpaw1Q1jChc3feY39vjtS/fLJ3FKVGqOKhyzwA=";
  };

  # Compile the native menu helper in the Nix sandbox, then assemble the
  # exact config tree SketchyBar expects.
  sketchybarConfig = pkgs.stdenv.mkDerivation {
    pname = "sketchybar-config";
    version = "1";
    src = ./sketchybar;

    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      make -C helpers clean
      make -C helpers
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R ./. "$out/"
      substituteInPlace "$out/helpers/init.lua" \
        --replace-fail '@sbarlua@' '${sbarLua}/lib'
      substituteInPlace "$out/sketchybarrc" \
        --replace-fail '#!/usr/bin/env lua' '#!${sbarLua}/bin/lua'
      substituteInPlace "$out/helpers/runtime.lua" \
        --replace-fail '@nowplaying@' '${nowplaying}/bin/nowplaying-cli' \
        --replace-fail '@statwell@' '${lib.getExe statwell}' \
        --replace-fail '@network_interface@' ${
          lib.escapeShellArg (
            lib.optionalString (
              config.services.statwell.networkInterface != null
            ) config.services.statwell.networkInterface
          )
        } \
        --replace-fail '@package_timeout_ms@' '${toString config.services.statwell.packageTimeoutMs}' \
        --replace-fail '@switchaudio@' '${pkgs.switchaudio-osx}/bin/SwitchAudioSource' \
        --replace-fail '@python@' '${pkgs.python3}/bin/python3' \
        --replace-fail '@yabai@' '${lib.getExe pkgs.yabai}' \
        --replace-fail '@space_script@' '${config.home.homeDirectory}/.config/yabai/space.sh'
      runHook postInstall
    '';
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  home = {
    # The old bootstrap script installed this exact, checksum-verified font as a
    # regular user file. Home Manager now owns the same asset; force is limited
    # to that known generated target so the first migration can replace it.
    file."Library/Fonts/sketchybar-app-font.ttf" = {
      source = sketchybarAppFont;
      force = true;
    };

    packages = [ sketchybar ];

    # The initial user-service migration pins its closure until a complete
    # Home Manager activation takes over garbage-collection ownership.
    activation.retireSketchybarBootstrapRoot = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
      run rm -f ${lib.escapeShellArg "${config.xdg.stateHome}/sketchybar/bootstrap-gcroot"}
    '';
  };

  launchd.agents.sketchybar = {
    enable = true;
    config = {
      ProgramArguments = [
        (toString (
          pkgs.writeShellScript "start-sketchybar" ''
            mkdir -p ${lib.escapeShellArg "${config.xdg.stateHome}/sketchybar"}
            # A new immutable config has a different path. Retire providers from
            # preceding generations, which would otherwise survive a restart.
            /usr/bin/pkill -TERM -u "$(/usr/bin/id -u)" -f \
              '^/nix/store/[^/]+-sketchybar-config-[^/]+/helpers/event_providers/(cpu_load|network_load|brew_check)/bin/' || true
            exec ${sketchybar}/bin/sketchybar --config ${sketchybarConfig}/sketchybarrc \
              >> ${lib.escapeShellArg "${config.xdg.stateHome}/sketchybar/service.log"} 2>&1
          ''
        ))
      ];
      EnvironmentVariables.PATH = "${sketchybar}/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin";
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Interactive";
    };
  };

  xdg.configFile."sketchybar".source = sketchybarConfig;
}
