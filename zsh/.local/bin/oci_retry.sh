#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================ #
# ++++++++++++++++++++++++++++ OCI RETRY LAUNCHER ++++++++++++++++++++++++++++ #
# ============================================================================ #
# Safely provisions an OCI VM.Standard.A1.Flex instance with targeted retry
# logic and configuration designed for local shell automation.
#
# This script:
#  - Resolves shorthand availability domains to full OCI AD names
#  - Fetches the latest compatible Ubuntu 22.04 AArch64 image
#  - Retries only on explicit capacity or throttling failures
#  - Supports 1Password-backed config via `op run`, `op://`, or Environments
#  - Writes logs to stderr and to a private local log file
#
# Usage:
#   oci_retry.sh [--dry-run] [--op-environment <environment-id>] [--op-no-masking] [--help]
#
# ============================================================================ #

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
DRY_RUN=false
LOG_READY=0
OP_ENVIRONMENT_ID=""
OP_BOOTSTRAPPED="${OCI_RETRY_OP_BOOTSTRAPPED:-0}"
OP_NO_MASKING=false

# -----------------------------------------------------------------------------
# default_ssh_key_file
# -----------------------------------------------------------------------------
# Picks a sensible default public key, preferring Ed25519 when present.
# -----------------------------------------------------------------------------

default_ssh_key_file() {
    if [[ -r "$HOME/.ssh/id_ed25519.pub" ]]; then
        printf '%s\n' "$HOME/.ssh/id_ed25519.pub"
    else
        printf '%s\n' "$HOME/.ssh/id_rsa.pub"
    fi
}

COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"
SUBNET_OCID="${SUBNET_OCID:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$(default_ssh_key_file)}"
AVAILABILITY_DOMAINS_RAW="${AVAILABILITY_DOMAINS:-AD-1 AD-2 AD-3}"
INSTANCE_NAME="${INSTANCE_NAME:-arm-always-free}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPU_COUNT="${OCPU_COUNT:-4}"
MEMORY_GB="${MEMORY_GB:-24}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-100}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"
RETRY_STEP="${RETRY_STEP:-15}"
RETRY_JITTER="${RETRY_JITTER:-15}"
MAX_RETRY_INTERVAL="${MAX_RETRY_INTERVAL:-300}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-600}"
LOG_FILE="${LOG_FILE:-$HOME/.local/state/oci/oci_retry.log}"
OCI_PROFILE="${OCI_PROFILE:-${OCI_CLI_PROFILE:-}}"
OCI_REGION="${OCI_REGION:-${OCI_CLI_REGION:-}}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-${OCI_CLI_CONFIG_FILE:-}}"

AVAILABILITY_DOMAINS=()
OCI_BASE_ARGS=()

# +++++++++++++++++++++++++++++ USAGE & HELPERS ++++++++++++++++++++++++++++++ #

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--op-environment <environment-id>] [--op-no-masking] [--help]

Required environment variables:
  COMPARTMENT_OCID         Tenancy or child compartment OCID
  SUBNET_OCID              Target subnet OCID

Optional environment variables:
  SSH_KEY_FILE             Public SSH key path (default: ~/.ssh/id_ed25519.pub or id_rsa.pub)
  AVAILABILITY_DOMAINS     Space/comma/newline separated list (default: AD-1 AD-2 AD-3)
  INSTANCE_NAME            Display name (default: arm-always-free)
  SHAPE                    Instance shape (default: VM.Standard.A1.Flex)
  OCPU_COUNT               OCPU count (default: 4)
  MEMORY_GB                Memory in GB (default: 24)
  BOOT_VOLUME_GB           Boot volume size in GB (default: 100)
  RETRY_INTERVAL           Base retry delay in seconds (default: 60)
  RETRY_STEP               Extra seconds added after each failure (default: 15)
  RETRY_JITTER             Random jitter in seconds (default: 15)
  MAX_RETRY_INTERVAL       Maximum retry delay in seconds (default: 300)
  MAX_ATTEMPTS             0 = retry forever, otherwise stop after N attempts (default: 0)
  MAX_WAIT_SECONDS         OCI wait timeout in seconds (default: 600)
  LOG_FILE                 Log path (default: ~/.local/state/oci/oci_retry.log)
  OCI_PROFILE              Optional OCI CLI profile override
  OCI_REGION               Optional OCI CLI region override
  OCI_CONFIG_FILE          Optional OCI CLI config file override

1Password support:
  String settings can be supplied directly, through \`op run\`, as \`op://\`
  secret references, or via \`--op-environment <environment-id>\`.
  The \`--op-environment\` flow requires a 1Password CLI build whose
  \`op run --help\` includes the \`--environment\` flag.
  Use \`--op-no-masking\` only for local interactive runs where readable output
  matters more than masking.

Example:
  $SCRIPT_NAME --op-environment 'blgexucrwfr2dtsxe2q4uu7dp4' --dry-run

  $SCRIPT_NAME --op-environment 'blgexucrwfr2dtsxe2q4uu7dp4' --op-no-masking --dry-run

  Or:
  export COMPARTMENT_OCID='op://Infra/OCI/compartment_ocid'
  export SUBNET_OCID='op://Infra/OCI/subnet_ocid'
  export AVAILABILITY_DOMAINS='AD-1 AD-2 AD-3'
  op run -- $SCRIPT_NAME
EOF
}

expand_path() {
    local raw_path="$1"

    case "$raw_path" in
        "~")
            printf '%s\n' "$HOME"
            ;;
        \~/*)
            printf '%s/%s\n' "$HOME" "${raw_path#~/}"
            ;;
        *)
            printf '%s\n' "$raw_path"
            ;;
    esac
}

join_by() {
    local delimiter="$1"
    shift

    local result=""
    local item
    for item in "$@"; do
        if [[ -n "$result" ]]; then
            result="${result}${delimiter}${item}"
        else
            result="$item"
        fi
    done

    printf '%s\n' "$result"
}

# ++++++++++++++++++++++++++++++ LOGGING & EXIT ++++++++++++++++++++++++++++++ #

init_logging() {
    if [[ "$LOG_READY" == "1" ]]; then
        return 0
    fi

    local log_dir=""
    umask 077
    log_dir=$(dirname -- "$LOG_FILE")
    mkdir -p -- "$log_dir"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    LOG_READY=1
}

log() {
    local level="$1"
    shift

    local timestamp=""
    local message=""

    init_logging

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    message="[$timestamp] [$level] $*"

    printf '%s\n' "$message" >&2
    printf '%s\n' "$message" >> "$LOG_FILE"
}

log_block() {
    local level="$1"
    local text="$2"
    local line=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        log "$level" "$line"
    done <<EOF
$text
EOF
}

notify_mac() {
    local title="$1"
    local body="$2"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        return 0
    fi

    if ! command -v osascript >/dev/null 2>&1; then
        return 0
    fi

    osascript - "$title" "$body" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

fatal_exit() {
    local message="$1"
    local code="${2:-1}"

    notify_mac "OCI Provisioning Failed" "$message"
    exit "$code"
}

cleanup() {
    log "INFO" "Interrupted by user. Exiting."
    notify_mac "OCI Provisioning" "Script interrupted by user."
    exit 130
}

# -----------------------------------------------------------------------------
# capture_cmd
# -----------------------------------------------------------------------------
# Runs a command with `set -e` temporarily relaxed so callers can inspect both
# combined output and exit status without aborting the whole script.
# -----------------------------------------------------------------------------
capture_cmd() {
    local output_var="$1"
    local rc_var="$2"
    shift 2

    local captured_output=""
    local captured_rc=0

    set +e
    captured_output=$("$@" 2>&1)
    captured_rc=$?
    set -e

    printf -v "$output_var" '%s' "$captured_output"
    printf -v "$rc_var" '%s' "$captured_rc"
}

# -----------------------------------------------------------------------------
# capture_cmd_streams
# -----------------------------------------------------------------------------
# Runs a command while keeping stdout and stderr separated. This is used for
# OCI calls that return JSON or raw values on stdout but may emit warnings on
# stderr that would otherwise corrupt parsing.
# -----------------------------------------------------------------------------
capture_cmd_streams() {
    local stdout_var="$1"
    local stderr_var="$2"
    local rc_var="$3"
    shift 3

    local captured_stdout=""
    local captured_stderr=""
    local captured_rc=0
    local stderr_file=""

    stderr_file=$(mktemp "${TMPDIR:-/tmp}/oci_retry.stderr.XXXXXX") || {
        printf 'Unable to allocate temporary file for stderr capture.\n' >&2
        exit 1
    }

    set +e
    captured_stdout=$("$@" 2>"$stderr_file")
    captured_rc=$?
    set -e

    captured_stderr=$(cat "$stderr_file" 2>/dev/null || true)
    rm -f "$stderr_file"

    printf -v "$stdout_var" '%s' "$captured_stdout"
    printf -v "$stderr_var" '%s' "$captured_stderr"
    printf -v "$rc_var" '%s' "$captured_rc"
}

format_command() {
    local formatted=""
    local arg=""

    for arg in "$@"; do
        formatted="${formatted}$(printf '%q ' "$arg")"
    done

    printf '%s\n' "${formatted% }"
}

require_command() {
    local command_name="$1"
    local help_text="${2:-}"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    if [[ -n "$help_text" ]]; then
        log "ERROR" "$help_text"
        fatal_exit "$help_text"
    fi

    log "ERROR" "Required command not found: $command_name"
    fatal_exit "Missing required command: $command_name"
}

# -----------------------------------------------------------------------------
# resolve_secret_ref
# -----------------------------------------------------------------------------
# Resolves either a plain value or a 1Password `op://` secret reference.
# -----------------------------------------------------------------------------
resolve_secret_ref() {
    local label="$1"
    local value="$2"
    local output=""
    local rc=0

    if [[ "$value" != op://* ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    require_command op "1Password CLI is required to resolve $label."
    capture_cmd output rc op read "$value"
    if [[ "$rc" -ne 0 ]]; then
        log "ERROR" "Unable to resolve 1Password reference for $label."
        log_block "ERROR" "$output"
        fatal_exit "Unable to resolve $label from 1Password."
    fi

    if [[ -z "$output" ]]; then
        log "ERROR" "1Password reference for $label resolved to an empty value."
        fatal_exit "1Password returned an empty value for $label."
    fi

    printf '%s\n' "$output"
}

# ++++++++++++++++++++++++++ ARGUMENTS & VALIDATION ++++++++++++++++++++++++++ #

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                ;;
            --op-environment)
                if (($# < 2)); then
                    printf 'Missing value for %s\n\n' "$1" >&2
                    usage >&2
                    exit 1
                fi
                OP_ENVIRONMENT_ID="$2"
                shift
                ;;
            --op-no-masking)
                OP_NO_MASKING=true
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown argument: %s\n\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# bootstrap_from_1password_environment
# -----------------------------------------------------------------------------
# Re-executes the script through `op run --environment` so configuration comes
# from a 1Password Environment without shell exports or .env files.
# -----------------------------------------------------------------------------
bootstrap_from_1password_environment() {
    local op_version=""
    local help_output=""
    local rc=0
    local -a cmd=()

    if [[ -z "$OP_ENVIRONMENT_ID" || "$OP_BOOTSTRAPPED" == "1" ]]; then
        return 0
    fi

    require_command op "1Password CLI is required for --op-environment."

    capture_cmd help_output rc op run --help
    if [[ "$rc" -ne 0 ]] || ! printf '%s' "$help_output" | grep -q -- '--environment'; then
        op_version=$(op --version 2>/dev/null || printf '%s' 'unknown')
        log "ERROR" "--op-environment requires a 1Password CLI build that supports 'op run --environment'."
        log "ERROR" "Detected 1Password CLI version: $op_version"
        log "ERROR" "Install the latest 1Password CLI beta, or use op:// references / op run --env-file instead."
        fatal_exit "Current 1Password CLI does not support --environment."
    fi

    cmd=(
        /usr/bin/env
        OCI_RETRY_OP_BOOTSTRAPPED=1
        op
        run
    )

    if $OP_NO_MASKING; then
        cmd+=(--no-masking)
    fi

    cmd+=(
        --environment "$OP_ENVIRONMENT_ID"
        --
        "$0" "$@"
    )

    exec "${cmd[@]}"
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1

    case "$1" in
        0|0.0|0.00|00|000)
            return 1
            ;;
    esac

    return 0
}

validate_non_negative_integer() {
    local name="$1"
    local value="$2"

    if ! is_non_negative_integer "$value"; then
        log "ERROR" "$name must be a non-negative integer. Got: $value"
        fatal_exit "Invalid numeric value for $name."
    fi
}

validate_positive_number() {
    local name="$1"
    local value="$2"

    if ! is_positive_number "$value"; then
        log "ERROR" "$name must be a positive number. Got: $value"
        fatal_exit "Invalid numeric value for $name."
    fi
}

# -----------------------------------------------------------------------------
# parse_availability_domains
# -----------------------------------------------------------------------------
# Normalizes a space/comma/newline separated list into a Bash array.
# -----------------------------------------------------------------------------
parse_availability_domains() {
    local raw="$1"
    local normalized=""
    local item=""
    local parts=()
    local old_ifs="$IFS"

    normalized=$(printf '%s' "$raw" | tr ',\r\n\t' '    ')

    set -f
    IFS=' '
    # shellcheck disable=SC2206
    parts=( $normalized )
    IFS="$old_ifs"
    set +f

    AVAILABILITY_DOMAINS=()
    for item in "${parts[@]}"; do
        AVAILABILITY_DOMAINS+=("$item")
    done

    if [[ "${#AVAILABILITY_DOMAINS[@]}" -eq 0 ]]; then
        log "ERROR" "AVAILABILITY_DOMAINS must contain at least one entry."
        fatal_exit "No availability domains configured."
    fi
}

is_full_ad_name() {
    [[ "$1" =~ ^[^[:space:]:]+:[^[:space:]]+-AD-[0-9]+$ ]]
}

# +++++++++++++++++++++++++++++ OCI PREPARATION ++++++++++++++++++++++++++++++ #

build_oci_base_args() {
    OCI_BASE_ARGS=()

    if [[ -n "$OCI_PROFILE" ]]; then
        OCI_BASE_ARGS+=(--profile "$OCI_PROFILE")
    fi

    if [[ -n "$OCI_REGION" ]]; then
        OCI_BASE_ARGS+=(--region "$OCI_REGION")
    fi

    if [[ -n "$OCI_CONFIG_FILE" ]]; then
        OCI_CONFIG_FILE=$(expand_path "$OCI_CONFIG_FILE")
        OCI_BASE_ARGS+=(--config-file "$OCI_CONFIG_FILE")
    fi
}

validate_config() {
    COMPARTMENT_OCID=$(resolve_secret_ref "COMPARTMENT_OCID" "$COMPARTMENT_OCID")
    SUBNET_OCID=$(resolve_secret_ref "SUBNET_OCID" "$SUBNET_OCID")
    AVAILABILITY_DOMAINS_RAW=$(resolve_secret_ref "AVAILABILITY_DOMAINS" "$AVAILABILITY_DOMAINS_RAW")
    INSTANCE_NAME=$(resolve_secret_ref "INSTANCE_NAME" "$INSTANCE_NAME")
    OCI_PROFILE=$(resolve_secret_ref "OCI_PROFILE" "$OCI_PROFILE")
    OCI_REGION=$(resolve_secret_ref "OCI_REGION" "$OCI_REGION")

    SSH_KEY_FILE=$(expand_path "$SSH_KEY_FILE")
    LOG_FILE=$(expand_path "$LOG_FILE")

    if [[ -z "$COMPARTMENT_OCID" ]]; then
        log "ERROR" "COMPARTMENT_OCID is required."
        fatal_exit "Missing COMPARTMENT_OCID."
    fi

    if [[ "$COMPARTMENT_OCID" != ocid1.compartment.* && "$COMPARTMENT_OCID" != ocid1.tenancy.* ]]; then
        log "ERROR" "COMPARTMENT_OCID must be a compartment or tenancy OCID. Got: $COMPARTMENT_OCID"
        fatal_exit "Invalid COMPARTMENT_OCID."
    fi

    if [[ -z "$SUBNET_OCID" ]]; then
        log "ERROR" "SUBNET_OCID is required."
        fatal_exit "Missing SUBNET_OCID."
    fi

    if [[ "$SUBNET_OCID" != ocid1.subnet.* ]]; then
        log "ERROR" "SUBNET_OCID must be a subnet OCID. Got: $SUBNET_OCID"
        fatal_exit "Invalid SUBNET_OCID."
    fi

    if [[ ! -r "$SSH_KEY_FILE" ]]; then
        log "ERROR" "SSH key file not found or not readable: $SSH_KEY_FILE"
        fatal_exit "SSH key file is missing or unreadable."
    fi

    validate_positive_number "OCPU_COUNT" "$OCPU_COUNT"
    validate_positive_number "MEMORY_GB" "$MEMORY_GB"
    validate_positive_number "BOOT_VOLUME_GB" "$BOOT_VOLUME_GB"
    validate_non_negative_integer "RETRY_INTERVAL" "$RETRY_INTERVAL"
    validate_non_negative_integer "RETRY_STEP" "$RETRY_STEP"
    validate_non_negative_integer "RETRY_JITTER" "$RETRY_JITTER"
    validate_non_negative_integer "MAX_RETRY_INTERVAL" "$MAX_RETRY_INTERVAL"
    validate_non_negative_integer "MAX_ATTEMPTS" "$MAX_ATTEMPTS"
    validate_non_negative_integer "MAX_WAIT_SECONDS" "$MAX_WAIT_SECONDS"

    parse_availability_domains "$AVAILABILITY_DOMAINS_RAW"
    build_oci_base_args

    if ! $DRY_RUN; then
        require_command oci "OCI CLI is required to launch instances."
    fi
}

# -----------------------------------------------------------------------------
# resolve_ads
# -----------------------------------------------------------------------------
# Resolves shorthand availability domains such as AD-1 to the full tenancy
# names returned by OCI. Full names are preserved as-is.
# -----------------------------------------------------------------------------
resolve_ads() {
    local needs_resolution=0
    local ad=""
    local output=""
    local stderr_output=""
    local rc=0
    local names=""
    local match=""
    local upper_ad=""
    local upper_candidate=""
    local candidate=""
    local line=""
    local resolved=()
    local all_ads=()

    for ad in "${AVAILABILITY_DOMAINS[@]}"; do
        if ! is_full_ad_name "$ad"; then
            needs_resolution=1
            break
        fi
    done

    if [[ "$needs_resolution" -eq 0 ]]; then
        return 0
    fi

    if $DRY_RUN; then
        log "INFO" "Dry-run: leaving shorthand AD names unresolved: $(join_by ', ' "${AVAILABILITY_DOMAINS[@]}")"
        return 0
    fi

    require_command python3 "python3 is required to resolve shorthand availability domains."

    log "INFO" "Resolving availability domains..."
    capture_cmd_streams output stderr_output rc \
        oci "${OCI_BASE_ARGS[@]}" iam availability-domain list \
        --all \
        --compartment-id "$COMPARTMENT_OCID" \
        --output json

    if [[ "$rc" -ne 0 ]]; then
        log "ERROR" "Failed to list availability domains."
        [[ -n "$stderr_output" ]] && log_block "ERROR" "$stderr_output"
        [[ -n "$output" ]] && log_block "ERROR" "$output"
        fatal_exit "Unable to resolve availability domains."
    fi

    set +e
    names=$(printf '%s' "$output" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
for item in payload.get("data", []):
    name = item.get("name")
    if name:
        print(name)
')
    rc=$?
    set -e

    if [[ "$rc" -ne 0 || -z "$names" ]]; then
        log "ERROR" "Could not parse OCI availability-domain response."
        [[ -n "$stderr_output" ]] && log_block "ERROR" "$stderr_output"
        [[ -n "$output" ]] && log_block "ERROR" "$output"
        fatal_exit "Unable to parse availability domains."
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] && all_ads+=("$line")
    done <<EOF
$names
EOF

    for ad in "${AVAILABILITY_DOMAINS[@]}"; do
        if is_full_ad_name "$ad"; then
            resolved+=("$ad")
            continue
        fi

        match=""
        upper_ad=$(printf '%s' "$ad" | tr '[:lower:]' '[:upper:]')
        for candidate in "${all_ads[@]}"; do
            upper_candidate=$(printf '%s' "$candidate" | tr '[:lower:]' '[:upper:]')
            if [[ "$upper_candidate" == *"$upper_ad" ]]; then
                match="$candidate"
                break
            fi
        done

        if [[ -z "$match" ]]; then
            log "WARN" "Could not resolve availability domain shorthand: $ad. Skipping it."
            continue
        fi

        log "INFO" "Resolved '$ad' -> '$match'"
        resolved+=("$match")
    done

    if [[ "${#resolved[@]}" -eq 0 ]]; then
        log "ERROR" "None of the configured availability domains could be resolved."
        log "ERROR" "Available domains reported by OCI: $(join_by ', ' "${all_ads[@]}")"
        fatal_exit "Availability domain resolution failed."
    fi

    AVAILABILITY_DOMAINS=("${resolved[@]}")
}

# -----------------------------------------------------------------------------
# fetch_image_id
# -----------------------------------------------------------------------------
# Retrieves the newest Ubuntu 22.04 image compatible with the requested shape.
# Uses `--all` to avoid depending on partial paginated results.
# -----------------------------------------------------------------------------
fetch_image_id() {
    local output=""
    local stderr_output=""
    local rc=0

    log "INFO" "Fetching latest Ubuntu 22.04 AArch64 image ID..."
    capture_cmd_streams output stderr_output rc \
        oci "${OCI_BASE_ARGS[@]}" compute image list \
        --all \
        --compartment-id "$COMPARTMENT_OCID" \
        --operating-system "Canonical Ubuntu" \
        --operating-system-version "22.04" \
        --shape "$SHAPE" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[0].id' \
        --raw-output

    if [[ "$rc" -ne 0 ]]; then
        log "ERROR" "Failed to fetch Ubuntu image ID."
        [[ -n "$stderr_output" ]] && log_block "ERROR" "$stderr_output"
        [[ -n "$output" ]] && log_block "ERROR" "$output"
        fatal_exit "Unable to fetch Ubuntu image ID."
    fi

    if [[ -z "$output" || "$output" == "null" ]]; then
        log "ERROR" "OCI returned no compatible Ubuntu image."
        fatal_exit "No compatible Ubuntu image found."
    fi

    printf '%s\n' "$output"
}

is_retryable_launch_error() {
    local output="$1"

    if printf '%s' "$output" | grep -Eiq 'OutOfHostCapacity|Out of host capacity|Out of capacity'; then
        return 0
    fi

    if printf '%s' "$output" | grep -Eiq 'TooManyRequests|HTTP 429|status code: 429'; then
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# launch_instance
# -----------------------------------------------------------------------------
# Attempts a single launch in one availability domain.
# Returns:
#   0 - Launch succeeded, stdout contains the instance OCID
#   1 - Retryable capacity or throttling failure
#   2 - Wait-for-state timeout
#   3 - Fatal OCI error
# -----------------------------------------------------------------------------
launch_instance() {
    local ad="$1"
    local image_id="$2"
    local shape_config=""
    local output=""
    local stderr_output=""
    local error_output=""
    local rc=0
    local cmd=()

    shape_config=$(printf '{"ocpus": %s, "memoryInGBs": %s}' "$OCPU_COUNT" "$MEMORY_GB")
    cmd=(
        oci "${OCI_BASE_ARGS[@]}" compute instance launch
        --availability-domain "$ad"
        --compartment-id "$COMPARTMENT_OCID"
        --shape "$SHAPE"
        --shape-config "$shape_config"
        --image-id "$image_id"
        --subnet-id "$SUBNET_OCID"
        --assign-public-ip true
        --boot-volume-size-in-gbs "$BOOT_VOLUME_GB"
        --ssh-authorized-keys-file "$SSH_KEY_FILE"
        --display-name "$INSTANCE_NAME"
        --wait-for-state RUNNING
        --max-wait-seconds "$MAX_WAIT_SECONDS"
        --query 'data.id'
        --raw-output
    )

    if $DRY_RUN; then
        log "DRY" "$(format_command "${cmd[@]}")"
        return 0
    fi

    capture_cmd_streams output stderr_output rc "${cmd[@]}"

    if [[ "$rc" -eq 0 ]]; then
        if [[ -z "$output" || "$output" == "null" ]]; then
            log "ERROR" "OCI launch returned success but no instance OCID."
            fatal_exit "Instance launch returned no instance OCID."
        fi
        printf '%s\n' "$output"
        return 0
    fi

    error_output="$stderr_output"
    if [[ -n "$output" ]]; then
        if [[ -n "$error_output" ]]; then
            error_output+=$'\n'
        fi
        error_output+="$output"
    fi

    if [[ "$rc" -eq 2 ]]; then
        log "ERROR" "Launch in $ad timed out while waiting for RUNNING."
        log "ERROR" "Stopping to avoid creating duplicate instances."
        [[ -n "$error_output" ]] && log_block "ERROR" "$error_output"
        return 2
    fi

    if is_retryable_launch_error "$error_output"; then
        log "WARN" "Retryable launch error in $ad."
        [[ -n "$error_output" ]] && log_block "WARN" "$error_output"
        return 1
    fi

    log "ERROR" "Fatal launch error in $ad."
    [[ -n "$error_output" ]] && log_block "ERROR" "$error_output"
    return 3
}

get_public_ip() {
    local instance_id="$1"
    local output=""
    local stderr_output=""
    local rc=0

    capture_cmd_streams output stderr_output rc \
        oci "${OCI_BASE_ARGS[@]}" compute instance list-vnics \
        --all \
        --compartment-id "$COMPARTMENT_OCID" \
        --instance-id "$instance_id" \
        --query 'data[0]."public-ip"' \
        --raw-output

    if [[ "$rc" -ne 0 ]]; then
        log "WARN" "Could not resolve public IP for $instance_id."
        [[ -n "$stderr_output" ]] && log_block "WARN" "$stderr_output"
        [[ -n "$output" ]] && log_block "WARN" "$output"
        printf '%s\n' "(unavailable)"
        return 0
    fi

    if [[ -z "$output" || "$output" == "null" ]]; then
        printf '%s\n' "(unavailable)"
        return 0
    fi

    printf '%s\n' "$output"
}

# ++++++++++++++++++++++++++++++ RETRY STRATEGY ++++++++++++++++++++++++++++++ #

# -----------------------------------------------------------------------------
# compute_retry_delay
# -----------------------------------------------------------------------------
# Builds a simple linear backoff with optional jitter and a configurable cap.
# -----------------------------------------------------------------------------
compute_retry_delay() {
    local attempt="$1"
    local delay="$RETRY_INTERVAL"
    local extra=0
    local jitter=0

    if [[ "$attempt" -gt 1 && "$RETRY_STEP" -gt 0 ]]; then
        extra=$(( (attempt - 1) * RETRY_STEP ))
        delay=$(( delay + extra ))
    fi

    if [[ "$RETRY_JITTER" -gt 0 ]]; then
        jitter=$(( RANDOM % (RETRY_JITTER + 1) ))
        delay=$(( delay + jitter ))
    fi

    if [[ "$MAX_RETRY_INTERVAL" -gt 0 && "$delay" -gt "$MAX_RETRY_INTERVAL" ]]; then
        delay="$MAX_RETRY_INTERVAL"
    fi

    printf '%s\n' "$delay"
}

# ++++++++++++++++++++++++++++++++ MAIN FLOW +++++++++++++++++++++++++++++++++ #

main() {
    local image_id=""
    local num_ads=0
    local attempt=0
    local ad_index=0
    local ad=""
    local instance_id=""
    local public_ip=""
    local rc=0
    local delay=0

    trap cleanup INT TERM

    parse_args "$@"
    bootstrap_from_1password_environment "$@"
    validate_config

    log "INFO" "OCI ARM provisioning script started. dry-run=$DRY_RUN"
    log "INFO" "Log file: $LOG_FILE"
    log "INFO" "Target shape: $SHAPE ($OCPU_COUNT OCPU / $MEMORY_GB GB)"
    log "INFO" "Availability domains: $(join_by ', ' "${AVAILABILITY_DOMAINS[@]}")"

    resolve_ads

    if $DRY_RUN; then
        image_id="ocid1.image.oc1..dry_run_placeholder"
        log "INFO" "Dry-run: skipping live image lookup."
    else
        image_id=$(fetch_image_id)
        log "INFO" "Using image ID: $image_id"
    fi

    num_ads="${#AVAILABILITY_DOMAINS[@]}"

    while true; do
        attempt=$((attempt + 1))

        if [[ "$MAX_ATTEMPTS" -gt 0 && "$attempt" -gt "$MAX_ATTEMPTS" ]]; then
            log "ERROR" "Reached MAX_ATTEMPTS=$MAX_ATTEMPTS without success."
            fatal_exit "Maximum attempts reached."
        fi

        ad="${AVAILABILITY_DOMAINS[$ad_index]}"
        log "INFO" "Attempt #$attempt in availability domain $ad"

        rc=0
        instance_id=$(launch_instance "$ad" "$image_id") || rc=$?

        case "$rc" in
            0)
                if $DRY_RUN; then
                    log "INFO" "Dry-run complete. No instance created."
                    exit 0
                fi

                public_ip=$(get_public_ip "$instance_id")
                log "SUCCESS" "Instance created."
                log "SUCCESS" "OCID: $instance_id"
                log "SUCCESS" "Public IP: $public_ip"

                printf '\n'
                printf 'Instance OCID: %s\n' "$instance_id"
                printf 'Public IP:     %s\n' "$public_ip"

                notify_mac "OCI Instance Ready" "Instance $instance_id is running. IP: $public_ip"
                exit 0
                ;;
            1)
                ;;
            2)
                fatal_exit "Launch timed out while waiting for RUNNING. Check OCI before retrying."
                ;;
            *)
                fatal_exit "Fatal OCI launch error. See $LOG_FILE for details."
                ;;
        esac

        ad_index=$(( (ad_index + 1) % num_ads ))
        delay=$(compute_retry_delay "$attempt")
        log "INFO" "Waiting ${delay}s before retrying (next AD: ${AVAILABILITY_DOMAINS[$ad_index]})"
        sleep "$delay"
    done
}

main "$@"

# ============================================================================ #
# End of script.
