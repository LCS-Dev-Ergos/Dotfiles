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

  # The font and its application-name map come from one release, so every
  # ligature the map names exists in the installed font.
  sketchybarAppFontRelease = "https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v3.0.5";
  sketchybarAppFont = pkgs.fetchurl {
    url = "${sketchybarAppFontRelease}/sketchybar-app-font.ttf";
    hash = "sha256-Srq4jhiG9pi+Q1CGzgzTD6UjIRHFQHnX0kR8Z8oRrss=";
  };
  sketchybarAppIconMap = pkgs.fetchurl {
    url = "${sketchybarAppFontRelease}/icon_map.lua";
    hash = "sha256-tBgPE8smsD48sJ5VTFQG9Se0nr3zGrpD/6ckyZ9OcVs=";
  };
  # macOS does not register a font that is a symlink into the store.
  # Home Manager copies the share/fonts of home.packages into ~/Library/Fonts/HomeManager
  # instead, so the font travels as a package.
  sketchybarAppFontPackage = pkgs.runCommand "sketchybar-app-font" { } ''
    install -D -m 0444 ${sketchybarAppFont} "$out/share/fonts/truetype/sketchybar-app-font.ttf"
  '';
  installedAppFont = "${config.home.homeDirectory}/Library/Fonts/HomeManager/truetype/sketchybar-app-font.ttf";

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
      install -m 0444 ${sketchybarAppIconMap} "$out/helpers/app_icon_map.lua"
      substituteInPlace "$out/helpers/init.lua" \
        --replace-fail '@sbarlua@' '${sbarLua}/lib'
      substituteInPlace "$out/sketchybarrc" \
        --replace-fail '#!/usr/bin/env lua' '#!${sbarLua}/bin/lua'
      substituteInPlace "$out/helpers/runtime.lua" \
        --replace-fail '@nowplaying@' '${nowplaying}/bin/nowplaying-cli' \
        --replace-fail '@statwell@' '${lib.getExe statwell}' \
        --replace-fail '@runtime_dir@' ${
          lib.escapeShellArg (
            if config.services.statwell.runtimeDir == null then "" else config.services.statwell.runtimeDir
          )
        } \
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
        --replace-fail '@space_script@' '${config.home.homeDirectory}/.config/yabai/space.sh' \
        --replace-fail '@navfx_script@' '${config.home.homeDirectory}/.config/yabai/navfx.sh'
      runHook postInstall
    '';

    # The widgets read StatWell's cache with `snapshot --cached-only` and ask
    # for package checks with `refresh`. A StatWell without them answers every
    # call with exit 2, which the bar can only show as a lost connection, so
    # we refuse to build against it. An empty runtime directory makes both
    # commands fail with 1 (no daemon) once their arguments are accepted.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      probe="$TMPDIR/statwell-contract"
      mkdir -m 0700 "$probe"
      for command in "snapshot --cached-only" "refresh --provider homebrew"; do
        status=0
        # shellcheck disable=SC2086
        ${lib.getExe statwell} $command --runtime-dir "$probe" >/dev/null 2>&1 || status=$?
        if [ "$status" -eq 2 ]; then
          echo "StatWell at ${statwell} rejects 'statwell $command'; SketchyBar needs it" >&2
          exit 1
        fi
      done
      # The Desktop pills resolve application names through the release's map.
      ${sbarLua}/bin/lua -e "package.path = '$out/?.lua;' .. package.path
        local icons = require('helpers.app_icons')
        assert(icons.Claude == ':claude:' and icons.ChatGPT == ':openai:' and icons.default == ':default:',
          'the application icon map is missing or incomplete')"
      runHook postInstallCheck
    '';
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  home = {
    packages = [
      sketchybar
      sketchybarAppFontPackage
    ];

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
            # SketchyBar resolves fonts once, when an item is created, and a
            # font it cannot find becomes Helvetica, which shows ligatures as
            # their names. The font's store path makes this script change with
            # the font, so Home Manager restarts the agent; we then wait for
            # its copy of this exact font, which may land after the restart,
            # and give the font daemon a moment to register it.
            for _ in $(seq 1 30); do
              if /usr/bin/cmp -s ${lib.escapeShellArg installedAppFont} ${sketchybarAppFont}; then
                sleep 1
                break
              fi
              sleep 1
            done
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
