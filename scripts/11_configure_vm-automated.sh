#!/usr/bin/env bash
# Usage: scripts/11_configure_vm-automated.sh <vmname> [--skip-tailscale] [--skip-ufw] [--skip-docker] [--authkey KEY]
#
# Fire-and-forget counterpart to 11_configure_vm-interactive.sh: same end
# state (VM joined to the tailnet, UFW locked down to tailscale0-only,
# Docker installed) but runs every step unconditionally over SSH, no
# prompts, so it can be used non-interactively (e.g. chained after
# 01_start_vm.sh). Idempotent -- each remote step already no-ops safely on
# a re-run (see
# scripts/lib/configure_steps.sh's remote step script), so running this
# against an already-configured VM is safe.
#
# Still enforces the same ordering safety as the -interactive variant:
# refuses to enable UFW unless tailscale0 is confirmed up first -- enabling
# a deny-by-default firewall before that would lock out SSH with no
# fallback besides `virsh console`.
#
# Reaches the VM over SSH as the `abhinav` user (already set up via
# cloud-init) -- via its Tailscale hostname if already joined, else its
# NAT/DHCP lease address.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/configure_steps.sh"
require_env

check_bin ssh

VMNAME="${1:?Usage: scripts/11_configure_vm-automated.sh <vmname> [--skip-tailscale] [--skip-ufw] [--skip-docker] [--authkey KEY]}"
shift

DO_TAILSCALE=1
DO_UFW=1
DO_DOCKER=1
AUTHKEY="${TAILSCALE_AUTHKEY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-tailscale) DO_TAILSCALE=0; shift ;;
        --skip-ufw)       DO_UFW=0; shift ;;
        --skip-docker)    DO_DOCKER=0; shift ;;
        --authkey)        AUTHKEY="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

validate_vmname "$VMNAME"

STATE_PATH="$(state_path "$VMNAME")"
[[ -f "$STATE_PATH" ]] || die "No state file for '$VMNAME' -- run scripts/00_init_vm-automated.sh $VMNAME first."
vm_is_running "$VMNAME" || die "VM '$VMNAME' is not running -- run scripts/01_start_vm.sh $VMNAME first."

if [[ "$DO_TAILSCALE" == "1" && -z "$AUTHKEY" ]]; then
    die "TAILSCALE_AUTHKEY not set (.env) and no --authkey given. Generate a reusable/ephemeral key at https://login.tailscale.com/admin/settings/keys, or pass --skip-tailscale."
fi

log "Waiting for SSH on '$VMNAME'..."
SSH_HOST="$(configure_wait_for_ssh "$VMNAME")" \
    || die "Could not reach '$VMNAME' over SSH (tried Tailscale hostname and DHCP lease IP). Is it done booting / has cloud-init finished?"
log "Reaching '$VMNAME' via $SSH_HOST"

trap 'configure_cleanup_remote "$SSH_HOST"' EXIT

log "Uploading configuration script..."
configure_upload_remote_script "$SSH_HOST"

DOCKER_STATE="skipped"

if [[ "$DO_DOCKER" == "1" ]]; then
    log "Installing/verifying Docker on '$VMNAME'..."
    configure_run_step "$SSH_HOST" "$VMNAME" install-docker
    DOCKER_STATE="installed"
fi

TAILSCALE_STATE="skipped"

if [[ "$DO_TAILSCALE" == "1" ]]; then
    log "Installing/verifying Tailscale on '$VMNAME'..."
    configure_run_step "$SSH_HOST" "$VMNAME" install-tailscale

    log "Running 'tailscale up --hostname=${VMNAME}' on '$VMNAME'..."
    configure_bring_up_tailscale "$SSH_HOST" "$VMNAME" "$AUTHKEY"

    log "Checking for tailscale0 interface..."
    TAILSCALE_UP=0
    for _ in $(seq 1 8); do
        if configure_check_step "$SSH_HOST" "$VMNAME" check-tailscale0; then
            TAILSCALE_UP=1
            break
        fi
        sleep 2
    done

    if [[ "$TAILSCALE_UP" == "1" ]]; then
        TAILSCALE_STATE="up"
        log "tailscale0 is up on '$VMNAME'."
    else
        log "tailscale0 is not up on '$VMNAME'."
    fi
fi

UFW_STATE="skipped"

if [[ "$DO_UFW" == "1" ]]; then
    if [[ "$TAILSCALE_STATE" != "up" ]]; then
        die "Refusing to enable UFW without a confirmed tailscale0 interface on '$VMNAME' -- this would lock out SSH with no fallback besides 'virsh console'. Configure Tailscale first, or pass --skip-ufw."
    fi

    log "Enabling UFW on '$VMNAME' (deny all inbound except tailscale0)..."
    configure_run_step "$SSH_HOST" "$VMNAME" configure-ufw
    UFW_STATE="enabled"
fi

if [[ "$DO_TAILSCALE" == "1" ]]; then
    state_set "$VMNAME" .tailscale "$TAILSCALE_STATE"
else
    state_set "$VMNAME" .tailscale "skipped"
fi

state_set "$VMNAME" .ufw "$UFW_STATE"
state_set "$VMNAME" .docker "$DOCKER_STATE"

log "Configuration complete for '$VMNAME'."
if [[ "$TAILSCALE_STATE" == "up" && -n "${TAILSCALE_TAILNET:-}" ]]; then
    log "Reconnect via: ssh ${CONFIGURE_SSH_USER}@${VMNAME}.${TAILSCALE_TAILNET}"
fi
