#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
#                      ██████╗  █████╗ ████████╗██╗  ██╗
#                      ██╔══██╗██╔══██╗╚══██╔══╝██║  ██║
#                      ██████╔╝███████║   ██║   ███████║
#                      ██╔═══╝ ██╔══██║   ██║   ██╔══██║
#                      ██║     ██║  ██║   ██║   ██║  ██║
#                      ╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝
# ============================================================================ #
# ++++++++++++++++++++ FINAL PATH REORDERING AND CLEANUP +++++++++++++++++++++ #
# ============================================================================ #
#
# This runs LAST. It takes the messy PATH and rebuilds it in the desired order.
# This guarantees that shims have top priority and the order is consistent.
#
# Priority order:
#   1. Dynamic shims (pyenv, rbenv, etc.).
#   2. Static language bins (SDKMAN, opam, etc.).
#   3. FNM current session.
#   4. Homebrew/system tools.
#   5. User and app-specific paths.
#   6. Leftover paths from original PATH.
#
# Behavior:
#   - Filters non-existent directories.
#   - Removes FNM orphaned session directories.
#   - Preserves VS Code and other dynamically added paths.
#   - Removes duplicates via "typeset -U".
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# zsh_rebuild_path
# -----------------------------------------------------------------------------
# Rebuild PATH in deterministic order with version manager shims at top.
# Ensures consistent PATH priority across shell sessions and removes duplicates.
# -----------------------------------------------------------------------------
zsh_rebuild_path() {
  # Store original PATH for debugging and fallback (exported for inspection).
  export PATH_BEFORE_BUILD="$PATH"
  local original_path="$PATH"

  # Helper: strip any fnm_multishells/<pid>_<ts>/bin entries from a PATH-like
  # string. FNM mints a fresh per-session symlink, so leaving those entries in
  # the cache key (or in the cached value) would either invalidate the cache
  # for every new shell, or pollute the new shell with the previous shell's
  # stale FNM directory.
  _path_strip_fnm() {
    local input="$1"
    local -a parts kept
    local part
    parts=("${(@s/:/)input}")
    for part in "${parts[@]}"; do
      [[ -z "$part" || "$part" == *fnm_multishells* ]] && continue
      kept+=("$part")
    done
    print -r -- "${(j/:/)kept}"
  }

  # Use a stable, FNM-free view of the inherited PATH for the cache signature.
  local stable_original_path
  stable_original_path="$(_path_strip_fnm "$original_path")"

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
  local cache_file="$cache_dir/path.cache"
  local cache_version="2"
  local cache_signature="${cache_version}|${stable_original_path}|${PLATFORM}"
  cache_signature+="|${PYENV_ROOT}|${SDKMAN_DIR}"
  cache_signature+="|${GEM_HOME}|${GOPATH}|${ANDROID_HOME}"

  local cache_ok=false
  if [[ -r "$cache_file" && -O "$cache_file" && ! -L "$cache_file" ]]; then
    cache_ok=true
  fi

  if $cache_ok; then
    local cached_signature cached_path
    {
      IFS= read -r cached_signature
      IFS= read -r cached_path
    } < "$cache_file"

    if [[ "$cached_signature" == "$cache_signature" && -n "$cached_path" ]]; then
      # Defensive: drop any FNM entry that slipped into the cached blob, then
      # prepend the current shell's FNM dir so node/npm/etc. resolve to the
      # right multishell session.
      local final_path="$cached_path"
      case "$final_path" in
        *fnm_multishells*) final_path="$(_path_strip_fnm "$final_path")" ;;
      esac
      if [[ -n "$FNM_MULTISHELL_PATH" && -d "$FNM_MULTISHELL_PATH/bin" ]]; then
        final_path="$FNM_MULTISHELL_PATH/bin:$final_path"
      fi
      export PATH="$final_path"
      typeset -gU PATH fpath manpath
      unset -f _path_strip_fnm
      return 0
    fi
  fi

  # Version-specific Ruby gems bin (only when Ruby and GEM_HOME are available).
  local ruby_user_bin=""
  if [[ -n "${GEM_HOME-}" ]]; then
    # Use glob expansion to find the version directory without spawning Ruby.
    # Looks for "$GEM_HOME/ruby/*/bin".
    local -a ruby_dirs=("$GEM_HOME"/ruby/*/bin(N))
    if (( ${#ruby_dirs} )); then
      ruby_user_bin="${ruby_dirs[1]}"
    fi
  fi

  # Define the desired final order of directories in the PATH.
  local -a path_template
  if [[ "$PLATFORM" == 'macOS' ]]; then
    path_template=(
      # ----- DYNAMIC SHIMS (TOP PRIORITY) ------ #
      "$HOME/.rbenv/shims"
      "$HOME/.pyenv/shims"

      # ----- STATIC SHIMS & LANGUAGE BINS ------ #
      "$PYENV_ROOT/bin"
      "$HOME/.opam/ocaml-compiler/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/current/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/maven/current/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/kotlin/current/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/gradle/current/bin"

      # ------ FNM (Current session only) ------- #
      "$FNM_MULTISHELL_PATH/bin"

      # --------------- Homebrew ---------------- #
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
      "/opt/homebrew/opt/llvm/bin"
      "/opt/homebrew/opt/ccache/libexec"

      # ------------- Container VM -------------- #
      "/opt/podman/bin"
      "$HOME/.rd/bin"
      "$HOME/.orbstack/bin"

      # ------------- System Tools -------------- #
      "/usr/local/bin" "/usr/bin" "/bin"
      "/usr/sbin" "/sbin"

      # --------- Functional Languages ---------- #
      "$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin"
      "$HOME/Library/Application Support/Coursier/bin"
      "$HOME/.ghcup/bin" "$HOME/.cabal/bin"
      "$HOME/.cargo/bin"
      "$HOME/.elan/bin"

      # ------ User and App-Specific Paths ------ #
      "$HOME/.ada/bin"
      "$HOME/.alire/bin"
      "$HOME/.bun/bin"
      "$HOME/.flutter/bin"
      "$HOME/.local/bin"
      "$HOME/.perl5/bin"
      "$HOME/.fpc-deluxe/fpc/bin/aarch64-darwin"
      "$GOPATH/bin"
      "$GEM_HOME/bin" "$ruby_user_bin"
      "$HOME/.miniforge3/condabin" "$HOME/.miniforge3/bin"
      "$ANDROID_HOME/platform-tools"
      "$ANDROID_HOME/cmdline-tools/latest/bin"

      # --------------- AI Tools ---------------- #
      "$HOME/.lmstudio/bin"
      "$HOME/.opencode/bin"

      # -------------- Other Paths -------------- #
      "$HOME/.config/emacs/bin"
      "$HOME/.wakatime"
      "$HOME/.lcs-bin"
      "$HOME/Library/Application Support/JetBrains/Toolbox/scripts"
      "/usr/local/mysql/bin"
      "/opt/homebrew/opt/ncurses/bin"
      "/Library/TeX/texbin"
      "/usr/local/texlive/2026/bin/universal-darwin"
      "/Applications/Obsidian.app/Contents/MacOS"
    )
  elif [[ "$PLATFORM" == 'Linux' ]]; then
    path_template=(
      # ----- DYNAMIC SHIMS (TOP PRIORITY) ------ #
      "$HOME/.rbenv/shims"
      "$HOME/.pyenv/shims"

      # ----- STATIC SHIMS & LANGUAGE BINS ------ #
      "$PYENV_ROOT/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/java/current/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/maven/current/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/kotlin/current/bin"
      "${SDKMAN_DIR:-$HOME/.sdkman}/candidates/gradle/current/bin"
      "$HOME/.opam/ocaml-compiler/bin"

      # ------ FNM (Current session only) ------- #
      "$FNM_MULTISHELL_PATH/bin"

      # ------------- System Tools -------------- #
      "/usr/local/bin" "/usr/bin" "/bin"
      "/usr/local/sbin" "/usr/sbin" "/sbin"

      # --------------- Linuxbrew --------------- #
      "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin"

      # --------- Functional Languages ---------- #
      "$HOME/.nix-profile/bin" "/nix/var/nix/profiles/default/bin"
      "$HOME/.ghcup/bin" "$HOME/.cabal/bin"
      "$HOME/.cargo/bin"
      "$HOME/.elan/bin"
      "$HOME/.local/share/coursier/bin"

      # ------ User and App-Specific Paths ------ #
      "$GEM_HOME/bin" "$ruby_user_bin"
      "$HOME/.ada/bin"
      "$HOME/.bun/bin"
      "$HOME/.flutter/bin"
      "$HOME/.local/bin"
      "$HOME/.npm/bin"
      "$HOME/.perl5/bin"
      "$GOPATH/bin"
      "/opt/miniconda3/condabin" "$HOME/.miniforge3/condabin" "$HOME/.miniforge3/bin"
      "$ANDROID_HOME/platform-tools"
      "$ANDROID_HOME/cmdline-tools/latest/bin"
      "$HOME/.local/share/JetBrains/Toolbox/scripts"

      # --------------- AI Tools ---------------- #
      "$HOME/.lmstudio/bin"
      "$HOME/.opencode/bin"

      # -------------- Other Paths -------------- #
      "$HOME/.config/emacs/bin"
      "$HOME/.wakatime"
      "$HOME/.lcs-bin"
    )
  fi

  # ---------------------------------------------------------------------------
  # Path Reconstruction Logic
  # ---------------------------------------------------------------------------
  # 1. Start with an empty array.
  # 2. Use an associative array 'seen' for O(1) duplicate detection.
  # 3. Add paths from 'path_template' (priority list).
  # 4. Append any remaining paths from 'original_path' (dynamic additions).
  # ---------------------------------------------------------------------------

  local -a new_path_array=()
  local -A seen

  # Helper to add a directory to the new path if valid and not seen.
  _add_to_path() {
    local dir="$1"
    # Check if directory exists and hasn't been added yet.
    if [[ -d "$dir" ]] && [[ -z "${seen[$dir]}" ]]; then
      # Filter out unwanted paths (e.g., Ghostty injection).
      if [[ "$dir" == *"/Ghostty.app/"* ]]; then
        return
      fi

      # Skip FNM orphan directories (safety check).
      if [[ "$dir" == *"fnm_multishells"* && "${dir}" != "${FNM_MULTISHELL_PATH}/bin" ]]; then
        return
      fi

      new_path_array+=("$dir")
      seen[$dir]=1
    fi
  }

  # 1. Add prioritized paths from template.
  for dir in "${path_template[@]}"; do
    _add_to_path "$dir"
  done

  # 2. Add remaining paths from original PATH (e.g., VS Code extensions).
  # Split original PATH by colon.
  local -a original_path_array=("${(@s/:/)original_path}")
  for dir in "${original_path_array[@]}"; do
    _add_to_path "$dir"
  done

  # Convert array to PATH string.
  local IFS=':'
  export PATH="${new_path_array[*]}"

  # Cleanup helper.
  unset -f _add_to_path

  # Deduplicate other important path arrays. PATH is already deduplicated
  # by the logic above, but -gU ensures it stays unique globally.
  typeset -gU PATH fpath manpath

  command mkdir -p "$cache_dir" 2>/dev/null
  # Persist a FNM-free PATH so future shells with a different FNM_MULTISHELL_PATH
  # can reuse this cache. The current shell's FNM dir was already added to the
  # live $PATH above; on cache hit, the next shell re-prepends its own.
  local cacheable_path
  cacheable_path="$(_path_strip_fnm "$PATH")"
  {
    print -r -- "$cache_signature"
    print -r -- "$cacheable_path"
  } >| "$cache_file" 2>/dev/null

  unset -f _path_strip_fnm
}

# Run the PATH rebuilding function.
zsh_rebuild_path

# ============================================================================ #
# # End of 90-path.zsh
