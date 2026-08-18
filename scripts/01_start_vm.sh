#!/usr/bin/env bash
# Usage: scripts/01_start_vm.sh <vmname>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    01_start_vm.sh -- start a defined (or stopped) VM

USAGE
    scripts/01_start_vm.sh <vmname>

REQUIRED
    <vmname>    VM name of an already-defined VM (scripts/00_init_vm.sh)

OPTIONS
    -h, --help  Show this help and exit

No-op (exit 0) if the VM is already running.
EOF
)
show_help_if_requested "$USAGE" "$@"
require_env

VMNAME="${1:?Missing <vmname>. Run 'scripts/01_start_vm.sh --help' for usage.}"
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
