{
  darwin,
  gcc16,
  lib,
  llvmPackages_22,
  runCommand,
  stdenv,
  symlinkJoin,
  writeShellScriptBin,
  darwinMinVersion ? "26.0",
  # Where Home Manager publishes the relocated runtime libraries (see
  # `runtimeRelativeDir`). Left null, binaries keep referencing the store.
  homeDirectory ? null,
}:
let
  inherit (llvmPackages_22) clang;
  clangUnwrapped = llvmPackages_22.clang-unwrapped;
  clangTools = llvmPackages_22.clang-tools;
  gcc = gcc16;
  inherit (darwin) cctools sigtool;
  name = "host-toolchain-llvm-${llvmPackages_22.llvm.version}-gcc-${gcc.version}-macos-${darwinMinVersion}";

  # Links load Nix's LTO library, not the one bundled with Apple's linker: an
  # older libLTO rejects LLVM 22 bitcode ("invalid value for 'frame-pointer'").
  ltoLibrary = "${llvmPackages_22.llvm.lib}/lib/libLTO.dylib";

  # Binaries record the install name of every dylib they link. A store path
  # there breaks the binary as soon as a newer compiler lets the garbage
  # collector remove the old runtime, and nothing relinks it: the build system
  # still considers it up to date. The runtimes are therefore copied with an
  # install name under a directory Home Manager keeps pointed at the current
  # generation, the way Homebrew's `opt/gcc/lib/gcc/current` survives upgrades.
  runtimeRelativeDir = ".local/lib/nix-toolchain";
  runtimeDir = if homeDirectory == null then null else "${homeDirectory}/${runtimeRelativeDir}";

  relocateRuntime =
    runtimeName: source:
    if runtimeDir == null then
      source
    else
      runCommand "${name}-${runtimeName}-runtime"
        {
          # sigtool's codesign looks codesign_allocate up on PATH.
          nativeBuildInputs = [
            cctools
            sigtool
          ];
        }
        ''
          mkdir -p "$out"
          for entry in ${source}/*; do
            file="''${entry##*/}"
            if [[ -L "$entry" && "$(readlink "$entry")" != */* ]]; then
              # Same-directory aliases such as libstdc++.dylib -> libstdc++.6.dylib.
              ln -s "$(readlink "$entry")" "$out/$file"
            elif [[ "$file" == *.dylib ]]; then
              cp -L "$entry" "$out/$file"
              chmod u+w "$out/$file"
              # cctools, not llvm-install-name-tool: the latter rejects the
              # LC_REEXPORT_DYLIB stub GCC ships as libgcc_s.1.dylib.
              install_name_tool \
                -id ${lib.escapeShellArg "${runtimeDir}/${runtimeName}"}/"$file" "$out/$file"
              codesign -f -s - "$out/$file"
            else
              ln -s "$(readlink -f "$entry")" "$out/$file"
            fi
          done
        '';

  clangRuntime = relocateRuntime "clang" "${clang}/resource-root/lib/darwin";
  gccRuntime = relocateRuntime "gcc" "${lib.getLib gcc.cc}/lib";

  resourceRoot = runCommand "${name}-resource-root" { } ''
    mkdir -p "$out/lib"
    ln -s ${clang}/resource-root/include "$out/include"
    ln -s ${clang}/resource-root/share "$out/share"
    ln -s ${clangRuntime} "$out/lib/darwin"
  '';

  # Every driver compiles against the SDK of the active Apple developer
  # directory, unless an explicit sysroot or valid SDKROOT selects another.
  # The same precedence applies to Clang, GCC, tooling and the Apple fallback.
  # nixpkgs' apple-sdk cannot play that role on a workstation: it strips the
  # third-party libraries Apple bundles (zlib, sqlite, libxml2, curl, ...), and
  # its libc++ headers break C++ as soon as anything adds the real SDK's
  # include directory, which CMake's find_package does for exactly those
  # libraries. A DEVELOPER_DIR or SDKROOT pointing into the store belongs to a
  # Nix build environment, never to the host, so it is dropped on the way in.
  hostSdkLookup = ''
    case "''${DEVELOPER_DIR-}" in /nix/store/*) unset DEVELOPER_DIR ;; esac
    case "''${SDKROOT-}" in /nix/store/*) unset SDKROOT ;; esac

    resolve_host_sdk() {
      local developer_dir="''${DEVELOPER_DIR-}" candidate
      # Match the compiler convention: SDKROOT must name an existing absolute
      # directory other than /. Store SDKs have already been dropped above.
      case "''${SDKROOT-}" in
        /*)
          if [[ "$SDKROOT" != / && -d "$SDKROOT" ]]; then
            host_sdk="$SDKROOT"
            return 0
          fi
          ;;
      esac
      if [[ -z "$developer_dir" ]]; then
        developer_dir="$(/usr/bin/xcode-select --print-path 2>/dev/null)" ||
          developer_dir=
      fi
      for candidate in \
        "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
        "$developer_dir/SDKs/MacOSX.sdk" \
        /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk; do
        if [[ -r "$candidate/SDKSettings.json" ]]; then
          host_sdk="$candidate"
          return 0
        fi
      done
      echo "no macOS SDK found; install the Command Line Tools with xcode-select --install" >&2
      return 1
    }
  '';

  # /usr/bin/ld resolves Apple's linker through the active developer directory.
  # The shim fills in only what the caller left out: the SDK as syslibroot, the
  # platform policy, and the matching LTO library.
  #
  # GCC still states its policy with the legacy -macos_version_min. On its own
  # that makes the linker record the minimum as the SDK version too, and adding
  # -sdk_version beside it is rejected as obsolete, so the pair is rewritten
  # into the -platform_version form Clang uses. A caller that already gives an
  # -sdk_version has chosen both values and is left untouched.
  appleLinker = writeShellScriptBin "ld" ''
    ${hostSdkLookup}
    arguments=("$@")
    have_platform=
    have_sdk_version=
    have_syslibroot=
    sdk_root=
    have_lto_library=
    legacy_min_index=
    for ((index = 0; index < ''${#arguments[@]}; index++)); do
      case "''${arguments[index]}" in
        -platform_version)
          have_platform=1
          ;;
        -macos_version_min|-macosx_version_min)
          legacy_min_index=$index
          ;;
        -sdk_version)
          have_sdk_version=1
          ;;
        -syslibroot)
          have_syslibroot=1
          sdk_root="''${arguments[index + 1]-}"
          ;;
        -lto_library)
          have_lto_library=1
          ;;
      esac
    done
    if [[ -n "$legacy_min_index" && -n "$have_sdk_version" ]]; then
      have_platform=1
    fi

    extra_args=()
    if [[ -z "$have_syslibroot" ]]; then
      resolve_host_sdk || exit 1
      sdk_root="$host_sdk"
      extra_args+=(-syslibroot "$sdk_root")
    fi
    if [[ -z "$have_platform" ]]; then
      # An arbitrary explicit sysroot need not contain SDKSettings.json.
      # Record an unknown SDK in that case, never the unrelated host SDK.
      sdk_version=0.0
      if [[ -r "$sdk_root/SDKSettings.json" ]]; then
        sdk_settings="$(<"$sdk_root/SDKSettings.json")"
        if [[ "$sdk_settings" =~ \"Version\"[[:space:]]*:[[:space:]]*\"([0-9.]+)\" ]]; then
          sdk_version="''${BASH_REMATCH[1]}"
        fi
      fi
      min_version=${lib.escapeShellArg darwinMinVersion}
      if [[ -n "$legacy_min_index" ]]; then
        min_version="''${arguments[legacy_min_index + 1]-$min_version}"
        arguments=(
          "''${arguments[@]:0:legacy_min_index}"
          "''${arguments[@]:legacy_min_index + 2}"
        )
      fi
      extra_args+=(-platform_version macos "$min_version" "$sdk_version")
    fi
    if [[ -z "$have_lto_library" ]]; then
      extra_args+=(-lto_library ${lib.escapeShellArg ltoLibrary})
    fi

    exec /usr/bin/ld "''${extra_args[@]}" "''${arguments[@]}"
  '';

  # GCC and its utilities look their assembler and archive tools up by name.
  # Handing them Apple's keeps GCC objects and archives on the same policy as
  # Clang's, instead of whichever copy PATH reaches first.
  mkAppleTool =
    toolName:
    writeShellScriptBin toolName ''
      ${hostSdkLookup}
      exec /usr/bin/${toolName} "$@"
    '';
  # Both compilers run dsymutil after a `-g` link, looking it up by name. LLVM
  # 22's copy reads the debug information LLVM 22 emits, whichever dsymutil
  # the caller's PATH happens to reach first.
  debugSymbolUtility = runCommand "${name}-dsymutil" { } ''
    mkdir -p "$out/bin"
    ln -s ${llvmPackages_22.llvm}/bin/dsymutil "$out/bin/dsymutil"
  '';
  gccPrograms = symlinkJoin {
    name = "${name}-gcc-programs";
    paths = [
      appleLinker
      debugSymbolUtility
    ]
    ++ map mkAppleTool [
      "ar"
      "as"
      "nm"
      "ranlib"
    ];
  };

  # The newest macOS SDK major version whose .tbd stubs this LLD can read.
  # LLD 22 rejects SDK 27's arm64e.x1 targets as an unknown architecture. The
  # check fails once LLD reads a newer SDK, which is the cue to raise this.
  lldNewestSdkMajor = "26";

  mkClangDriver =
    driverName: executable: appleExecutable:
    writeShellScriptBin driverName ''
      ${hostSdkLookup}
      # Clang only recognises -cc1 as the very first argument.
      case "''${1-}" in
        -cc1*) exec ${clangUnwrapped}/bin/${executable} "$@" ;;
      esac

      target=
      next_is_target=
      next_is_arch=
      next_is_sysroot=
      will_link=${if driverName == "cpp" then "" else "1"}
      have_version=
      have_linker=
      requested_lld=
      have_sysroot=
      have_isysroot=
      sysroot=
      foreign_arch=
      for argument in "$@"; do
        if [[ -n "$next_is_target" ]]; then
          target="$argument"
          next_is_target=
          continue
        fi
        if [[ -n "$next_is_arch" ]]; then
          [[ "$argument" == arm64 ]] || foreign_arch=1
          next_is_arch=
          continue
        fi
        if [[ -n "$next_is_sysroot" ]]; then
          sysroot="$argument"
          next_is_sysroot=
          continue
        fi
        case "$argument" in
          --target=*|-target=*)
            target="''${argument#*=}"
            ;;
          --target|-target)
            next_is_target=1
            ;;
          -arch)
            next_is_arch=1
            ;;
          -c|-S|-E|-fsyntax-only|-M|-MM|-emit-ast|--precompile)
            will_link=
            ;;
          -mmacosx-version-min=*|-mmacos-version-min=*)
            have_version=1
            ;;
          -fuse-ld=lld)
            have_linker=1
            requested_lld=1
            ;;
          -fuse-ld=*|--ld-path=*)
            have_linker=1
            requested_lld=
            ;;
          -isysroot)
            have_sysroot=1
            have_isysroot=1
            next_is_sysroot=1
            ;;
          -isysroot?*)
            have_sysroot=1
            have_isysroot=1
            sysroot="''${argument#-isysroot}"
            ;;
          --sysroot)
            have_sysroot=1
            next_is_sysroot=1
            ;;
          --sysroot=*)
            have_sysroot=1
            sysroot="''${argument#--sysroot=}"
            ;;
        esac
      done

      # A versioned triple already carries a deployment target; adding ours
      # as well makes Clang report an overriding option.
      case "$target" in
        *-apple-macos[0-9]*|*-apple-macosx[0-9]*|*-apple-darwin[0-9]*)
          have_version=1
          ;;
      esac
      case "$target" in
        x86_64*-apple-*|i?86-apple-*|arm64e-apple-*)
          foreign_arch=1
          ;;
      esac

      case "$target" in
        ""|*-apple-darwin*|*-apple-macos*)
          policy_args=()
          if [[ -z "$have_version" ]]; then
            policy_args+=(-mmacosx-version-min=${lib.escapeShellArg darwinMinVersion})
          fi

          if [[ -z "$have_sysroot" ]]; then
            resolve_host_sdk || exit 1
            sysroot="$host_sdk"
          fi
          # Darwin Clang reads SDK version metadata from -isysroot, even
          # when --sysroot already supplies header and library paths. Supply
          # the same path for both spellings without replacing user flags.
          if [[ -z "$have_isysroot" && -n "$sysroot" ]]; then
            policy_args+=(-isysroot "$sysroot")
          fi

          # nixpkgs no longer builds x86_64-darwin, so its compiler-rt carries
          # only arm64. Apple's compiler is the one complete toolchain for
          # Intel and universal binaries, so those invocations go to it whole.
          if [[ -n "$foreign_arch" && -n ${lib.escapeShellArg appleExecutable} ]]; then
            exec /usr/bin/${appleExecutable} "''${policy_args[@]}" "$@"
          fi

          # An explicit -fuse-ld or --ld-path is the caller's decision;
          # Clang would silently drop it in favour of ours. The exception is
          # an LLD request against an SDK newer than this LLD can read: its
          # TAPI parser rejects the stubs outright, and projects ask for LLD
          # only as a faster linker, so Apple's serves that request instead.
          if [[ -n "$requested_lld" && -r "$sysroot/SDKSettings.json" ]]; then
            sdk_settings="$(<"$sysroot/SDKSettings.json")"
            if [[ "$sdk_settings" =~ \"Version\":\"([0-9]+) ]] &&
              (( BASH_REMATCH[1] > ${lldNewestSdkMajor} )); then
              have_linker=
            fi
          fi
          if [[ -n "$will_link" && -z "$have_linker" ]]; then
            policy_args+=(--ld-path=${appleLinker}/bin/ld)
          fi
          exec ${clangUnwrapped}/bin/${executable} \
            -resource-dir=${resourceRoot} \
            "''${policy_args[@]}" \
            "$@"
          ;;
        *)
          exec ${clangUnwrapped}/bin/${executable} "$@"
          ;;
      esac
    '';

  # GCC searches include-fixed, its fixincludes copies of the system headers
  # it had to rewrite while it was built, ahead of the sysroot. nixpkgs built
  # gcc16 against its SDK 14.4, so with any other SDK that directory shadows
  # the host's math.h with the 14.4 one. Run against the host SDK, the same
  # fixincludes rewrites nothing that matters -- the one fix left, in
  # math.h, is upstream in Apple's headers now, and check.nix keeps verifying
  # that -- so the drivers run GCC from a prefix whose include-fixed is empty.
  #
  # GCC_EXEC_PREFIX relocates the compiler there. Relocation also moves GCC's
  # private include directory ahead of the libstdc++ headers, because nixpkgs
  # installs those outside the GCC prefix; the spec gives them back their
  # usual place, in C++ compilations only, unless the caller opts out.
  gccTarget = stdenv.targetPlatform.config;
  gccPrefix = runCommand "${name}-gcc-prefix" { } ''
    source_dir=${gcc.cc}/lib/gcc/${gccTarget}/${gcc.version}
    target_dir="$out/lib/gcc/${gccTarget}/${gcc.version}"
    cxx_headers=${gcc.cc}/include/c++/${gcc.version}
    if [[ ! -d "$source_dir/include-fixed" || ! -d "$cxx_headers/${gccTarget}" ]]; then
      echo "unexpected GCC layout under ${gcc.cc}" >&2
      exit 1
    fi

    mkdir -p "$target_dir/include-fixed" "$out/share"
    for entry in ${gcc.cc}/lib/*; do
      [[ "''${entry##*/}" == gcc ]] || ln -s "$entry" "$out/lib/"
    done
    for entry in "$source_dir"/*; do
      [[ "''${entry##*/}" == include-fixed ]] || ln -s "$entry" "$target_dir/"
    done
    ln -s ${gcc.cc}/include "$out/include"
    ln -s ${gcc.cc}/libexec "$out/libexec"

    printf '%s\n' '*cc1plus:' \
      "+ %{!nostdinc:%{!nostdinc++:%{!stdlib=libc++:-isystem $cxx_headers -isystem $cxx_headers/${gccTarget} -isystem $cxx_headers/backward}}}" \
      "" > "$out/share/libstdcxx-headers.spec"
  '';

  # GCC's own fixincludes, built from the same source, for check.nix to rerun
  # against the host SDK. Only its two directories are unpacked: the whole
  # GCC tarball takes minutes to extract.
  gccFixincludes = stdenv.mkDerivation {
    pname = "gcc-fixincludes";
    inherit (gcc.cc) version src;
    # stdenv's bash crashes in fixupPhase on this host without a locale.
    env.LC_ALL = "C";
    unpackPhase = ''
      tar -xf "$src" --wildcards --no-wildcards-match-slash \
        'gcc-*/fixincludes' 'gcc-*/libiberty' 'gcc-*/include' 'gcc-*/config' \
        'gcc-*/config.guess' 'gcc-*/config.sub' 'gcc-*/install-sh' 'gcc-*/missing' \
        'gcc-*/mkinstalldirs' 'gcc-*/move-if-change' \
        'gcc-*/gcc/BASE-VER' 'gcc-*/gcc/DEV-PHASE' 'gcc-*/gcc/DATESTAMP'
      sourceRoot=$(echo gcc-*)
    '';
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      source_root=$PWD
      mkdir -p ../obj/libiberty ../obj/fixincludes
      (cd ../obj/libiberty && "$source_root/libiberty/configure" --disable-multilib && make)
      (cd ../obj/fixincludes && "$source_root/fixincludes/configure" --target=${gccTarget} && make)
      runHook postBuild
    '';
    installPhase = ''
      install -Dm755 ../obj/fixincludes/fixincl "$out/libexec/fixincl"
      install -Dm755 ../obj/fixincludes/fixinc.sh "$out/libexec/fixinc.sh"
    '';
  };

  mkGccDriver =
    driverName:
    writeShellScriptBin driverName ''
      ${hostSdkLookup}
      have_version=
      have_sysroot=
      next_is_sysroot=
      for argument in "$@"; do
        if [[ -n "$next_is_sysroot" ]]; then
          next_is_sysroot=
          continue
        fi
        case "$argument" in
          -mmacosx-version-min=*)
            have_version=1
            ;;
          -isysroot|--sysroot)
            have_sysroot=1
            next_is_sysroot=1
            ;;
          -isysroot?*|--sysroot=*)
            have_sysroot=1
            ;;
        esac
      done

      policy_args=(
        -specs=${gccPrefix}/share/libstdcxx-headers.spec
        -B${gccPrograms}/bin/
        -L${gccRuntime}
      )
      if [[ -z "$have_sysroot" ]]; then
        resolve_host_sdk || exit 1
        policy_args+=(-isysroot "$host_sdk")
      fi
      if [[ -z "$have_version" ]]; then
        policy_args+=(-mmacosx-version-min=${lib.escapeShellArg darwinMinVersion})
      fi
      GCC_EXEC_PREFIX=${gccPrefix}/lib/gcc/ exec ${gcc.cc}/bin/${driverName} \
        "''${policy_args[@]}" "$@"
    '';

  # GCC's own utilities, which its nixpkgs wrapper does not expose. CMake looks
  # for gcc-ar-<major> before gcc-ar next to the compiler and then on PATH, so
  # without the versioned names a GCC LTO build would archive with Homebrew's
  # gcc-ar from a different release. Each runs by its store path, from which
  # GCC locates its LTO plugin, with the same helper programs as the drivers.
  gccTools =
    let
      major = lib.versions.major gcc.version;
      tools = [
        "gcov"
        "gcov-dump"
        "gcov-tool"
        "lto-dump"
      ];
      versionedTools = [
        "gcc-ar"
        "gcc-nm"
        "gcc-ranlib"
      ];
    in
    runCommand "${name}-gcc-tools" { } ''
      mkdir -p "$out/bin"
      wrap() {
        printf '#!%s\nPATH=%s:"$PATH" exec %s "$@"\n' \
          ${lib.escapeShellArg stdenv.shell} \
          ${lib.escapeShellArg "${gccPrograms}/bin"} \
          "${gcc.cc}/bin/$1" > "$out/bin/$2"
        chmod +x "$out/bin/$2"
      }
      for tool in ${lib.escapeShellArgs tools}; do
        wrap "$tool" "$tool"
      done
      for tool in ${lib.escapeShellArgs versionedTools}; do
        wrap "$tool" "$tool"
        wrap "$tool" "$tool-${major}"
      done
    '';

  # The clang-tools wrappers point libTooling at nixpkgs' libc and libc++
  # headers through CPATH. Next to the host SDK those headers break every C++
  # translation unit ("reference to unresolved using declaration"), so each
  # tool runs unwrapped with the host SDK instead, like the compiler it models.
  hostClangTools = runCommand "${name}-clang-tools" { } ''
    mkdir -p "$out/bin"
    for tool in ${clangTools}/bin/*; do
      tool_name="''${tool##*/}"
      case "$tool_name" in
        *-unwrapped) continue ;;
      esac
      if [[ -x "${clangTools}/bin/$tool_name-unwrapped" ]]; then
        {
          printf '#!%s\n' ${lib.escapeShellArg stdenv.shell}
          printf '%s\n' ${lib.escapeShellArg hostSdkLookup}
          printf '%s\n' 'if resolve_host_sdk; then'
          printf '%s\n' '  export SDKROOT="$host_sdk"'
          printf '%s\n' 'fi'
          printf 'exec %s "$@"\n' "${clangTools}/bin/$tool_name-unwrapped"
        } > "$out/bin/$tool_name"
        chmod +x "$out/bin/$tool_name"
      else
        ln -s "$tool" "$out/bin/$tool_name"
      fi
    done
  '';

  runtimeLinks = runCommand "${name}-runtime-links" { } ''
    mkdir -p "$out/runtime"
    ln -s ${clangRuntime} "$out/runtime/clang"
    ln -s ${gccRuntime} "$out/runtime/gcc"
  '';

  toolchain = lib.setPrio 5 (symlinkJoin {
    inherit name;
    paths = [
      (mkClangDriver "cc" "clang" "clang")
      (mkClangDriver "c++" "clang++" "clang++")
      (mkClangDriver "clang" "clang" "clang")
      (mkClangDriver "clang++" "clang++" "clang++")
      (mkClangDriver "cpp" "clang-cpp" "")
      (mkGccDriver "gcc")
      (mkGccDriver "g++")
      gccTools
      # Joined deliberately, not just referenced through --ld-path above. Both
      # llvmPackages_22.clang and gcc16 ship a bin/ld of their own, and it is
      # the cctools wrapper this package exists to bypass. Without this entry
      # winning at priority 5, a bare `ld` on PATH would be exactly the linker
      # that produces the incompatible host-native objects.
      appleLinker
      debugSymbolUtility
      hostClangTools
      runtimeLinks
    ];

    passthru = {
      inherit
        darwinMinVersion
        gcc
        runtimeDir
        runtimeRelativeDir
        ;
      tests.default = runCommand "${name}-check" { } (
        import ./check.nix {
          inherit
            cctools
            clangRuntime
            darwinMinVersion
            gccRuntime
            lib
            lldNewestSdkMajor
            runtimeDir
            toolchain
            ;
          inherit (llvmPackages_22) lld;
          appleLinker = "${appleLinker}/bin/ld";
          inherit gccFixincludes gccTarget;
          gccVersion = gcc.version;
          hostArch = stdenv.hostPlatform.darwinArch;
        }
      );
    };

    meta = clang.meta // {
      description = "LLVM ${llvmPackages_22.llvm.version} and GCC ${gcc.version} drivers for host-native macOS ${darwinMinVersion} builds";
      mainProgram = "clang";
      platforms = lib.platforms.darwin;
    };
  });
in
assert lib.assertMsg stdenv.hostPlatform.isDarwin "The Darwin host toolchain requires macOS";
toolchain
