#!/usr/bin/env bash
# Usage: scripts/01_start_vm.sh <vmname>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

VMNAME="${1:?Usage: $0 <vmname>}"
validate_vmname "$VMNAME"

[[ -f "$(state_path "$VMNAME")" ]] || die "VM '$VMNAME' has no state file -- run scripts/00_init_vm.sh $VMNAME first."
vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt -- run scripts/00_init_vm.sh $VMNAME first."

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
