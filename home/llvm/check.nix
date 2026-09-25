# Smoke tests for the host toolchain, run as `passthru.tests.default`. Every
# case compiles, links and runs a real binary; the diagnostics it inspects are
# the contract the drivers promise, not incidental output.
{
  appleLinker,
  cctools,
  clangRuntime,
  darwinMinVersion,
  gccFixincludes,
  gccRuntime,
  gccTarget,
  gccVersion,
  hostArch,
  lib,
  lld,
  lldNewestSdkMajor,
  runtimeDir,
  toolchain,
}:
let
  relocated = runtimeDir != null;
in
''
  set -euo pipefail
  export HOME="$TMPDIR"
  cd "$TMPDIR"

  bin=${toolchain}/bin
  otool=${cctools}/bin/otool
  lipo=${cctools}/bin/lipo
  # As in a deployed profile: helpers such as dsymutil are found by name, and
  # -fuse-ld=lld finds ld64.lld from the separate lld package.
  export PATH="$bin:${lld}/bin:$PATH"

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

  check_build_version() {
    local binary="$1" expected_sdk="''${2-$sdk_version}" load_commands
    load_commands="$($otool -l "$binary")"
    grep -Eq "minos[[:space:]]+${darwinMinVersion}([.]0)?$" <<<"$load_commands" ||
      fail "$binary does not target macOS ${darwinMinVersion}"
    grep -Eq "sdk[[:space:]]+''${expected_sdk//./[.]}([.]0)?$" <<<"$load_commands" ||
      fail "$binary was not linked against SDK $expected_sdk"
  }

  for program in cc c++ clang clang++ cpp ld dsymutil gcc g++ clangd clang-tidy; do
    [[ -x "$bin/$program" ]] || fail "missing $program"
  done

  # ----- Compiler policy ----- #
  printf '%s\n' 'int main(void) { return 0; }' > smoke.c
  diagnostics="$($bin/cc -### -c smoke.c 2>&1)"
  grep -Fq -- '-apple-macosx${darwinMinVersion}.0' <<<"$diagnostics" ||
    fail "the native triple does not target macOS ${darwinMinVersion}"
  host_sdk="$(sed -n 's/.*"-isysroot" "\([^"]*\)".*/\1/p' <<<"$diagnostics")"
  host_sdk="''${host_sdk%%$'\n'*}"
  [[ -r "$host_sdk/SDKSettings.json" ]] || fail "no host SDK in: $diagnostics"
  # The build environment exports Nix's own SDK; the driver must not take it.
  [[ "$host_sdk" != /nix/store/* ]] || fail "the driver selected a store SDK"
  sdk_settings="$(<"$host_sdk/SDKSettings.json")"
  [[ "$sdk_settings" =~ \"Version\":\"([0-9.]+)\" ]] || fail "unreadable SDK version"
  sdk_version="''${BASH_REMATCH[1]}"

  grep -Fq -- '${appleLinker}' <<<"$($bin/cc -### smoke.c -o smoke 2>&1)" ||
    fail "a native link does not use the Apple linker shim"
  if grep -Fq -- '${appleLinker}' <<<"$($bin/cc --ld-path=/usr/bin/ld -### smoke.c -o smoke 2>&1)"; then
    fail "an explicit --ld-path was overridden"
  fi
  # LLD is honoured for an SDK it can read and replaced by Apple's linker for
  # one it cannot, which must stay true: once LLD reads the host SDK, the
  # fallback is dead weight and lldNewestSdkMajor has to rise.
  lld_link="$($bin/cc -fuse-ld=lld -### smoke.c -o smoke 2>&1)"
  if (( ''${sdk_version%%.*} > ${lldNewestSdkMajor} )); then
    grep -Fq -- '${appleLinker}' <<<"$lld_link" ||
      fail "an LLD request against SDK $sdk_version did not fall back"
    quiet $bin/cc -fuse-ld=lld smoke.c -o smoke-lld-fallback
    ./smoke-lld-fallback
    if $bin/cc --ld-path=${lld}/bin/ld64.lld smoke.c -o smoke-lld >/dev/null 2>&1; then
      fail "LLD now reads SDK $sdk_version; raise lldNewestSdkMajor in package.nix"
    fi
  elif grep -Fq -- '${appleLinker}' <<<"$lld_link"; then
    fail "an explicit -fuse-ld=lld was overridden"
  fi

  quiet $bin/cc -Werror=unused-command-line-argument --target=wasm32 -c smoke.c -o smoke.wasm.o
  quiet $bin/cc -Werror=unused-command-line-argument -fsyntax-only smoke.c
  quiet $bin/cc -Werror=unused-command-line-argument -E smoke.c -o smoke.i
  quiet $bin/cc -Werror --target=${hostArch}-apple-macos14 -c smoke.c -o versioned-target.o
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
  # host with only one SDK installed. Headers and stubs still come from the
  # host: this tests SDK selection/metadata, not older-SDK compatibility.
  alternate_sdk="$PWD/alternate SDK/MacOSX.sdk"
  alternate_version="$(( ''${sdk_version%%.*} + 1 )).0"
  mkdir -p "$alternate_sdk"
  for entry in "$host_sdk"/*; do
    [[ "''${entry##*/}" == SDKSettings.json ]] || ln -s "$entry" "$alternate_sdk/"
  done
  sed -E 's/"Version"[[:space:]]*:[[:space:]]*"[0-9.]+"/"Version":"'"$alternate_version"'"/' \
    "$host_sdk/SDKSettings.json" > "$alternate_sdk/SDKSettings.json"

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
  for arch in arm64 x86_64; do
    trace="$(SDKROOT="$alternate_sdk" $bin/cc -arch "$arch" -### -c smoke.c 2>&1)"
    grep -Fq -- "\"-isysroot\" \"$alternate_sdk\"" <<<"$trace" ||
      fail "SDKROOT was not honoured for $arch"
    grep -Fq -- "-target-sdk-version=$alternate_version" <<<"$trace" ||
      fail "SDKROOT metadata differs for $arch"
  done
  quiet env SDKROOT="$alternate_sdk" $bin/cc -arch arm64 -arch x86_64 smoke.c -o sdk-universal
  check_build_version sdk-universal "$alternate_version"
  ./sdk-universal

  # Direct ld must infer metadata from its explicit root rather than SDKROOT.
  quiet env SDKROOT="$host_sdk" $bin/ld -arch ${hostArch} \
    -syslibroot "$alternate_sdk" -lSystem smoke.o -o sdk-direct-ld
  check_build_version sdk-direct-ld "$alternate_version"

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
  quiet env \
    DEVELOPER_DIR=/nix/store/00000000000000000000000000000000-apple-sdk \
    SDKROOT=/nix/store/00000000000000000000000000000000-apple-sdk/SDKs/MacOSX.sdk \
    $bin/c++ -std=c++23 sdk.cc -lz -o sdk-store-environment
  ./sdk-store-environment

  printf '%s\n' 'int increment(int value) { return value + 1; }' > increment.c
  printf '%s\n' 'int increment(int); int main(void) { return increment(-1); }' > lto-main.c
  quiet $bin/cc -flto=thin -O2 increment.c lto-main.c -o lto
  ./lto

  printf '%s\n' \
    '#include <stdio.h>' \
    'int main(void) { if (__builtin_available(macOS 27, *)) puts("27"); return 0; }' \
    > available.c
  quiet $bin/cc -arch arm64 -arch x86_64 available.c -o universal
  [[ "$($lipo -archs universal)" == *x86_64* ]] || fail "the universal binary lacks x86_64"
  ./universal >/dev/null

  quiet $bin/cc -fsanitize=address -g smoke.c -o asan
  # The build environment has no /usr/bin/atos to symbolise with.
  ASAN_OPTIONS=symbolize=0 DYLD_LIBRARY_PATH=${clangRuntime} ./asan
  ${lib.optionalString relocated ''
    $otool -L asan | grep -Fq '${runtimeDir}/clang/libclang_rt.asan_osx_dynamic.dylib' ||
      fail "the sanitizer runtime is not referenced through the stable directory"
  ''}

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
      # Wraps Apple's availability macros in __has_attribute(availability),
      # a test the SDK already performs and GCC passes (checked below).
      AvailabilityInternal.h) ;;
      *) fail "fixincludes now rewrites $header from SDK $sdk_version; decide whether GCC needs that fix" ;;
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
  quiet $bin/gcc-ar-${lib.versions.major gccVersion} rcs libincrement.a increment-lto.o
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

  touch "$out"
''
