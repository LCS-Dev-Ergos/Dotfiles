{
  apple-sdk_26,
  lib,
  llvmPackages_22,
  runCommand,
  stdenv,
  symlinkJoin,
  writeShellScriptBin,
  darwinMinVersion ? "26.0",
}:
let
  inherit (llvmPackages_22) clang;
  clangUnwrapped = llvmPackages_22.clang-unwrapped;
  linker = clang.bintools.bintools;
  sdkRoot = apple-sdk_26.sdkroot;
  sdkVersion = apple-sdk_26.version;
  name = "llvm-${llvmPackages_22.llvm.version}-darwin-sdk-${apple-sdk_26.version}-min-${darwinMinVersion}";

  mkDriver =
    driverName: executable: extraArgs:
    writeShellScriptBin driverName ''
      target=
      next_is_target=
      for argument in "$@"; do
        if [[ -n "$next_is_target" ]]; then
          target="$argument"
          break
        fi
        case "$argument" in
          --target=*|-target=*)
            target="''${argument#*=}"
            break
            ;;
          --target|-target)
            next_is_target=1
            ;;
        esac
      done

      case "$target" in
        ""|*-apple-darwin*|*-apple-macos*)
          exec ${clang}/bin/${executable} \
            ${lib.escapeShellArgs extraArgs} \
            -isysroot ${lib.escapeShellArg sdkRoot} \
            -mmacosx-version-min=${lib.escapeShellArg darwinMinVersion} \
            "$@"
          ;;
        *)
          exec ${clangUnwrapped}/bin/${executable} \
            ${lib.escapeShellArgs extraArgs} \
            "$@"
          ;;
      esac
    '';

  # The stock cctools wrapper carries Nixpkgs' macOS 14 compatibility floor.
  # Use the same unwrapped linker as Clang and supply host defaults only when
  # the caller has not already selected a platform version or SDK.
  mkLinker = writeShellScriptBin "ld" ''
    have_platform_version=
    have_darwin_platform_version=
    have_darwin_sdk_version=
    have_syslibroot=

    for argument in "$@"; do
      case "$argument" in
        -platform_version)
          have_platform_version=1
          ;;
        -macos_version_min|-macosx_version_min)
          have_darwin_platform_version=1
          ;;
        -sdk_version)
          have_darwin_sdk_version=1
          ;;
        -syslibroot|-syslibroot=*)
          have_syslibroot=1
          ;;
      esac
    done

    platform_args=()
    if [[ -z "$have_platform_version" ]]; then
      if [[ -z "$have_darwin_platform_version" &&
            -z "$have_darwin_sdk_version" ]]; then
        platform_args=(
          -platform_version macos
          ${lib.escapeShellArg darwinMinVersion}
          ${lib.escapeShellArg sdkVersion}
        )
      elif [[ -z "$have_darwin_sdk_version" ]]; then
        platform_args=(-sdk_version ${lib.escapeShellArg sdkVersion})
      elif [[ -z "$have_darwin_platform_version" ]]; then
        platform_args=(
          -macos_version_min ${lib.escapeShellArg darwinMinVersion}
        )
      fi
    fi

    sysroot_args=()
    if [[ -z "$have_syslibroot" ]]; then
      sysroot_args=(-syslibroot ${lib.escapeShellArg sdkRoot})
    fi

    exec ${linker}/bin/ld \
      "''${sysroot_args[@]}" \
      "''${platform_args[@]}" \
      "$@"
  '';

  toolchain = lib.setPrio 5 (symlinkJoin {
    inherit name;
    paths = [
      (mkDriver "cc" "clang" [ ])
      (mkDriver "c++" "clang++" [ ])
      (mkDriver "clang" "clang" [ ])
      (mkDriver "clang++" "clang++" [ ])
      (mkDriver "cpp" "clang" [ "-E" ])
      mkLinker
    ];

    passthru = {
      inherit darwinMinVersion sdkRoot sdkVersion;
      tests.default = runCommand "${name}-check" { } ''
        export HOME="$TMPDIR"

        for driver in cc c++ clang clang++ cpp ld; do
          test -x "${toolchain}/bin/$driver"
        done

        diagnostics="$(
          ${toolchain}/bin/cc -### -c -x c /dev/null 2>&1
        )"
        printf '%s\n' "$diagnostics" \
          | grep -Fq -- '-apple-macosx${darwinMinVersion}.0'
        printf '%s\n' "$diagnostics" | grep -Fq -- '${sdkRoot}'

        ${toolchain}/bin/cc \
          -Werror=unused-command-line-argument \
          --target=wasm32 \
          -c -x c /dev/null \
          -o smoke.wasm.o

        printf '%s\n' 'int main(void) { return 0; }' > smoke.c
        ${toolchain}/bin/cc -c smoke.c -o smoke.o
        ${toolchain}/bin/ld \
          -arch ${lib.escapeShellArg stdenv.hostPlatform.darwinArch} \
          -lSystem \
          smoke.o \
          -o smoke-c
        linker_diagnostics="$(${linker}/bin/otool -l smoke-c)"
        printf '%s\n' "$linker_diagnostics" \
          | grep -Eq -- 'minos[[:space:]]+${darwinMinVersion}([.]0)?$'
        printf '%s\n' "$linker_diagnostics" \
          | grep -Eq -- 'sdk[[:space:]]+${sdkVersion}([.]0)?$'
        ./smoke-c

        printf '%s\n' \
          '#include <vector>' \
          'int main() { std::vector<int> values{1, 2, 3};' \
          '  return values.size() == 3 ? 0 : 1; }' \
          > smoke.cc
        ${toolchain}/bin/c++ -std=c++23 smoke.cc -o smoke
        ./smoke

        touch "$out"
      '';
    };

    meta = clang.meta // {
      description = "LLVM ${llvmPackages_22.llvm.version} with the macOS ${darwinMinVersion} target";
      mainProgram = "clang";
      platforms = lib.platforms.darwin;
    };
  });
in
assert lib.assertMsg stdenv.isDarwin "The Darwin LLVM toolchain requires macOS";
toolchain
