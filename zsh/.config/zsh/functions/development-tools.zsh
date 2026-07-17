#!/usr/bin/env zsh
# shellcheck shell=zsh
# ============================================================================ #
# +++++++++++++++++++++++ DEVELOPMENT TOOLS FUNCTIONS ++++++++++++++++++++++++ #
# ============================================================================ #
# Development-related utilities.
# Functions to streamline coding workflows and environment setup.
#
# Functions:
#   - clang_format_link   Create symlink to global .clang-format config.
#   - sysinfo             Display comprehensive system information.
#   - zbench              Run zsh-bench from the shared tools directory.
#   - fnm_clean           Clean stale fnm multishell symlinks.
#   - zsh_profile         Profile startup time, milestones, and zprof output.
#   - zshdeps             Inspect and validate supported dependencies.
#
# ============================================================================ #

# -----------------------------------------------------------------------------
# clang_format_link
# @description Creates a .clang-format symlink from the global config in the
# current directory and prompts before replacing an existing target.
# @noargs
# @exitcode 1 If the global config is missing or link creation fails.
# -----------------------------------------------------------------------------
function clang_format_link() {
  local config_file="$HOME/.config/clang-format/.clang-format"
  local target_file="./.clang-format"

  # Check if global config file exists.
  if [[ ! -f "$config_file" ]]; then
    echo "${C_RED}Error: Global .clang-format file not found at '$config_file'${C_RESET}" >&2
    return 1
  fi

  # Check if target already exists.
  if [[ -e "$target_file" ]]; then
    if [[ -L "$target_file" ]]; then
      local current_target=$(readlink "$target_file")
      if [[ "$current_target" == "$config_file" ]]; then
        echo "${C_YELLOW}Symbolic link already exists and points to the correct file.${C_RESET}"
        return 0
      else
        echo "${C_YELLOW}Symbolic link exists but points to: $current_target${C_RESET}"
      fi
    else
      echo "${C_YELLOW}File '.clang-format' already exists in current directory.${C_RESET}"
    fi

    echo -n "${C_YELLOW}Replace existing file/link? (y/N): ${C_RESET}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "${C_CYAN}Operation cancelled.${C_RESET}"
      return 0
    fi

    rm -f "$target_file"
  fi

  # Create the symbolic link.
  echo "${C_CYAN}Creating symbolic link to .clang-format configuration...${C_RESET}"

  if ln -s "$config_file" "$target_file" 2>/dev/null; then
    echo "${C_GREEN}✓ Successfully created symbolic link: .clang-format → $config_file${C_RESET}"

    # Show the link details.
    if command -v ls >/dev/null 2>&1; then
      ls -la "$target_file"
    fi
  else
    echo "${C_RED}Error: Failed to create symbolic link.${C_RESET}" >&2
    return 1
  fi
}

# -----------------------------------------------------------------------------
# sysinfo
# @description Displays platform-aware OS, CPU, memory, disk, network, and
# uptime information.
# @noargs
# -----------------------------------------------------------------------------
function sysinfo() {
  emulate -L zsh
  setopt localoptions pipefail
  _zsh_ui_load || return 1
  _zsh_detect_platform

  local os_info="Unknown" cpu_info="Unknown" memory_info="Unknown"
  local disk_info="Unknown" network_info="Unavailable" uptime_info
  local kernel_info="$(command uname -sr 2>/dev/null)"
  local -a addresses rows

  if [[ "$PLATFORM" == macOS ]]; then
    local product version build memory_bytes cores hardware_info
    product="$(command sw_vers -productName 2>/dev/null)"
    version="$(command sw_vers -productVersion 2>/dev/null)"
    build="$(command sw_vers -buildVersion 2>/dev/null)"
    os_info="${product:-macOS} ${version}${build:+ · build $build}"
    cpu_info="$(command sysctl -n machdep.cpu.brand_string 2>/dev/null)"
    cores="$(command sysctl -n hw.ncpu 2>/dev/null)"
    [[ -z "$cores" ]] || cpu_info+=" · $cores cores"
    memory_bytes="$(command sysctl -n hw.memsize 2>/dev/null)"
    [[ "$memory_bytes" == <-> ]] &&
      memory_info="$(( memory_bytes / 1024 / 1024 / 1024 )) GiB total"
    if [[ "$cpu_info" == "" || "$memory_info" == Unknown ]] &&
        (( $+commands[system_profiler] )); then
      hardware_info="$(command system_profiler SPHardwareDataType 2>/dev/null)"
      if [[ -z "$cpu_info" ]]; then
        cpu_info="$(print -r -- "$hardware_info" |
          awk -F: '/^[[:space:]]*(Chip|Processor Name):/ {
            sub(/^[ \t]+/, "", $2); print $2; exit
          }')"
        cores="$(print -r -- "$hardware_info" |
          awk -F: '/Total Number of Cores:/ {
            sub(/^[ \t]+/, "", $2); print $2; exit
          }')"
        if [[ -n "$cores" ]]; then
          local core_count="${cores%% *}"
          local core_detail="${cores#$core_count}"
          cpu_info+=" · $core_count cores$core_detail"
        fi
      fi
      [[ "$memory_info" != Unknown ]] || memory_info="$(
        print -r -- "$hardware_info" |
          awk -F: '/^[[:space:]]*Memory:/ {
            sub(/^[ \t]+/, "", $2); print $2 " total"; exit
          }'
      )"
    fi
    if (( $+commands[ifconfig] )); then
      addresses=("${(@f)$(command ifconfig 2>/dev/null | awk \
        '/inet / && $2 != "127.0.0.1" { print $2 }')}")
    fi
  elif [[ "$PLATFORM" == Linux ]]; then
    if [[ -r /etc/os-release ]]; then
      os_info="$(. /etc/os-release; print -r -- "${PRETTY_NAME:-$NAME}")"
    fi
    cpu_info="$(awk -F: \
      '/model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' \
      /proc/cpuinfo 2>/dev/null)"
    (( $+commands[nproc] )) && cpu_info+=" · $(command nproc) cores"
    if (( $+commands[free] )); then
      memory_info="$(command free -h | awk \
        '/^Mem:/ { print $2 " total · " $3 " used · " $7 " available" }')"
    fi
    if (( $+commands[hostname] )); then
      addresses=("${(@s: :)$(command hostname -I 2>/dev/null)}")
    fi
  fi

  disk_info="$(command df -h / 2>/dev/null | awk \
    'END { print $5 " used · " $4 " free · " $1 }')"
  addresses=("${(@)addresses:#}")
  (( ${#addresses[@]} )) && network_info="${(j:, :)addresses}"
  uptime_info="$(command uptime 2>/dev/null)"
  uptime_info="${uptime_info#"${uptime_info%%[![:space:]]*}"}"

  rows=(
    $'Operating system\t'"$os_info"
    $'Kernel\t'"${kernel_info:-Unknown}"
    $'CPU\t'"${cpu_info:-Unknown}"
    $'Memory\t'"$memory_info"
    $'Root disk\t'"${disk_info:-Unknown}"
    $'Network\t'"$network_info"
    $'Uptime\t'"${uptime_info:-Unknown}"
  )
  _zsh_ui_section "System information"
  _zsh_ui_table $'Component\tValue' "${rows[@]}"
}

# -----------------------------------------------------------------------------
# zbench
# @description Runs zsh-bench from ZSH_BENCH_DIR or the shared tools directory.
# @arg $@ string Optional arguments forwarded to zsh-bench.
# @exitcode 1 If zsh-bench is not found.
# -----------------------------------------------------------------------------
function zbench() {
  local bench_dir="${ZSH_BENCH_DIR:-${ZSH_TOOLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zsh/tools}/zsh-bench}"
  local bench_cmd="$bench_dir/zsh-bench"

  if [[ ! -x "$bench_cmd" ]]; then
    echo "${C_RED}Error: zsh-bench not found at '$bench_cmd'.${C_RESET}" >&2
    echo "${C_YELLOW}Install with:${C_RESET} git clone https://github.com/romkatv/zsh-bench \"$bench_dir\"" >&2
    return 1
  fi

  "$bench_cmd" "$@"
}

# -----------------------------------------------------------------------------
# fnm_clean
# @description Removes stale fnm multishell symlinks while preserving
# active sessions.
# @option --all Remove active-session symlinks too.
# @option -n | --dry-run Preview removals without changing files.
# @option --quiet Suppress informational output.
# @option -h | --help Show usage information.
# @exitcode 1 If removal fails; 2 if an option is invalid.
# -----------------------------------------------------------------------------
function fnm_clean() {
  emulate -L zsh
  setopt noxtrace noverbose nullglob

  local fnm_state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/fnm_multishells"
  local remove_all=0
  local dry_run=0
  local quiet=0
  local arg

  for arg in "$@"; do
    case "$arg" in
      --all) remove_all=1 ;;
      --dry-run|-n) dry_run=1 ;;
      --quiet) quiet=1 ;;
      -h|--help)
        cat <<'EOF'
Usage: fnm_clean [--all] [--dry-run|-n] [--quiet]

Default behavior removes only orphan fnm multishell symlinks.
Use --all to remove every symlink in the fnm multishell state directory.
EOF
        return 0
        ;;
      *)
        echo "fnm_clean: unknown option '$arg'" >&2
        return 2
        ;;
    esac
  done

  (( quiet )) || _zsh_ui_load || return 1

  if [[ ! -d "$fnm_state_dir" ]]; then
    (( quiet )) || _zsh_ui_log info \
      "No fnm state directory exists; nothing to clean."
    return 0
  fi

  local -a links=("$fnm_state_dir"/*(N@))
  if (( ${#links[@]} == 0 )); then
    (( quiet )) || _zsh_ui_log info "No fnm multishell symlinks to clean."
    return 0
  fi

  (( quiet )) || _zsh_ui_section "fnm multishell cleanup"

  local removed=0 skipped=0 failed=0
  local link base pid
  local -a preview_rows=()

  for link in "${links[@]}"; do
    if (( ! remove_all )); then
      # Keep current shell session symlink when available.
      if [[ -n "${FNM_MULTISHELL_PATH:-}" && "$link" == "$FNM_MULTISHELL_PATH" ]]; then
        ((skipped++))
        continue
      fi

      # fnm multishell names are "<pid>_<timestamp>"; keep running PIDs.
      base="${link:t}"
      pid="${base%%_*}"
      if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
        ((skipped++))
        continue
      fi
    fi

    if (( dry_run )); then
      (( quiet )) || preview_rows+=($'Remove\t'"$link")
      ((removed++))
      continue
    fi

    if command rm -f -- "$link"; then
      ((removed++))
    else
      ((failed++))
    fi
  done

  if (( dry_run )); then
    if (( ! quiet )); then
      (( ${#preview_rows[@]} )) &&
        _zsh_ui_table $'Action\tPath' "${preview_rows[@]}"
      _zsh_ui_log ok \
        "Dry run: $removed candidates, $skipped active sessions preserved."
    fi
    return 0
  fi

  if (( failed > 0 )); then
    (( quiet )) || _zsh_ui_log warn \
      "Removed $removed; preserved $skipped active; $failed failed."
    return 1
  fi

  (( quiet )) || _zsh_ui_log ok \
    "Removed $removed stale links; preserved $skipped active sessions."
  return 0
}

# -----------------------------------------------------------------------------
# zsh_profile
# @description Measures Zsh startup time, reports startup milestones, or prints
# zprof output. Trace mode ends at the first input-ready boundary.
# @arg $1 string Optional mode: time, trace, zprof, or both; defaults to time.
# @exitcode 1 If the mode is invalid or profiling fails.
# -----------------------------------------------------------------------------
function zsh_profile() {
  emulate -L zsh
  setopt localoptions no_aliases pipefail

  local mode="${1:-time}"
  local zdot="${ZSH_CONFIG_DIR:-${ZDOTDIR:-$HOME/.config/zsh}}"
  local zsh_bin="${ZSH_PROFILE_ZSH_BIN:-$(command -v zsh)}"
  local fast="${ZSH_PROFILE_FAST_START:-}"
  local -a time_cmd

  case "$mode" in
    time|--time|trace|--trace|zprof|--zprof|both|--both)
      ;;
    -h|--help)
      print -r -- "Usage: zsh_profile [time|trace|zprof|both]"
      print -r -- ""
      print -r -- "  time   Measure total interactive startup time."
      print -r -- "  trace  Report milestones through the first input-ready boundary."
      print -r -- "  zprof  Report function-level startup costs."
      print -r -- "  both   Run time and zprof reports."
      return 0
      ;;
    *)
      print -u2 "Usage: zsh_profile [time|trace|zprof|both]"
      return 1
      ;;
  esac

  [[ -x "$zsh_bin" ]] || {
    print -u2 "zsh_profile: Zsh executable not found: $zsh_bin"
    return 1
  }

  if [[ ! -f "$zdot/.zshrc" ]]; then
    zdot="${ZDOTDIR:-$HOME}"
  fi

  if [[ -x /usr/bin/time ]]; then
    time_cmd=(/usr/bin/time -p)
  elif command -v gtime >/dev/null 2>&1; then
    time_cmd=(gtime -p)
  fi

  case "$mode" in
    time|--time)
      if (( ${#time_cmd[@]} )); then
        command "${time_cmd[@]}" env \
          ZDOTDIR="$zdot" \
          ZSH_FAST_START="$fast" \
          "$zsh_bin" -i -c exit
      else
        TIMEFMT=$'real\t%*E\nuser\t%*U\nsys\t%*S'
        time (env ZDOTDIR="$zdot" ZSH_FAST_START="$fast" \
          "$zsh_bin" -i -c exit)
      fi
      ;;
    trace|--trace)
      zmodload -i zsh/datetime 2>/dev/null || {
        print -u2 "zsh_profile: zsh/datetime is unavailable"
        return 1
      }

      local trace_parent="${TMPDIR:-/tmp}"
      if [[ ! -d "$trace_parent" || ! -w "$trace_parent" ]]; then
        trace_parent="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
        command mkdir -p -- "$trace_parent" || return 1
      fi

      local trace_file=""
      trace_file="$(mktemp "$trace_parent/zsh-startup-trace.XXXXXX")" ||
        return 1
      local trace_finish="precmd"
      [[ -t 0 && -t 1 ]] && trace_finish="zle"
      local trace_status=0

      {
        command env \
          ZDOTDIR="$zdot" \
          ZSH_FAST_START="$fast" \
          ZSH_CACHE_AUTO="${ZSH_PROFILE_CACHE_AUTO:-0}" \
          ZSH_STARTUP_TRACE=1 \
          ZSH_STARTUP_TRACE_EXIT=1 \
          ZSH_STARTUP_TRACE_FILE="$trace_file" \
          ZSH_STARTUP_TRACE_FINISH="$trace_finish" \
          ZSH_STARTUP_TRACE_ORIGIN="$EPOCHREALTIME" \
          "$zsh_bin" -i
        trace_status=$?

        if (( trace_status != 0 )) || [[ ! -s "$trace_file" ]]; then
          print -u2 "zsh_profile: startup trace did not complete"
          return 1
        fi

        local total delta milestone
        print -r -- "Zsh startup trace"
        printf '%10s  %10s  %s\n' "TOTAL(ms)" "DELTA(ms)" "MILESTONE"
        while IFS=$'\t' read -r total delta milestone; do
          [[ "$total" == elapsed_ms || "$total" == \#* ]] && continue
          printf '%10s  %10s  %s\n' "$total" "$delta" "$milestone"
        done < "$trace_file"
      } always {
        command rm -f -- "$trace_file"
      }
      ;;
    zprof|--zprof)
      command env ZDOTDIR="$zdot" ZSH_PROFILE=1 \
        ZSH_FAST_START="$fast" "$zsh_bin" -i -c zprof
      ;;
    both|--both)
      if (( ${#time_cmd[@]} )); then
        command "${time_cmd[@]}" env \
          ZDOTDIR="$zdot" \
          ZSH_FAST_START="$fast" \
          "$zsh_bin" -i -c exit || return 1
      else
        TIMEFMT=$'real\t%*E\nuser\t%*U\nsys\t%*S'
        time (env ZDOTDIR="$zdot" ZSH_FAST_START="$fast" \
          "$zsh_bin" -i -c exit) || return 1
      fi
      command env ZDOTDIR="$zdot" ZSH_PROFILE=1 \
        ZSH_FAST_START="$fast" "$zsh_bin" -i -c zprof
      ;;
  esac
}

# -----------------------------------------------------------------------------
# zshdeps
# @description Reports required, recommended, and optional Zsh dependencies;
# can also validate or regenerate the platform package manifests.
# @option --required Show required dependencies only.
# @option --all Treat every missing dependency as an error.
# @option --check-manifests Verify generated Homebrew and Arch manifests.
# @option --sync-manifests Regenerate manifests from the canonical registry.
# @option --quiet Print only errors and the final summary.
# @option -h | --help Show usage information.
# @exitcode 1 If the selected contract or manifest validation fails.
# @exitcode 2 If options conflict or an option is invalid.
# -----------------------------------------------------------------------------
function zshdeps() {
  local checker="${ZSH_CONFIG_DIR:-${ZDOTDIR:-$HOME/.config/zsh}}/scripts/check-zsh-dependencies.zsh"

  if [[ ! -x "$checker" ]]; then
    print -u2 "zshdeps: dependency checker is not executable: $checker"
    return 1
  fi
  "$checker" "$@"
}

# ============================================================================ #
# End of development-tools.zsh
