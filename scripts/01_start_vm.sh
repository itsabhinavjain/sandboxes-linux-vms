#!/usr/bin/env bash
# Usage: ./scripts/01_start_vm.sh <vmname>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    01_start_vm.sh -- start a defined (or stopped) VM

USAGE
    ./scripts/01_start_vm.sh <vmname>

REQUIRED
    <vmname>    VM name of an already-defined VM (./scripts/00_init_vm.sh)

OPTIONS
    -h, --help  Show this help and exit

No-op (exit 0) if the VM is already running.
EOF
)
show_help_if_requested "$USAGE" "$@"
require_env

VMNAME="${1:?Missing <vmname>. Run './scripts/01_start_vm.sh --help' for usage.}"
validate_vmname "$VMNAME"

[[ -f "$(state_path "$VMNAME")" ]] || die "VM '$VMNAME' has no state file -- run ./scripts/00_init_vm.sh $VMNAME first."
vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt -- run ./scripts/00_init_vm.sh $VMNAME first."

if vm_is_running "$VMNAME"; then
    log "VM '$VMNAME' is already running."
    exit 0
fi

log "Starting VM '$VMNAME'..."
"${VIRSH[@]}" start "$VMNAME"

state_set "$VMNAME" .status "running"
state_set "$VMNAME" .started_at "$(now_utc)"

log "VM '$VMNAME' is starting up. Cloud-init is configuring it now."
if [[ -n "${TAILSCALE_TAILNET:-}" ]]; then
    log "Wait ~60-90 seconds, then try: ssh ${VMNAME}.${TAILSCALE_TAILNET}"
fi
log "Watch progress with: virsh -c qemu:///system console $VMNAME  (Ctrl+] to exit)"

STATE_TAILSCALE="$(state_get "$VMNAME" .tailscale 2>/dev/null || echo null)"
if [[ "$STATE_TAILSCALE" == "up" ]]; then
    log "This VM was previously joined to the tailnet. tailscaled normally just resumes on boot, same hostname, no action needed."
    log "If it doesn't reappear in 'tailscale status' after a minute (can happen if it was stopped a long time -- ephemeral keys get cleaned up by Tailscale on its own schedule), rejoin with:"
    log "    ./scripts/11_configure_vm.sh $VMNAME --skip-docker --skip-ufw"
fi
