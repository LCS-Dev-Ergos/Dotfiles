{
  # home/cc-toolchain.nix applied to pkgs. Deliberately not named after a
  # package set attribute: callPackage would silently fill `llvmPackages` or
  # `gcc` with nixpkgs' defaults, whereas a missing `ccToolchain` fails.
  ccToolchain,
  coreutils,
  darwin,
  findutils,
  gnugrep,
  gnused,
  lib,
  runCommand,
  runtimeShell,
  shellcheck-minimal,
  stdenv,
  symlinkJoin,
  writeTextFile,
  # Where Home Manager publishes the relocated runtime libraries (see
  # `runtimeRelativeDir`); null keeps binaries referencing the store. There is
  # no default, so every caller states which of the two it builds.
  homeDirectory,
}:
let
  inherit (ccToolchain) llvmPackages gcc;
  inherit (llvmPackages) clang lld;
  clangUnwrapped = llvmPackages.clang-unwrapped;
  clangTools = llvmPackages.clang-tools;
  inherit (darwin) cctools sigtool;
  inherit (builtins) storeDir;
  deploymentTarget = ccToolchain.darwinDeploymentTarget;
  llvmMajor = lib.versions.major llvmPackages.llvm.version;
  lldNewestSdkMajor = toString ccToolchain.lld.newestSdkMajor;
  hostArch = stdenv.hostPlatform.darwinArch;
  name = "host-toolchain-llvm-${llvmPackages.llvm.version}-gcc-${gcc.version}-macos-${deploymentTarget}";

  # Every generated script is linted as it is written: a quoting mistake in a
  # compiler driver surfaces only for the one argument that happens to contain
  # a space, long after the build that introduced it.
  shellcheck = "${lib.getExe shellcheck-minimal} --shell=bash";
  writeCheckedScriptBin =
    scriptName: text:
    writeTextFile {
      name = scriptName;
      executable = true;
      destination = "/bin/${scriptName}";
      text = ''
        #!${runtimeShell}
        ${text}
      '';
      checkPhase = ''
        ${stdenv.shellDryRun} "$target"
        ${shellcheck} "$target"
      '';
      meta.mainProgram = scriptName;
    };

  # Links load Nix's LTO library, not the one bundled with Apple's linker: an
  # older libLTO rejects LLVM 22 bitcode ("invalid value for 'frame-pointer'").
  ltoLibrary = "${llvmPackages.llvm.lib}/lib/libLTO.dylib";

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
  dropStoreSdk = ''
    case "''${DEVELOPER_DIR-}" in ${storeDir}/*) unset DEVELOPER_DIR ;; esac
    case "''${SDKROOT-}" in ${storeDir}/*) unset SDKROOT ;; esac
  '';

  # Both functions return through globals, so not every script that shares
  # them reads every variable they set.
  hostSdkFunctions = ''
    # Sets host_sdk, and host_sdk_explicit when SDKROOT chose it rather than
    # the developer directory.
    # shellcheck disable=SC2034
    resolve_host_sdk() {
      local developer_dir="''${DEVELOPER_DIR-}" candidate
      host_sdk_explicit=
      # Match the compiler convention: SDKROOT must name an existing absolute
      # directory other than /. Store SDKs have already been dropped above.
      case "''${SDKROOT-}" in
        /*)
          if [[ "$SDKROOT" != / && -d "$SDKROOT" ]]; then
            host_sdk="$SDKROOT"
            host_sdk_explicit=1
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

    # Sets sdk_version to the version an SDK's SDKSettings.json declares, and
    # fails when the file is missing or no longer has the shape parsed here.
    # The one parser every driver and the check share; check.nix compares its
    # answer with the SDK's SystemVersion.plist.
    # shellcheck disable=SC2034
    read_sdk_version() {
      local settings="" pattern='"Version"[[:space:]]*:[[:space:]]*"([0-9]+([.][0-9]+)*)"'
      sdk_version=
      [[ -r "$1/SDKSettings.json" ]] || return 1
      IFS= read -r -d "" settings <"$1/SDKSettings.json" || true
      [[ "$settings" =~ $pattern ]] || return 1
      sdk_version="''${BASH_REMATCH[1]}"
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
  appleLinker = writeCheckedScriptBin "ld" ''
    ${dropStoreSdk}
    ${hostSdkFunctions}
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
    sdk_chosen_by_caller=1
    if [[ -z "$have_syslibroot" ]]; then
      resolve_host_sdk || exit 1
      sdk_root="$host_sdk"
      sdk_chosen_by_caller="$host_sdk_explicit"
      extra_args+=(-syslibroot "$sdk_root")
    fi
    if [[ -z "$have_platform" ]]; then
      if ! read_sdk_version "$sdk_root"; then
        # A root the caller chose need not describe itself: record an
        # unknown SDK then, never the unrelated host one. The developer
        # directory's SDK always does, so failing to read it means Apple
        # changed SDKSettings.json, and a guess would mislabel every binary.
        if [[ -z "$sdk_chosen_by_caller" ]]; then
          echo "ld: cannot read the SDK version of $sdk_root" >&2
          exit 1
        fi
        sdk_version=0.0
      fi
      min_version=${lib.escapeShellArg deploymentTarget}
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
    writeCheckedScriptBin toolName ''
      ${dropStoreSdk}
      exec /usr/bin/${toolName} "$@"
    '';
  # Both compilers run dsymutil after a `-g` link, looking it up by name. The
  # driver's own LLVM reads the debug information it emits, whichever dsymutil
  # the caller's PATH happens to reach first.
  debugSymbolUtility = runCommand "${name}-dsymutil" { } ''
    mkdir -p "$out/bin"
    ln -s ${llvmPackages.llvm}/bin/dsymutil "$out/bin/dsymutil"
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

  # appleExecutable names the Apple compiler that takes over foreign
  # architectures; the preprocessor has none, since preprocessing needs no
  # compiler-rt and stays on this LLVM for every architecture.
  mkClangDriver =
    driverName: executable: appleExecutable:
    let
      delegatesForeignArch = appleExecutable != "";
    in
    writeCheckedScriptBin driverName ''
      ${dropStoreSdk}
      ${hostSdkFunctions}
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
      use_linker=
      have_ld_path=
      have_sysroot=
      have_isysroot=
      sysroot=
      ${lib.optionalString delegatesForeignArch "foreign_arch="}
      for argument in "$@"; do
        if [[ -n "$next_is_target" ]]; then
          target="$argument"
          next_is_target=
          continue
        fi
        if [[ -n "$next_is_arch" ]]; then
          ${lib.optionalString delegatesForeignArch ''[[ "$argument" == ${hostArch} ]] || foreign_arch=1''}
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
          -fuse-ld=*)
            use_linker="''${argument#-fuse-ld=}"
            ;;
          --ld-path=*)
            have_ld_path=1
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
      ${lib.optionalString delegatesForeignArch ''
        case "$target" in
          x86_64*-apple-*|i?86-apple-*|arm64e-apple-*)
            foreign_arch=1
            ;;
        esac
      ''}

      case "$target" in
        ""|*-apple-darwin*|*-apple-macos*)
          policy_args=()
          if [[ -z "$have_version" ]]; then
            policy_args+=(-mmacosx-version-min=${lib.escapeShellArg deploymentTarget})
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
          ${lib.optionalString delegatesForeignArch ''

            # nixpkgs no longer builds x86_64-darwin, so its compiler-rt
            # carries only arm64. Apple's compiler is the one complete
            # toolchain for Intel and universal binaries, so those
            # invocations go to it whole.
            if [[ -n "$foreign_arch" ]]; then
              exec /usr/bin/${appleExecutable} "''${policy_args[@]}" "$@"
            fi
          ''}
          # An explicit --ld-path, or -fuse-ld naming another linker, is the
          # caller's decision; Clang would silently drop it in favour of ours.
          # -fuse-ld=lld gets this LLVM's own LLD by path -- Clang's pairing
          # for "this --ld-path is LLD" -- rather than whichever ld64.lld PATH
          # reaches first, so it needs nothing on PATH and LTO bitcode never
          # meets another LLVM release's linker. The exception is an SDK newer
          # than that LLD can read: its TAPI parser rejects the stubs outright,
          # and projects ask for LLD only as a faster linker, so the request is
          # dropped and Apple's linker serves it like any other link.
          link_args=("$@")
          if [[ -n "$will_link" && -z "$have_ld_path" ]]; then
            case "$use_linker" in
              "")
                policy_args+=(--ld-path=${appleLinker}/bin/ld)
                ;;
              lld)
                if read_sdk_version "$sysroot" &&
                  (( ''${sdk_version%%.*} > ${lldNewestSdkMajor} )); then
                  link_args=()
                  for argument in "$@"; do
                    [[ "$argument" == -fuse-ld=* ]] || link_args+=("$argument")
                  done
                  policy_args+=(--ld-path=${appleLinker}/bin/ld)
                else
                  policy_args+=(--ld-path=${lld}/bin/ld64.lld)
                fi
                ;;
            esac
          fi
          exec ${clangUnwrapped}/bin/${executable} \
            -resource-dir=${resourceRoot} \
            "''${policy_args[@]}" \
            "''${link_args[@]}"
          ;;
        *)
          exec ${clangUnwrapped}/bin/${executable} "$@"
          ;;
      esac
    '';

  # GCC searches include-fixed, its fixincludes copies of the system headers
  # it had to rewrite while it was built, ahead of the sysroot. nixpkgs builds
  # GCC against its own, older SDK, so with any other SDK that directory
  # shadows the host's math.h with that one. Run against the host SDK, the same
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
    writeCheckedScriptBin driverName ''
      ${dropStoreSdk}
      ${hostSdkFunctions}
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
        policy_args+=(-mmacosx-version-min=${lib.escapeShellArg deploymentTarget})
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
          ${lib.escapeShellArg runtimeShell} \
          ${lib.escapeShellArg "${gccPrograms}/bin"} \
          "${gcc.cc}/bin/$1" > "$out/bin/$2"
        chmod +x "$out/bin/$2"
        ${shellcheck} "$out/bin/$2"
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
          printf '#!%s\n' ${lib.escapeShellArg runtimeShell}
          printf '%s\n' ${lib.escapeShellArg (dropStoreSdk + hostSdkFunctions)}
          printf '%s\n' 'if resolve_host_sdk; then'
          printf '%s\n' '  export SDKROOT="$host_sdk"'
          printf '%s\n' 'fi'
          printf 'exec %s "$@"\n' "${clangTools}/bin/$tool_name-unwrapped"
        } > "$out/bin/$tool_name"
        chmod +x "$out/bin/$tool_name"
        ${shellcheck} "$out/bin/$tool_name"
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

  # The facts a passing check holds for. Each of them can change without Nix
  # rebuilding anything -- an Xcode, Command Line Tools or macOS update -- so
  # cc-toolchain-check compares them with those of the last verification.
  fingerprintFunctions = ''
    # Sets REPLY to a string value of an XML property list.
    plist_value() {
      local plist="" pattern="<key>$2</key>[[:space:]]*<string>([^<]*)</string>"
      REPLY=
      [[ -r "$1" ]] || return 1
      IFS= read -r -d "" plist <"$1" || true
      [[ "$plist" =~ $pattern ]] || return 1
      REPLY="''${BASH_REMATCH[1]}"
    }

    # Sets REPLY to the project version of Apple's linker, such as ld-1221.4.
    apple_linker_version() {
      local banner pattern='PROJECT:([^[:space:]]+)'
      REPLY=unknown
      banner="$(/usr/bin/ld -v 2>&1)" || return 1
      [[ "$banner" =~ $pattern ]] || return 1
      REPLY="''${BASH_REMATCH[1]}"
    }

    # Prints the fingerprint of a verification against the SDK at $1.
    fingerprint() {
      local sdk_build=unknown linker macos=unknown
      read_sdk_version "$1" || sdk_version=unknown
      if plist_value "$1/System/Library/CoreServices/SystemVersion.plist" ProductBuildVersion; then
        sdk_build="$REPLY"
      fi
      apple_linker_version || true
      linker="$REPLY"
      if plist_value /System/Library/CoreServices/SystemVersion.plist ProductVersion; then
        macos="$REPLY"
        if plist_value /System/Library/CoreServices/SystemVersion.plist ProductBuildVersion; then
          macos+=" ($REPLY)"
        fi
      fi
      printf '%s=%s\n' \
        toolchain ${toolchain} \
        sdk "$1" \
        sdk-version "$sdk_version" \
        sdk-build "$sdk_build" \
        linker "$linker" \
        macos "$macos"
    }
  '';

  # The smoke tests as a program, so the same script runs inside a Nix build
  # and by hand against the live host.
  checkRunner = writeTextFile {
    name = "${name}-check-runner";
    executable = true;
    destination = "/bin/cc-toolchain-check-run";
    text = import ./check.nix {
      inherit
        cctools
        clangRuntime
        coreutils
        deploymentTarget
        fingerprintFunctions
        gccFixincludes
        gccRuntime
        gccTarget
        hostArch
        hostSdkFunctions
        lib
        lld
        lldNewestSdkMajor
        runtimeDir
        runtimeShell
        storeDir
        toolchain
        ;
      appleLinker = "${appleLinker}/bin/ld";
      gccVersion = gcc.version;
      llvmVersion = llvmPackages.llvm.version;
      nixpkgsMinVersion = stdenv.hostPlatform.darwinMinVersion;
      toolPath = lib.makeBinPath [
        coreutils
        findutils
        gnugrep
        gnused
      ];
    };
    checkPhase = ''
      ${stdenv.shellDryRun} "$target"
      ${shellcheck} "$target"
    '';
  };

  # The flake check. Its output records what it verified, which
  # cc-toolchain-check reads as the verification of the system build.
  checkResult = runCommand "${name}-check" { } ''
    mkdir "$out"
    ${checkRunner}/bin/cc-toolchain-check-run --fingerprint-to "$out/fingerprint"
  '';

  # Installed next to the toolchain. Because it refers to checkResult, a
  # system build cannot deploy a toolchain whose check fails on the host that
  # builds it; afterwards it tells whether that verification still holds.
  checkCommand = writeCheckedScriptBin "cc-toolchain-check" ''
    set -euo pipefail
    ${dropStoreSdk}
    ${hostSdkFunctions}
    ${fingerprintFunctions}

    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/cc-toolchain"
    record="$state_dir/verified"
    build_record=${checkResult}/fingerprint

    usage() {
      printf '%s\n' \
        'Usage: cc-toolchain-check [--status | --fingerprint | --help]' \
        "" \
        'Without options, runs the C/C++ toolchain smoke tests against this host:' \
        'the SDK the drivers select (SDKROOT and DEVELOPER_DIR are honoured),' \
        "Apple's linker and the running macOS. A pass is recorded in" \
        "  $record" \
        "" \
        '  --status       Tell whether the toolchain is verified for the host as it' \
        '                 is now: exit 0 if so, 1 if not, 2 on error.' \
        '  --fingerprint  Print the facts a verification would hold for.'
    }

    # Sets REPLY to the SDK the drivers select in this environment, or
    # selection_error to the reason there is none.
    selected_sdk() {
      local trace pattern='"-isysroot" "([^"]*)"'
      selection_error=
      if ! trace="$(${toolchain}/bin/cc -### -c -x c /dev/null -o /dev/null 2>&1)"; then
        selection_error="''${trace##*$'\n'}"
        return 1
      fi
      if ! [[ "$trace" =~ $pattern ]]; then
        selection_error="the drivers select no SDK"
        return 1
      fi
      REPLY="''${BASH_REMATCH[1]}"
    }

    # Prints the one-line summary of a fingerprint.
    describe() {
      local key value
      local -A facts=()
      while IFS='=' read -r key value; do
        facts[$key]="$value"
      done <<<"$1"
      printf 'SDK %s (%s), %s, macOS %s\n' "''${facts[sdk-version]-}" \
        "''${facts[sdk-build]-}" "''${facts[linker]-}" "''${facts[macos]-}"
    }

    status() {
      local live reference key value joined
      local -A verified=()
      local -a changes=()
      # A status line on standard output in every outcome, errors included:
      # callers such as devdoctor show it as the explanation.
      if ! selected_sdk; then
        printf 'cannot tell which SDK the drivers select: %s\n' "$selection_error"
        return 2
      fi
      live="$(fingerprint "$REPLY")"
      for reference in "$record" "$build_record"; do
        if [[ -r "$reference" && "$(<"$reference")" == "$live" ]]; then
          printf 'verified: %s\n' "$(describe "$live")"
          return 0
        fi
      done

      # Explain the difference from the newest verification of this toolchain:
      # a recorded run of it if there is one, else the system build's.
      reference="$build_record"
      if [[ -r "$record" ]]; then
        while IFS='=' read -r key value; do
          verified[$key]="$value"
        done <"$record"
        [[ "''${verified[toolchain]-}" == ${toolchain} ]] && reference="$record"
      fi
      verified=()
      while IFS='=' read -r key value; do
        verified[$key]="$value"
      done <"$reference"
      while IFS='=' read -r key value; do
        if [[ "''${verified[$key]-}" != "$value" ]]; then
          changes+=("$key ''${verified[$key]:-unknown} -> $value")
        fi
      done <<<"$live"
      (( ''${#changes[@]} )) || changes=("fingerprint format")
      printf -v joined '%s; ' "''${changes[@]}"
      printf 'not verified for this host (changed: %s); run cc-toolchain-check\n' "''${joined%; }"
      return 1
    }

    run() {
      local candidate
      umask 077
      ${coreutils}/bin/mkdir -p "$state_dir"
      candidate="$(${coreutils}/bin/mktemp "$state_dir/.verified.XXXXXX")"
      if ! ${checkRunner}/bin/cc-toolchain-check-run --fingerprint-to "$candidate"; then
        ${coreutils}/bin/rm -f "$candidate"
        return 1
      fi
      ${coreutils}/bin/mv -f "$candidate" "$record"
      printf 'verified: %s\n' "$(describe "$(<"$record")")"
    }

    case "''${1-}" in
      "") run ;;
      --status) status ;;
      --fingerprint)
        if ! selected_sdk; then
          printf 'cc-toolchain-check: %s\n' "$selection_error" >&2
          exit 2
        fi
        fingerprint "$REPLY"
        ;;
      -h|--help) usage ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
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
      # Joined deliberately, not just referenced through --ld-path above. The
      # stock Clang and GCC wrappers ship a bin/ld of their own, and it is
      # the cctools wrapper this package exists to bypass. Without this entry
      # winning at priority 5, a bare `ld` on PATH would be exactly the linker
      # that produces the incompatible host-native objects.
      appleLinker
      debugSymbolUtility
      hostClangTools
      runtimeLinks
    ];

    passthru = {
      inherit runtimeDir runtimeRelativeDir;
      # `cc-toolchain-check`, for Home Manager to install; see checkCommand.
      check = checkCommand;
      tests.default = checkResult;
    };

    meta = clang.meta // {
      description = "LLVM ${llvmPackages.llvm.version} and GCC ${gcc.version} drivers for host-native macOS ${deploymentTarget} builds";
      mainProgram = "clang";
      platforms = lib.platforms.darwin;
    };
  });
in
assert lib.assertMsg stdenv.hostPlatform.isDarwin "The Darwin host toolchain requires macOS";
assert lib.assertMsg (ccToolchain.lld.llvm == llvmMajor) ''
  home/cc-toolchain.nix selects LLVM ${llvmMajor}, but lld.newestSdkMajor
  (${lldNewestSdkMajor}) was established for LLD ${ccToolchain.lld.llvm}.
  Set lld.llvm to "${llvmMajor}" once the ceiling is re-established for the
  new release: the toolchain check fails when LLD reads a host SDK above the
  ceiling, and the macOS CI runner links with LLD against the SDK below it.'';
assert lib.assertMsg (
  builtins.match "[0-9]+[.][0-9]+" deploymentTarget != null
) "home/cc-toolchain.nix: darwinDeploymentTarget must be MAJOR.MINOR, not ${deploymentTarget}.";
# The relocated runtimes are nixpkgs builds with nixpkgs' floor as their own
# deployment target; linking them into anything older warns on every link.
assert lib.assertMsg (lib.versionAtLeast deploymentTarget stdenv.hostPlatform.darwinMinVersion)
  "home/cc-toolchain.nix: darwinDeploymentTarget ${deploymentTarget} is below nixpkgs' floor ${stdenv.hostPlatform.darwinMinVersion}.";
toolchain
