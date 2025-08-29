# .clangd Configuration for "Competitive Programming"

CompileFlags:
  Add:
    # Target architecture for Apple Silicon
    - --target=arm64-apple-darwin

    # Force C++ compilation
    - -xc++

    # C++23 standard with optimization and debug flags
    - -std=c++23
    - -O2
    - -DLOCAL=1

    # Enable debug mode, disable debug info for faster compilation
    - -DDEBUG
    - -g0

    # Cross-platform GCC compatibility
    - -D__GNUC__=15

  Remove:
    # Remove problematic Clang flags that vary by platform
    - -stdlib=*
    - -fcolor-diagnostics
    # Remove platform-specific toolchain flags
    - --gcc-toolchain=*

  Compiler: clang++

Diagnostics:
  # Suppress diagnostics from system and standard library files
  Suppress:
    # Suppress unsupported types warning
    - type_unsupported

    # macOS specific paths
    - "^/opt/homebrew/.*"
    - "^/usr/local/.*"
    - "^/System/.*"
    - "^/Applications/Xcode.app/.*"

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

    # Common warnings to suppress for fast development
    - unknown-pragmas
    - unused-includes
    - unused-const-variable
    - unused-parameter
    - unused-variable
    - shorten-64-to-32
    - builtin_definition

  # Disable clang-tidy completely
  ClangTidy:
    Remove: ["*"]
    Add: []

  # Disable other checks that can be noisy
  UnusedIncludes: None
  MissingIncludes: None

# Index settings for better performance
Index:
  Background: Build
  StandardLibrary: Yes

# Completion settings optimized for productivity
Completion:
  AllScopes: Yes

# Disable InlayHints to avoid visual clutter
InlayHints:
  Enabled: No

# Hover settings
Hover:
  ShowAKA: Yes
