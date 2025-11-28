#!/bin/bash
# shellcheck shell=zsh
# ============================================================================ #
# utm_ubuntu.sh - Helper script to start a UTM virtual machine and mount a host
# shared directory
#
# SYNOPSIS
#   utm_ubuntu.sh [--no-login]
#
# DESCRIPTION
#   Starts a UTM VM and mounts a host-shared directory into the guest with safety
#   checks (path validation, permissions, idempotency). Optionally logs into the VM
#   after setup is complete.
#
# REQUIREMENTS
#   - macOS with UTM installed and configured for the target VM.
#   - Proper permissions to control UTM and access the host shared directory.
#   - SSH access to guest with key-based authentication.
#   - Passwordless sudo configured for mkdir and mount commands in the guest.
#
# OPTIONS
#   --no-login             Skip automatic SSH login after setup completion.
#
# ENVIRONMENT VARIABLES
#   VM_NAME                Name of the UTM VM (default: Ubuntu)
#   UTM_SSH_HOST           SSH host identifier (default: ${VM_NAME}.UTM)
#   REMOTE_SHARE_NAME      virtiofs share name (default: share)
#   REMOTE_MOUNTPOINT      Mount point in guest (default: Shared)
#   MAX_WAIT_SECONDS       SSH readiness timeout (default: 120)
#
# BEHAVIOR & SAFEGUARDS
#   - Check VM state and wait for a clean "running" status before attempting mounts.
#   - Avoid remounting an already mounted location.
#   - Log actions and failures with clear, actionable messages.
#   - Exit codes:
#       0   Success
#       1   General error / invalid usage
#       2   VM start or state error
#       3   Mount/unmount failure
#
# ============================================================================ #

# When sourced by zsh during shell startup, expose helper commands and avoid changing shell options.
if [[ -n "${ZSH_VERSION:-}" && "${BASH_SOURCE[0]:-}" != "$0" ]]; then
    UTM_UBUNTU_SCRIPT_PATH="${(%):-%N}"
    utm_ubuntu_start() {
        bash "${UTM_UBUNTU_SCRIPT_PATH}" "$@"
    }
    utm_ubuntu_login() {
        local ssh_host="${UTM_SSH_HOST:-Ubuntu.UTM}"
        ssh "${ssh_host}"
    }
    return 0
fi

set -euo pipefail

# Parse command line arguments
AUTO_LOGIN=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-login)
            AUTO_LOGIN=false
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--no-login]" >&2
            exit 1
            ;;
    esac
done

# VM name (as known by utmctl) and associated SSH host (configurable via env)
VM_NAME="${VM_NAME:-Ubuntu}"
SSH_HOST="${UTM_SSH_HOST:-${VM_NAME}.UTM}"
UTMCTL_CMD="${UTMCTL_CMD:-utmctl}"

# SSH options reused across checks
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-3}"
SSH_BATCH_MODE="${SSH_BATCH_MODE:-yes}"
SSH_OPTS=(-o "BatchMode=${SSH_BATCH_MODE}" -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}" -o "StrictHostKeyChecking=accept-new")

# Timing controls for SSH availability checks
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-120}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"

# Shared folder settings on the guest
REMOTE_SHARE_NAME="${REMOTE_SHARE_NAME:-share}"
REMOTE_MOUNTPOINT="${REMOTE_MOUNTPOINT:-Shared}"
REMOTE_SUDO="${REMOTE_SUDO:-sudo -n}"

START_CMD=("${UTMCTL_CMD}" start "${VM_NAME}")

log() { echo "$@"; }
fail() { echo "$@" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }

describe_ssh_target() {
    # Show the resolved ssh config (host, port, user) to help debugging connectivity.
    local ssh_info_file
    ssh_info_file=$(mktemp) || return
    if ssh -G "${SSH_HOST}" >"${ssh_info_file}" 2>/dev/null; then
        local host port user
        host=$(grep "^hostname " "${ssh_info_file}" | awk '{print $2}' | head -1)
        port=$(grep "^port " "${ssh_info_file}" | awk '{print $2}' | head -1)
        user=$(grep "^user " "${ssh_info_file}" | awk '{print $2}' | head -1)
        log "SSH target -> host: ${host:-unknown}, port: ${port:-22}, user: ${user:-$(whoami)}"
    fi
    rm -f "${ssh_info_file}"
}

FIRST_SSH_FAILURE_SHOWN=false
LAST_SSH_ERROR=""
is_vm_reachable() {
    local out
    if out=$(ssh "${SSH_OPTS[@]}" "${SSH_HOST}" exit 2>&1); then
        LAST_SSH_ERROR=""
        return 0
    fi

    # Surface host key mismatch immediately since waiting will not fix it.
    if [[ "${out}" == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* ]] || [[ "${out}" == *"Host key verification failed"* ]]; then
        fail "SSH host key issue for ${SSH_HOST}. Fix it with: ssh-keygen -R ${SSH_HOST}"
    fi

    if [[ "${FIRST_SSH_FAILURE_SHOWN}" == false ]]; then
        log "SSH not ready yet (${SSH_HOST}): ${out}"
        FIRST_SSH_FAILURE_SHOWN=true
    fi
    LAST_SSH_ERROR="${out}"
    return 1
}

start_vm_if_needed() {
    log "Checking if the VM is already running (SSH check on ${SSH_HOST})..."
    if is_vm_reachable; then
        log "The VM is already running."
        return
    fi

    log "Starting the UTM virtual machine..."
    if ! START_OUTPUT=$("${START_CMD[@]}" 2>&1); then
        if echo "${START_OUTPUT}" | grep -q "OSStatus error -2700"; then
            log "The VM appears to be already running (error -2700 ignored)."
        else
            log "Error starting the VM:"
            echo "${START_OUTPUT}" >&2
            exit 1
        fi
    else
        log "The VM has been started successfully."
    fi
}

wait_for_vm() {
    log "Waiting for the VM to be available (SSH check on ${SSH_HOST})..."
    elapsed=0
    while ! is_vm_reachable; do
        if (( elapsed >= MAX_WAIT_SECONDS )); then
            fail "Timeout: the VM is unreachable after ${MAX_WAIT_SECONDS} seconds. Last SSH error: ${LAST_SSH_ERROR}"
        fi
        printf "."
        sleep "${SLEEP_SECONDS}"
        elapsed=$((elapsed + SLEEP_SECONDS))
    done
    printf "\n"
    log "The VM is ready!"
}

mount_shared_directory() {
    log "Mounting the shared directory on the VM..."
    local mount_output
    local remote_sudo_q remote_mount_q remote_share_q
    remote_sudo_q=$(printf "%q" "${REMOTE_SUDO}")
    remote_mount_q=$(printf "%q" "${REMOTE_MOUNTPOINT}")
    remote_share_q=$(printf "%q" "${REMOTE_SHARE_NAME}")

if mount_output=$(ssh "${SSH_OPTS[@]}" -T "${SSH_HOST}" "bash -s" 2>&1 <<EOF
set -euo pipefail
REMOTE_SUDO=${remote_sudo_q}
REMOTE_MOUNTPOINT=${remote_mount_q}
REMOTE_SHARE_NAME=${remote_share_q}

CMD_MKDIR="\$(command -v mkdir || echo /bin/mkdir)"
CMD_MOUNT="\$(command -v mount || echo /bin/mount)"

MP="\${REMOTE_MOUNTPOINT}"
case "\${MP}" in
  /*) ;;
  *) MP="\${HOME}/\${MP}" ;;
esac

if mountpoint -q "\${MP}"; then
  echo "The shared directory is already mounted at \${MP}."
  exit 0
fi

\${REMOTE_SUDO} "\${CMD_MKDIR}" -p "\${MP}"
\${REMOTE_SUDO} "\${CMD_MOUNT}" -t virtiofs "\${REMOTE_SHARE_NAME}" "\${MP}"
echo "Mount completed on the VM at \${MP}."
EOF
); then
        log "${mount_output}"
    else
        if [[ "${mount_output}" == *"a terminal is required"* ]] || \
           [[ "${mount_output}" == *"password is required"* ]]; then
            fail "Passwordless sudo is required on the guest for mkdir/mount. Example sudoers entry: <username> ALL=(ALL) NOPASSWD: /usr/bin/mkdir, /usr/bin/mount -t virtiofs *"
        fi
        fail "Error mounting the shared directory: ${mount_output}"
    fi
}

main() {
    require_command "${UTMCTL_CMD}"
    require_command ssh
    describe_ssh_target

    start_vm_if_needed
    wait_for_vm
    mount_shared_directory
    log "Operation completed."

    if [[ "${AUTO_LOGIN}" == true ]]; then
        log "Logging into the VM..."
        exec ssh "${SSH_HOST}"
    fi
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main "$@"
fi

# ============================================================================ #
# End of utm_ubuntu.sh
