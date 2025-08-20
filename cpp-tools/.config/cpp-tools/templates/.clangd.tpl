# .clangd Configuration for "Competitive Programming" (Cross-Platform)

CompileFlags:
  Add:
    # Target architecture for Apple Silicon
    - --target=arm64-apple-darwin

    # Standard C++23 flags for competitive programming
    - -std=c++23
    - -O2
    - -DLOCAL=1

    # Competitive programming optimizations
    - -DDEBUG
    # No debug info for faster compilation
    - -g0

    # Cross-platform GCC compatibility
    - -D__GNUC__=15

  Remove:
    # Remove problematic clang flags that vary by platform
    - -stdlib=*
    - -fcolor-diagnostics
    # Remove platform-specific toolchain flags
    - --gcc-toolchain=*

  Compiler: clang

Diagnostics:
  # Suppress diagnostics from system and standard library files (Cross-Platform)
  Suppress:
    # Suppress the specific __float128 error on Apple Silicon
    - type_unsupported

    # macOS specific paths
    - "^/opt/homebrew/.*"
    - "^/usr/local/.*"
    - "^/System/.*"
    - "^/Applications/Xcode.app/.*"

    # Linux specific paths
    - "^/usr/include/.*"
    - "^/usr/lib/.*"
    - "^/lib/.*"
    - "^/usr/share/.*"

    # Generic system paths
    - "^/opt/.*"
    - "^/snap/.*"

    # Standard library internals (platform-independent)
    - ".*bits/.*"
    - ".*ext/.*"
    - ".*__.*"
    - ".*std_abs.*"
    - ".*stdlib.*"
    - ".*cstdlib.*"
    - ".*algorithm.*"
    - ".*vector.*"
    - ".*iostream.*"
    - ".*string.*"
    - ".*memory.*"

    # C++ standard library patterns
    - ".*stdc\\+\\+.*"
    - ".*c\\+\\+/.*"
    - ".*libstdc\\+\\+.*"
    - ".*libc\\+\\+.*"

    # Compiler-specific internals
    - ".*clang/.*"
    - ".*gcc/.*"
    - ".*gnu/.*"

    # Common warnings to suppress for competitive programming
    - unused-includes
    - unused-const-variable
    - unused-parameter
    - unused-variable
    - sign-conversion
    - implicit-int-conversion
    - shorten-64-to-32

  # Disable clang-tidy completely for competitive programming
  ClangTidy:
    Remove: ["*"]
    Add: []

  # Disable other checks that can be noisy in competitive programming
  UnusedIncludes: None
  MissingIncludes: None

# Index settings for better performance
Index:
  Background: Build
  StandardLibrary: Yes

# Completion settings optimized for competitive programming
Completion:
  AllScopes: Yes

# InlayHints can be useful for debugging but might be distracting
InlayHints:
  Enabled: No

# Hover settings
Hover:
  ShowAKA: Yes
