#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# ++++++++++++++++++++++ BOOTSTRAP SHELL QUALIFICATION +++++++++++++++++++++++ #
# ============================================================================ #
# Loads production adapters in an isolated startup context. Manager roots are
# explicit; cache, multishell state and working directory are disposable.
# ============================================================================ #

emulate -L zsh
setopt err_return pipefail
umask 077

autoload -Uz add-zsh-hook
typeset -ga precmd_functions
export PLATFORM=Linux
[[ "$OSTYPE" != darwin* ]] || export PLATFORM=macOS
typeset -a bootstrap_languages=( ${=DEV_BOOTSTRAP_ONLY} )
typeset bootstrap_language=""

_bootstrap_manager_origin() {
  local manager_name="$1" expected="$2" actual
  actual="$(whence -p "$manager_name")" || return 1
  [[ -n "$expected" && "${actual:A}" == "${expected:A}" ]] || {
    print -u2 "Bootstrap $manager_name is shadowed: $actual"
    return 1
  }
}

for bootstrap_language in "${bootstrap_languages[@]}"; do
  case "$bootstrap_language" in
    node|python|ocaml|rust|haskell|ruby|jvm)
      source "$ZSH_CONFIG_DIR/languages/$bootstrap_language.zsh" || return 1
      ;;
    # PATH-only adapters; selections are inspected without proxies. The SDKMAN
    # build tools and Coursier's launchers are on PATH through 90-path.zsh,
    # keyed on SDKMAN_DIR and COURSIER_BIN_DIR; the .NET muxer on DOTNET_ROOT,
    # and conda's condabin on CONDA_ROOT_PREFIX.
    lean|julia|kotlin|maven|gradle|scala|dotnet|conda) ;;
    *) return 1 ;;
  esac
done

source "$ZSH_CONFIG_DIR/lib/90-path.zsh" || {
  print -u2 'Bootstrap PATH initialization failed'
  return 1
}
if (( ${bootstrap_languages[(Ie)node]} )); then
  _bootstrap_manager_origin fnm "$DEV_BOOTSTRAP_NATIVE_FNM" || return 1
  _fnm_lazy_init || return 1
  typeset expected_native_fnm="$FNM_DIR/fnm"
  [[ "${commands[fnm]:A}" == "${expected_native_fnm:A}" ]] || {
    print -u2 "Bootstrap FNM is shadowed: ${commands[fnm]}"
    return 1
  }
fi
if (( ${bootstrap_languages[(Ie)python]} )); then
  _bootstrap_manager_origin pyenv "$DEV_BOOTSTRAP_NATIVE_PYENV" || return 1
fi
if (( ${bootstrap_languages[(Ie)ocaml]} )); then
  _bootstrap_manager_origin opam "$DEV_BOOTSTRAP_NATIVE_OPAM" || return 1
  _zsh_opam_env_apply || return 1
fi

for bootstrap_language in "${bootstrap_languages[@]}"; do
  case "$bootstrap_language" in
    node)
      # The adapter releases its multishell symlink at Zsh exit. Resolve the
      # executable now, while that link still exists, for the parent verifier.
      typeset node_executable="$(whence -p node)"
      node_executable="${node_executable:A}"
      print -r -- node$'\t'"$node_executable"$'\t'"$(command node --version)"
      ;;
    python)
      typeset python_executable
      python_executable="$(command python -I -B -c \
        'import sys; print(sys.executable)')" || return 1
      print -r -- python$'\t'"$python_executable"$'\t'"$(command python --version)"
      ;;
    ocaml)
      print -r -- ocaml$'\t'"$(whence -p ocamlc)"$'\t'"$(command ocamlc -version)"
      ;;
    rust|haskell|lean|ruby|jvm|kotlin|maven|gradle|scala|julia|dotnet|conda)
      # Download-capable proxies are never executed to qualify a selection.
      # The parent validates the direct runtime; here verify shell exposure and
      # manager provenance against the same explicit roots and selector files.
      typeset runtime_command manager_command expected_proxy expected_name
      typeset manager_variable
      case "$bootstrap_language" in
        rust) runtime_command=rustc; manager_command=rustup; expected_proxy="$CARGO_HOME/bin/rustc" ;;
        haskell) runtime_command=ghc; manager_command=ghcup; expected_proxy="$GHCUP_INSTALL_BASE_PREFIX/.ghcup/bin/ghc" ;;
        lean) runtime_command=lean; manager_command=elan; expected_proxy="$ELAN_HOME/bin/lean" ;;
        ruby) runtime_command=ruby; manager_command=rbenv; expected_proxy="$RBENV_ROOT/shims/ruby" ;;
        jvm) runtime_command=java; manager_command=sdkman; expected_proxy="$SDKMAN_DIR/candidates/java/current/bin/java" ;;
        kotlin) runtime_command=kotlin; manager_command=sdkman; expected_proxy="$SDKMAN_DIR/candidates/kotlin/current/bin/kotlin" ;;
        maven) runtime_command=mvn; manager_command=sdkman; expected_proxy="$SDKMAN_DIR/candidates/maven/current/bin/mvn" ;;
        gradle) runtime_command=gradle; manager_command=sdkman; expected_proxy="$SDKMAN_DIR/candidates/gradle/current/bin/gradle" ;;
        scala) runtime_command=scala; manager_command=cs; expected_proxy="$COURSIER_BIN_DIR/scala" ;;
        julia) runtime_command=julia; manager_command=juliaup; expected_proxy="$JULIAUP_HOME/bin/julia" ;;
        dotnet) runtime_command=dotnet; manager_command=dotnet; expected_proxy="$DOTNET_ROOT/dotnet" ;;
        conda) runtime_command=conda; manager_command=conda; expected_proxy="$CONDA_ROOT_PREFIX/condabin/conda" ;;
      esac
      typeset actual_runtime="$(whence -p "$runtime_command")"
      [[ -n "$actual_runtime" && "${actual_runtime:A}" == "${expected_proxy:A}" ]] || {
        print -u2 "Bootstrap $runtime_command is shadowed: $actual_runtime"
        return 1
      }
      # Coursier's manager is named for the project, its command `cs`.
      manager_variable="DEV_BOOTSTRAP_NATIVE_${(U)manager_command}"
      [[ "$manager_command" != cs ]] ||
        manager_variable=DEV_BOOTSTRAP_NATIVE_COURSIER
      if [[ "$manager_command" == sdkman ]]; then
        typeset sdkman_script="$SDKMAN_DIR/bin/sdkman-init.sh"
        [[ "${sdkman_script:A}" == "${${(P)manager_variable}:A}" ]] || return 1
      elif [[ "$manager_command" == conda ]]; then
        # PATH exposes condabin's entry point; the manager is the base's own.
        typeset conda_manager="$CONDA_ROOT_PREFIX/bin/conda"
        [[ "${conda_manager:A}" == "${${(P)manager_variable}:A}" ]] || return 1
      else
        _bootstrap_manager_origin "$manager_command" "${(P)manager_variable}" || return 1
      fi
      expected_name="DEV_BOOTSTRAP_EXPECTED_${(U)bootstrap_language}"
      [[ -x "${(P)expected_name}" ]] || return 1
      print -r -- "$bootstrap_language"$'\t'"${(P)expected_name}"$'\t'prequalified
      ;;
  esac
done

# ============================================================================ #
# End of probe-shell.zsh
