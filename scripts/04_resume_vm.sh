#!/usr/bin/env bash
# Usage: scripts/04_resume_vm.sh <vmname>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

VMNAME="${1:?Usage: $0 <vmname>}"
validate_vmname "$VMNAME"

vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt."

CURRENT_STATE="$("${VIRSH[@]}" domstate "$VMNAME")"

if [[ "$CURRENT_STATE" != "paused" ]]; then
    log "VM '$VMNAME' is not paused (current state: $CURRENT_STATE). Nothing to resume."
    exit 0
fi

log "Resuming VM '$VMNAME'..."
"${VIRSH[@]}" resume "$VMNAME"

state_set "$VMNAME" .status "running"

log "VM '$VMNAME' resumed."
