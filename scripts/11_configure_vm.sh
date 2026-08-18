#!/usr/bin/env bash
# Usage: ./scripts/11_configure_vm.sh <vmname> [-i|--interactive] [--skip-tailscale] [--skip-ufw] [--skip-docker] [--authkey KEY]
#
# Joins a running VM to the tailnet, locks UFW down to tailscale0-only, and
# installs Docker -- over SSH, using the shared step machinery in
# ./scripts/lib/configure_steps.sh. Idempotent -- each remote step already
# no-ops safely on a re-run, so this is also how you change network/firewall
# config or install/update Docker on an existing VM (cloud-init only runs
# once, see DECISIONS.md).
#
# Default (no -i): runs every step unconditionally, no prompts -- useful for
# chaining after 01_start_vm.sh, or reconfiguring a VM without babysitting
# it. With -i/--interactive: confirms before each step and runs it over
# `ssh -tt` (real pty) so output streams live -- useful for configuring a new
# base image for the first time, or debugging why Docker/Tailscale/UFW isn't
# coming up cleanly. Declining a step isn't an error -- state.yaml records
# `skipped` for it.
#
# Always refuses to enable UFW unless tailscale0 is confirmed up first --
# enabling a deny-by-default firewall before that would lock out SSH with no
# fallback besides `virsh console`.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/configure_steps.sh"

USAGE=$(cat <<EOF
NAME
    11_configure_vm.sh -- join a running VM to the tailnet, lock down UFW, install Docker

USAGE
    ./scripts/11_configure_vm.sh <vmname> [-i|--interactive] [options]

    VM must already be running (./scripts/01_start_vm.sh). Reaches it over SSH
    as the 'abhinav' user, via its Tailscale hostname if already joined,
    else its NAT/DHCP lease address. Re-runnable/idempotent.

REQUIRED
    <vmname>
        VM name of an already-running VM

OPTIONS
    -i, --interactive
        Confirm before each step instead of running unconditionally; streams
        step output live over an allocated pty
    --skip-tailscale
        Don't install Tailscale / run 'tailscale up'
    --skip-ufw
        Don't enable UFW
    --skip-docker
        Don't install Docker
    --authkey KEY
        Tailscale auth key (default: \$TAILSCALE_AUTHKEY from .env)
    -h, --help
        Show this help and exit

NOTES
    Refuses to enable UFW unless tailscale0 is confirmed up first, in both
    modes -- this is a safety check, not a prompt, and is not skippable
    short of --skip-ufw.

EXAMPLES
    ./scripts/11_configure_vm.sh myvm
    ./scripts/11_configure_vm.sh myvm -i --skip-docker
EOF
)
show_help_if_requested "$USAGE" "$@"

require_env
check_bin ssh

VMNAME="${1:?Missing <vmname>. Run './scripts/11_configure_vm.sh --help' for usage.}"
shift

INTERACTIVE=0
DO_TAILSCALE=1
DO_UFW=1
DO_DOCKER=1
AUTHKEY="${TAILSCALE_AUTHKEY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interactive) INTERACTIVE=1; shift ;;
        --skip-tailscale) DO_TAILSCALE=0; shift ;;
        --skip-ufw)       DO_UFW=0; shift ;;
        --skip-docker)    DO_DOCKER=0; shift ;;
        --authkey)        AUTHKEY="$2"; shift 2 ;;
        -h|--help)        printf '%s\n' "$USAGE"; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

validate_vmname "$VMNAME"

STATE_PATH="$(state_path "$VMNAME")"
[[ -f "$STATE_PATH" ]] || die "No state file for '$VMNAME' -- run ./scripts/00_init_vm.sh $VMNAME first."
vm_is_running "$VMNAME" || die "VM '$VMNAME' is not running -- run ./scripts/01_start_vm.sh $VMNAME first."

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
    if [[ "$INTERACTIVE" == "0" ]] || confirm "Install/verify Docker on '$VMNAME'?"; then
        log "Installing/verifying Docker on '$VMNAME'..."
        configure_run_step "$SSH_HOST" "$VMNAME" install-docker
        DOCKER_STATE="installed"
    else
        log "Skipped Docker install step."
    fi
fi

TAILSCALE_STATE="skipped"

if [[ "$DO_TAILSCALE" == "1" ]]; then
    if [[ "$INTERACTIVE" == "0" ]] || confirm "Install/verify Tailscale on '$VMNAME'?"; then
        log "Installing/verifying Tailscale on '$VMNAME'..."
        configure_run_step "$SSH_HOST" "$VMNAME" install-tailscale
    else
        log "Skipped Tailscale install step."
    fi

    if [[ "$INTERACTIVE" == "0" ]] || confirm "Run 'tailscale up --hostname=${VMNAME}' on '$VMNAME' now?"; then
        log "Running 'tailscale up --hostname=${VMNAME}' on '$VMNAME'..."
        configure_bring_up_tailscale "$SSH_HOST" "$VMNAME" "$AUTHKEY"
    else
        log "Skipped 'tailscale up'."
    fi

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

    if [[ "$INTERACTIVE" == "0" ]] || confirm "Enable UFW on '$VMNAME' (deny all inbound except tailscale0)?"; then
        log "Enabling UFW on '$VMNAME' (deny all inbound except tailscale0)..."
        configure_run_step "$SSH_HOST" "$VMNAME" configure-ufw
        UFW_STATE="enabled"
    else
        log "Skipped enabling UFW."
    fi
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
