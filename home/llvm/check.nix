# Smoke tests for the host toolchain, as the program cc-toolchain-check-run.
# The same script runs as the flake check (passthru.tests.default), inside
# every Darwin system build that deploys the toolchain, and by hand against the
# live host through `cc-toolchain-check`. Every case compiles, links and runs a
# real binary; the diagnostics it inspects are the contract the drivers
# promise, not incidental output.
#
# Nothing here assumes a particular host SDK. Decisions that depend on the SDK
# version are exercised through SDK views on both sides of each threshold, and
# the host SDK then runs one side end to end.
{
  appleLinker,
  cctools,
  clangRuntime,
  coreutils,
  deploymentTarget,
  fingerprintFunctions,
  gccFixincludes,
  gccRuntime,
  gccTarget,
  gccVersion,
  hostArch,
  hostSdkFunctions,
  lib,
  lld,
  lldNewestSdkMajor,
  llvmVersion,
  nixpkgsMinVersion,
  runtimeDir,
  runtimeShell,
  storeDir,
  toolPath,
  toolchain,
}:
let
  relocated = runtimeDir != null;
  gccMajor = lib.versions.major gccVersion;
  # A runtime availability check is emitted only above the deployment target.
  availabilityProbe = toString (lib.toInt (lib.versions.major deploymentTarget) + 1);
  # Any versioned triple other than the default target will do; nixpkgs' own
  # floor is one every SDK the drivers accept still supports.
  olderTarget = lib.versions.major nixpkgsMinVersion;
  lldAboveCeiling = toString (lib.toInt lldNewestSdkMajor + 1);
  ld64Lld = "${lld}/bin/ld64.lld";
in
''
  #!${runtimeShell}
  set -euo pipefail

  fingerprint_file=
  case "''${1-}" in
    --fingerprint-to)
      fingerprint_file="''${2:?--fingerprint-to needs a path}"
      [[ "$fingerprint_file" == /* ]] || fingerprint_file="$PWD/$fingerprint_file"
      ;;
    "") ;;
    *)
      echo "usage: cc-toolchain-check-run [--fingerprint-to FILE]" >&2
      exit 2
      ;;
  esac

  # One known environment, by hand as inside a Nix build: of the caller's
  # variables only TMPDIR and the SDK selection the drivers honour survive, and
  # a store SDK exported by a Nix build environment is dropped the way the
  # drivers drop it (a case below checks that they do). LC_ALL keeps bash off
  # the CoreFoundation locale lookup that crashes it under the Nix build user.
  if [[ "''${CC_TOOLCHAIN_CHECK_SCRUBBED-}" != 1 ]]; then
    kept=()
    for variable in SDKROOT DEVELOPER_DIR; do
      value="''${!variable-}"
      if [[ -n "$value" && "$value" != ${storeDir}/* ]]; then
        kept+=("$variable=$value")
      fi
    done
    exec ${coreutils}/bin/env -i CC_TOOLCHAIN_CHECK_SCRUBBED=1 LC_ALL=C \
      TMPDIR="''${TMPDIR:-/tmp}" "''${kept[@]}" "$0" "$@"
  fi

  ${hostSdkFunctions}
  ${fingerprintFunctions}

  bin=${toolchain}/bin
  otool=${cctools}/bin/otool
  lipo=${cctools}/bin/lipo
  # As in a deployed profile, helpers such as dsymutil are found by name; but
  # only the package's own, so nothing else on PATH can stand in for part of
  # the toolchain. LLD included: a -fuse-ld=lld link that works here needs no
  # ld64.lld beyond the one the drivers name.
  export PATH="$bin:${toolPath}"

  work="$(mktemp -d "''${TMPDIR:-/tmp}/cc-toolchain-check.XXXXXX")"
  # shellcheck disable=SC2317 # invoked through the EXIT trap
  finish() {
    local status=$?
    if (( status == 0 )); then
      rm -rf "$work"
    else
      echo "cc-toolchain-check: build artifacts kept in $work" >&2
    fi
  }
  trap finish EXIT
  cd "$work"
  export HOME="$work"

  fail() {
    echo "FAIL: $*" >&2
    exit 1
  }

  # Fails on any diagnostic, not only on errors: a warning on every link is
  # exactly the kind of regression these tests exist to catch.
  quiet() {
    local output
    if ! output="$("$@" 2>&1)"; then
      printf '%s\n' "$output" >&2
      fail "$*"
    fi
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
      fail "unexpected diagnostics from: $*"
    fi
  }

  # Succeeds when the dotted version $1 is at least $2.
  version_at_least() {
    local -a have want
    local index
    IFS=. read -ra have <<<"$1"
    IFS=. read -ra want <<<"$2"
    for ((index = 0; index < ''${#have[@]} || index < ''${#want[@]}; index++)); do
      (( 10#''${have[index]:-0} > 10#''${want[index]:-0} )) && return 0
      (( 10#''${have[index]:-0} < 10#''${want[index]:-0} )) && return 1
    done
    return 0
  }

  check_build_version() {
    local binary="$1" expected_sdk="''${2-$host_sdk_version}" load_commands
    load_commands="$($otool -l "$binary")"
    grep -Eq "minos[[:space:]]+${deploymentTarget}([.]0)?$" <<<"$load_commands" ||
      fail "$binary does not target macOS ${deploymentTarget}"
    grep -Eq "sdk[[:space:]]+''${expected_sdk//./[.]}([.]0)?$" <<<"$load_commands" ||
      fail "$binary was not linked against SDK $expected_sdk"
  }

  # Creates at $1 a view of the host SDK whose SDKSettings.json declares
  # version $2. Headers and stubs still come from the host: a view tests SDK
  # selection and metadata, not compatibility with an older SDK.
  make_sdk_view() {
    local entry
    mkdir -p "$1"
    for entry in "$host_sdk"/*; do
      [[ "''${entry##*/}" == SDKSettings.json ]] || ln -s "$entry" "$1/"
    done
    sed -E 's/"Version"[[:space:]]*:[[:space:]]*"[0-9.]+"/"Version":"'"$2"'"/' \
      "$host_sdk/SDKSettings.json" > "$1/SDKSettings.json"
  }

  for program in cc c++ clang clang++ cpp ld dsymutil gcc g++ gcc-ar-${gccMajor} clangd clang-tidy; do
    [[ -x "$bin/$program" ]] || fail "missing $program"
  done

  # ----- Host ----- #
  printf '%s\n' 'int main(void) { return 0; }' > smoke.c
  diagnostics="$($bin/cc -### -c smoke.c 2>&1)" || fail "cc -### fails: $diagnostics"
  sysroot_pattern='"-isysroot" "([^"]*)"'
  [[ "$diagnostics" =~ $sysroot_pattern ]] || fail "no host SDK in: $diagnostics"
  host_sdk="''${BASH_REMATCH[1]}"
  [[ "$host_sdk" != ${storeDir}/* ]] || fail "the driver selected a store SDK"
  read_sdk_version "$host_sdk" || fail "cannot read the SDK version of $host_sdk"
  host_sdk_version="$sdk_version"
  sdk_major="''${host_sdk_version%%.*}"
  # Tripwire: SDKSettings.json and the SDK's SystemVersion.plist are separate
  # Apple files. When they disagree, SDKSettings.json has changed shape under
  # the parser every driver shares, and the SDK version the linker writes into
  # binaries could be wrong.
  plist_value "$host_sdk/System/Library/CoreServices/SystemVersion.plist" ProductVersion ||
    fail "$host_sdk has no readable SystemVersion.plist"
  [[ "$REPLY" == "$host_sdk_version" ]] ||
    fail "$host_sdk: SDKSettings.json declares $host_sdk_version, SystemVersion.plist $REPLY"
  plist_value /System/Library/CoreServices/SystemVersion.plist ProductVersion ||
    fail "cannot read the running macOS version"
  macos_version="$REPLY"
  apple_linker_version || fail "cannot read the version of Apple's linker"
  linker_version="$REPLY"
  lld_route="LLD ${llvmVersion}"
  (( sdk_major <= ${lldNewestSdkMajor} )) || lld_route="Apple's linker"
  echo "cc-toolchain-check: macOS $macos_version, SDK $host_sdk_version at $host_sdk, $linker_version; -fuse-ld=lld links with $lld_route"

  # The deployment target has a floor, asserted at evaluation, and this
  # ceiling: what is built here has to run here.
  version_at_least "$macos_version" ${deploymentTarget} ||
    fail "macOS $macos_version is older than the deployment target ${deploymentTarget} in home/cc-toolchain.nix"

  # ----- Compiler policy ----- #
  grep -Fq -- '-apple-macosx${deploymentTarget}.0' <<<"$diagnostics" ||
    fail "the native triple does not target macOS ${deploymentTarget}"

  grep -Fq -- '${appleLinker}' <<<"$($bin/cc -### smoke.c -o smoke 2>&1)" ||
    fail "a native link does not use the Apple linker shim"
  if grep -Fq -- '${appleLinker}' <<<"$($bin/cc --ld-path=/usr/bin/ld -### smoke.c -o smoke 2>&1)"; then
    fail "an explicit --ld-path was overridden"
  fi

  quiet $bin/cc -Werror=unused-command-line-argument --target=wasm32 -c smoke.c -o smoke.wasm.o
  quiet $bin/cc -Werror=unused-command-line-argument -fsyntax-only smoke.c
  quiet $bin/cc -Werror=unused-command-line-argument -E smoke.c -o smoke.i
  quiet $bin/cc -Werror --target=${hostArch}-apple-macos${olderTarget} -c smoke.c -o versioned-target.o
  $bin/cc -cc1 -version >/dev/null || fail "-cc1 is not passed through"
  [[ "$(printf '%s\n' '#define VALUE 42' 'VALUE' | $bin/cpp -P | tr -d '[:space:]')" == 42 ]] ||
    fail "cpp does not read standard input"

  # ----- Clang links ----- #
  quiet $bin/cc smoke.c -o smoke-c
  ./smoke-c
  check_build_version smoke-c

  # CPython probes Apple's libffi using this SDK-specific include directory.
  # Headers alone are insufficient: a stripped SDK can pass the header probe
  # but fail -lffi, sending configure down the wrong (non-Apple) code path.
  cat > python-sdk.c <<'C'
  #include <ffi.h>
  #include <bzlib.h>
  static int answer(void) { return 42; }
  int main(void) {
    ffi_cif cif;
    ffi_arg result = 0;
    if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 0, &ffi_type_sint, 0) != FFI_OK)
      return 1;
    ffi_call(&cif, FFI_FN(answer), &result, 0);
    return result != 42 || BZ2_bzlibVersion() == 0;
  }
  C
  quiet $bin/cc -I"$host_sdk/usr/include/ffi" python-sdk.c -lffi -lbz2 -o python-sdk
  ./python-sdk
  check_build_version python-sdk

  quiet $bin/cc -c smoke.c -o smoke.o
  quiet $bin/ld -arch ${hostArch} -lSystem smoke.o -o smoke-ld
  ./smoke-ld
  check_build_version smoke-ld

  # An SDK view with distinct metadata exercises override policy even on a
  # host with only one SDK installed.
  alternate_sdk="$PWD/alternate SDK/MacOSX.sdk"
  alternate_version="$(( sdk_major + 1 )).0"
  make_sdk_view "$alternate_sdk" "$alternate_version"

  for compiler in cc gcc; do
    for spelling in isysroot separate equals; do
      case "$spelling" in
        isysroot) sdk_args=(-isysroot "$alternate_sdk") ;;
        separate) sdk_args=(--sysroot "$alternate_sdk") ;;
        equals) sdk_args=(--sysroot="$alternate_sdk") ;;
      esac
      output="sdk-$compiler-$spelling"
      quiet env SDKROOT="$host_sdk" "$bin/$compiler" \
        "''${sdk_args[@]}" smoke.c -o "$output"
      check_build_version "$output" "$alternate_version"
      ./"$output"
    done
    quiet env SDKROOT="$alternate_sdk" "$bin/$compiler" smoke.c -o "sdk-env-$compiler"
    check_build_version "sdk-env-$compiler" "$alternate_version"
  done

  # SDKROOT must select the same SDK before and after the Apple fallback.
  for arch in ${hostArch} x86_64; do
    trace="$(SDKROOT="$alternate_sdk" $bin/cc -arch "$arch" -### -c smoke.c 2>&1)" ||
      fail "-arch $arch does not resolve: $trace"
    grep -Fq -- "\"-isysroot\" \"$alternate_sdk\"" <<<"$trace" ||
      fail "SDKROOT was not honoured for $arch"
    grep -Fq -- "-target-sdk-version=$alternate_version" <<<"$trace" ||
      fail "SDKROOT metadata differs for $arch"
  done
  quiet env SDKROOT="$alternate_sdk" $bin/cc -arch ${hostArch} -arch x86_64 smoke.c -o sdk-universal
  check_build_version sdk-universal "$alternate_version"
  ./sdk-universal

  # Direct ld must infer metadata from its explicit root rather than SDKROOT.
  quiet env SDKROOT="$host_sdk" $bin/ld -arch ${hostArch} \
    -syslibroot "$alternate_sdk" -lSystem smoke.o -o sdk-direct-ld
  check_build_version sdk-direct-ld "$alternate_version"

  # The developer directory's SDK always states its version, so an unreadable
  # one is a changed format and the linker refuses to guess the metadata.
  broken_developer_dir="$PWD/broken developer dir"
  mkdir -p "$broken_developer_dir/SDKs"
  make_sdk_view "$broken_developer_dir/SDKs/MacOSX.sdk" unparsable
  printf '{"DisplayName":"macOS"}\n' > "$broken_developer_dir/SDKs/MacOSX.sdk/SDKSettings.json"
  if linker_output="$(env -u SDKROOT DEVELOPER_DIR="$broken_developer_dir" $bin/ld -arch ${hostArch} -lSystem smoke.o -o sdk-unknown 2>&1)"; then
    fail "the linker guessed the version of an SDK it cannot read"
  fi
  grep -Fq 'cannot read the SDK version' <<<"$linker_output" ||
    fail "an unreadable developer SDK failed for another reason: $linker_output"

  # zlib is one of the libraries nixpkgs' SDK strips; reaching it, in C++ and
  # with the SDK named explicitly the way CMake does, is the point of using
  # the host SDK.
  printf '%s\n' \
    '#include <zlib.h>' \
    '#include <vector>' \
    'int main() { std::vector<int> values{1, 2, 3};' \
    '  return values.size() == 3 && zlibVersion()[0] != 0 ? 0 : 1; }' \
    > sdk.cc
  quiet $bin/c++ -std=c++23 sdk.cc -lz -o sdk-cc
  ./sdk-cc
  quiet $bin/c++ -std=c++23 -isysroot "$host_sdk" sdk.cc -lz -o sdk-sysroot
  ./sdk-sysroot

  # A Nix build environment exports its own SDK; the drivers must ignore it
  # and select what they would with neither variable set.
  trace="$(env -u SDKROOT -u DEVELOPER_DIR $bin/cc -### -c smoke.c 2>&1)" ||
    fail "cc -### fails without SDKROOT and DEVELOPER_DIR: $trace"
  [[ "$trace" =~ $sysroot_pattern ]] || fail "no default SDK in: $trace"
  default_sdk="''${BASH_REMATCH[1]}"
  store_sdk=${storeDir}/00000000000000000000000000000000-apple-sdk
  trace="$(env DEVELOPER_DIR="$store_sdk" SDKROOT="$store_sdk/SDKs/MacOSX.sdk" \
    $bin/cc -### -c smoke.c 2>&1)" || fail "a store SDK environment breaks the driver: $trace"
  grep -Fq -- "\"-isysroot\" \"$default_sdk\"" <<<"$trace" ||
    fail "a store SDK in the environment displaced the default SDK: $trace"
  quiet env DEVELOPER_DIR="$store_sdk" SDKROOT="$store_sdk/SDKs/MacOSX.sdk" \
    $bin/c++ -std=c++23 sdk.cc -lz -o sdk-store-environment
  ./sdk-store-environment

  printf '%s\n' 'int increment(int value) { return value + 1; }' > increment.c
  printf '%s\n' 'int increment(int); int main(void) { return increment(-1); }' > lto-main.c
  quiet $bin/cc -flto=thin -O2 increment.c lto-main.c -o lto
  ./lto

  printf '%s\n' \
    '#include <stdio.h>' \
    'int main(void) { if (__builtin_available(macOS ${availabilityProbe}, *)) puts("${availabilityProbe}"); return 0; }' \
    > available.c
  quiet $bin/cc -arch ${hostArch} -arch x86_64 available.c -o universal
  [[ "$($lipo -archs universal)" == *x86_64* ]] || fail "the universal binary lacks x86_64"
  ./universal >/dev/null

  quiet $bin/cc -fsanitize=address -g smoke.c -o asan
  # The build environment has no /usr/bin/atos to symbolise with.
  ASAN_OPTIONS=symbolize=0 DYLD_LIBRARY_PATH=${clangRuntime} ./asan
  ${lib.optionalString relocated ''
    $otool -L asan | grep -Fq '${runtimeDir}/clang/libclang_rt.asan_osx_dynamic.dylib' ||
      fail "the sanitizer runtime is not referenced through the stable directory"
  ''}

  # ----- LLD ----- #
  # Which linker a -fuse-ld=lld link gets depends on the SDK version, so both
  # outcomes are exercised on every host through views on either side of
  # home/cc-toolchain.nix's lld.newestSdkMajor. Until September 2026 only the
  # host SDK decided, and the LLD path first ran on a macOS 26 CI runner.
  lld_sdk="$PWD/lld-sdk/MacOSX.sdk"
  apple_sdk="$PWD/apple-sdk/MacOSX.sdk"
  make_sdk_view "$lld_sdk" ${lldNewestSdkMajor}.0
  make_sdk_view "$apple_sdk" ${lldAboveCeiling}.0

  trace="$(SDKROOT="$lld_sdk" $bin/cc -fuse-ld=lld -### smoke.c -o smoke 2>&1)" ||
    fail "-fuse-ld=lld against SDK ${lldNewestSdkMajor} does not resolve: $trace"
  grep -Fq -- '"${ld64Lld}"' <<<"$trace" ||
    fail "-fuse-ld=lld against SDK ${lldNewestSdkMajor} does not link with LLD ${llvmVersion}: $trace"
  fallback_trace="$(SDKROOT="$apple_sdk" $bin/cc -fuse-ld=lld -### smoke.c -o smoke 2>&1)" ||
    fail "-fuse-ld=lld against SDK ${lldAboveCeiling} does not resolve: $fallback_trace"
  default_trace="$(SDKROOT="$apple_sdk" $bin/cc -### smoke.c -o smoke 2>&1)" ||
    fail "a link against SDK ${lldAboveCeiling} does not resolve: $default_trace"
  # Identical up to the name of Clang's temporary object file.
  temporary_object='s|"[^"]*/smoke-[0-9a-f]+[.]o"|"smoke.o"|g'
  [[ "$(sed -E "$temporary_object" <<<"$fallback_trace")" == \
    "$(sed -E "$temporary_object" <<<"$default_trace")" ]] ||
    fail "-fuse-ld=lld against SDK ${lldAboveCeiling} is not an ordinary link with Apple's linker"
  # The caller's own linker path is never replaced, whichever side of the
  # ceiling and whichever order the two flags come in.
  for sdk in "$lld_sdk" "$apple_sdk"; do
    for linker_flags in "-fuse-ld=lld --ld-path=/usr/bin/ld" "--ld-path=/usr/bin/ld -fuse-ld=lld"; do
      # shellcheck disable=SC2086 # two flags per case
      trace="$(SDKROOT="$sdk" $bin/cc $linker_flags -### smoke.c -o smoke 2>&1)" ||
        fail "$linker_flags does not resolve: $trace"
      if grep -Fq -e '${appleLinker}' -e '${ld64Lld}' <<<"$trace"; then
        fail "$linker_flags was overridden against ''${sdk%/*}"
      fi
    done
  done

  # The host SDK takes one of the two paths end to end.
  if (( sdk_major <= ${lldNewestSdkMajor} )); then
    quiet $bin/cc -fuse-ld=lld smoke.c -o smoke-lld
    ./smoke-lld
    check_build_version smoke-lld
    quiet $bin/cc -fuse-ld=lld -flto=thin -O2 increment.c lto-main.c -o lto-lld
    ./lto-lld
  else
    quiet $bin/cc -fuse-ld=lld smoke.c -o smoke-lld-fallback
    ./smoke-lld-fallback
    check_build_version smoke-lld-fallback
    quiet $bin/cc -fuse-ld=lld -flto=thin -O2 increment.c lto-main.c -o lto-lld-fallback
    ./lto-lld-fallback
    # Tripwire: LLD still rejects this SDK, for the known reason. Once it
    # reads it, the fallback is dead weight and the ceiling has to rise.
    if lld_output="$($bin/cc -fuse-ld=lld --ld-path=${ld64Lld} smoke.c -o smoke-lld 2>&1)"; then
      fail "LLD ${llvmVersion} now reads SDK $host_sdk_version; raise lld.newestSdkMajor in home/cc-toolchain.nix"
    fi
    grep -Eq 'could not load TAPI file|unknown architecture' <<<"$lld_output" || {
      printf '%s\n' "$lld_output" >&2
      fail "LLD ${llvmVersion} rejects SDK $host_sdk_version for an unexpected reason"
    }
  fi

  # ----- GCC ----- #
  printf '%s\n' \
    '#include <bits/stdc++.h>' \
    '#include <ext/pb_ds/assoc_container.hpp>' \
    'using ordered_set = __gnu_pbds::tree<int, __gnu_pbds::null_type, std::less<int>,' \
    '  __gnu_pbds::rb_tree_tag, __gnu_pbds::tree_order_statistics_node_update>;' \
    'int main() { ordered_set values; values.insert(3); values.insert(1);' \
    '  return *values.find_by_order(1) == 3 && std::sqrt(4.0) == 2.0 ? 0 : 1; }' \
    > gnu.cc
  quiet $bin/g++ -std=c++23 -O2 -Wl,-fatal_warnings gnu.cc -o gnu
  DYLD_LIBRARY_PATH=${gccRuntime} ./gnu
  check_build_version gnu
  quiet $bin/g++ -std=c++23 -g gnu.cc -o gnu-debug
  [[ -d gnu-debug.dSYM ]] || fail "g++ -g did not produce debug symbols"
  ${lib.optionalString relocated ''
    $otool -L gnu | grep -Fq '${runtimeDir}/gcc/libstdc++.6.dylib' ||
      fail "libstdc++ is not referenced through the stable directory"
  ''}

  # GCC runs without the include-fixed nixpkgs generated from its own SDK:
  # system headers come from the host SDK, libstdc++ keeps its place ahead of
  # GCC's private headers, and a caller can still opt out of it.
  math_origin="$(printf '%s\n' '#include <math.h>' | $bin/gcc -H -fsyntax-only -x c - 2>&1 | sed -n 1p)"
  [[ "$math_origin" == ". $host_sdk/usr/include/math.h" ]] ||
    fail "gcc does not take math.h from the host SDK: $math_origin"
  search_dirs="$(printf "" | $bin/g++ -x c++ -E -v - 2>&1 |
    sed -n '/<[.][.][.]> search starts here:/,/End of search list/{s/^ *//;p;}')"
  [[ "$(sed -n 2p <<<"$search_dirs")" == */include/c++/${gccVersion} ]] ||
    fail "libstdc++ headers are not searched first: $search_dirs"
  while IFS= read -r directory; do
    [[ -z "$(ls -A "$directory")" ]] || fail "g++ searches a populated $directory"
  done < <(grep include-fixed <<<"$search_dirs")
  if printf "" | $bin/g++ -nostdinc++ -x c++ -E -v - 2>&1 | grep -Fq include/c++/; then
    fail "-nostdinc++ no longer drops the libstdc++ headers"
  fi

  printf '#include <%s>\n' \
    assert.h complex.h ctype.h dirent.h dlfcn.h errno.h fcntl.h fenv.h float.h \
    inttypes.h limits.h locale.h mach/mach.h math.h netdb.h poll.h pthread.h \
    setjmp.h signal.h stdarg.h stdatomic.h stdbool.h stddef.h stdint.h stdio.h \
    stdlib.h string.h sys/mman.h sys/socket.h sys/stat.h sys/time.h sys/wait.h \
    termios.h tgmath.h time.h unistd.h wchar.h wctype.h zlib.h > system-headers.h
  printf '%s\n' '#include "system-headers.h"' 'int main(void) { return isnan(sqrt(4.0)); }' \
    > system-headers.c
  quiet $bin/gcc -std=c17 -Wall -Wextra system-headers.c -o system-headers-c
  quiet $bin/g++ -std=c++23 -Wall -Wextra -x c++ system-headers.c -o system-headers-cxx

  # The empty include-fixed stays right only while GCC's own fixincludes
  # finds nothing to repair in the host SDK. A new SDK that trips one of its
  # rules fails here, before GCC reads the unrepaired header.
  fixed_headers="$PWD/fixincludes"
  mkdir "$fixed_headers"
  (
    cd ${gccFixincludes}/libexec
    TARGET_MACHINE=${gccTarget} target_canonical=${gccTarget} MACRO_LIST=/dev/null \
      ./fixinc.sh "$fixed_headers" "$host_sdk/usr/include"
  ) >fixincludes.log 2>&1 || {
    cat fixincludes.log >&2
    fail "fixincludes could not scan the host SDK"
  }
  while IFS= read -r header; do
    case "$header" in
      # Tripwire, reviewed header by header: wraps Apple's availability
      # macros in __has_attribute(availability), a test the SDK already
      # performs and GCC passes (checked below).
      AvailabilityInternal.h) ;;
      *) fail "fixincludes now rewrites $header from SDK $host_sdk_version; decide whether GCC needs that fix" ;;
    esac
  done < <(cd "$fixed_headers" && find . -type f | sed 's|^[.]/||' | sort)
  [[ "$(printf '%s\n' '#if __has_attribute(availability)' yes '#endif' | $bin/gcc -E -P -x c - | tr -d '[:space:]')" == yes ]] ||
    fail "gcc lost the availability attribute the AvailabilityInternal.h fix tests for"

  # Objects from either compiler link with the other without a version mismatch.
  printf '%s\n' 'extern "C" int increment(int);' 'int main() { return increment(-1); }' > mixed.cc
  quiet $bin/cc -c increment.c -o clang-increment.o
  quiet $bin/g++ mixed.cc clang-increment.o -o gcc-links-clang
  DYLD_LIBRARY_PATH=${gccRuntime} ./gcc-links-clang
  quiet $bin/gcc -c increment.c -o gcc-increment.o
  quiet $bin/c++ mixed.cc gcc-increment.o -o clang-links-gcc
  ./clang-links-gcc

  printf '%s\n' \
    '#include <omp.h>' \
    'int main(void) { int sum = 0;' \
    '#pragma omp parallel for reduction(+:sum)' \
    '  for (int i = 0; i < 100; ++i) sum += i;' \
    '  return sum == 4950 ? 0 : 1; }' \
    > openmp.c
  quiet $bin/gcc -fopenmp openmp.c -o openmp
  DYLD_LIBRARY_PATH=${gccRuntime} ./openmp

  # A GCC LTO static library needs GCC's own archiver, under the versioned
  # name CMake asks for first.
  quiet $bin/gcc -flto -O2 -c increment.c -o increment-lto.o
  quiet $bin/gcc-ar-${gccMajor} rcs libincrement.a increment-lto.o
  quiet $bin/gcc -flto -O2 lto-main.c -L. -lincrement -o gcc-lto
  ./gcc-lto

  # ----- Tooling ----- #
  printf '[{"directory":"%s","file":"sdk.cc","command":"%s -std=c++23 -c sdk.cc"}]\n' \
    "$PWD" "$bin/c++" > compile_commands.json
  clangd_output="$($bin/clangd --check=sdk.cc 2>&1)" || {
    printf '%s\n' "$clangd_output" >&2
    fail "clangd could not check a C++ file"
  }
  grep -Fq 'All checks completed, 0 errors' <<<"$clangd_output" || {
    printf '%s\n' "$clangd_output" >&2
    fail "clangd disagrees with the compiler"
  }
  $bin/clang-tidy --quiet '-checks=-*,bugprone-use-after-move' sdk.cc >/dev/null 2>&1 ||
    fail "clang-tidy could not parse a C++ file"

  if [[ -n "$fingerprint_file" ]]; then
    fingerprint "$host_sdk" > "$fingerprint_file"
  fi
  echo "cc-toolchain-check: every check passed"
''
