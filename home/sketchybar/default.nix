{
  externalSources,
  lib,
  pkgs,
  ...
}:
let
  nowplaying = pkgs.callPackage ../cli-tools/nowplaying-cli.nix { };
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

  # Compile all four native helpers in the Nix sandbox, then assemble the
  # exact config tree SketchyBar expects. The source checkout contains no
  # architecture-specific binaries; each Darwin host builds its own output.
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
        --replace-fail '@switchaudio@' '${pkgs.switchaudio-osx}/bin/SwitchAudioSource' \
        --replace-fail '@python@' '${pkgs.python3}/bin/python3'
      runHook postInstall
    '';
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  # The old bootstrap script installed this exact, checksum-verified font as a
  # regular user file. Home Manager now owns the same asset; force is limited
  # to that known generated target so the first migration can replace it.
  home.file."Library/Fonts/sketchybar-app-font.ttf" = {
    source = sketchybarAppFont;
    force = true;
  };

  # Keep service ownership with the existing Homebrew launchd integration;
  # Home Manager supplies only the immutable config and native helper closure.
  xdg.configFile."sketchybar".source = sketchybarConfig;
}
