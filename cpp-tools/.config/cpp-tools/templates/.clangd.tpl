# .clangd Configuration for "Competitive Programming"
# https://clangd.llvm.org/config.html

CompileFlags:
  Add:
    # Standard C++23 flags for competitive programming
    - -std=c++23
    - -O2
    - -DLOCAL=1

    # Force GCC compatibility mode
    - -D__GNUC__=15
    - --gcc-toolchain=/opt/homebrew

    # Competitive programming optimizations
    - -DDEBUG
    # No debug info for faster compilation
    - -g0

  Remove:
    # Remove problematic clang flags
    - -stdlib=*
    - -fcolor-diagnostics

  Compiler: clang

Diagnostics:
  # Suppress diagnostics from system and standard library files
  Suppress:
    # All Homebrew installed headers (including GCC stdlib)
    - "^/opt/homebrew/.*"
    # System headers
    - "^/usr/include/.*"
    - "^/System/.*"
    - "^/Applications/Xcode.app/.*"
    # Standard library bits
    - ".*bits/.*"
    - ".*ext/.*"
    - ".*__.*"
    - ".*std_abs.*"
    - ".*stdlib.*"
    - ".*cstdlib.*"
    - ".*algorithm.*"
    - ".*vector.*"
    - ".*iostream.*"
    # Specific problematic files
    - ".*stdc\\+\\+.*"
    - ".*c\\+\\+/.*"

    # Unused includes and const variables
    - unused-includes
    - unused-const-variable

    # Suppress sign conversion warnings
    - sign-conversion

  # Disable clang-tidy completely for competitive programming
  ClangTidy:
    Remove: ["*"]
    Add: []

  # Disable other checks that can be noisy
  UnusedIncludes: None
  MissingIncludes: None

# Index settings for better performance
Index:
  Background: Build

# Completion settings
Completion:
  AllScopes: Yes
