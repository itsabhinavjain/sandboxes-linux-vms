#!/usr/bin/env bash
# Usage: scripts/03_reboot.sh <vmname>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

VMNAME="${1:?Usage: $0 <vmname>}"
validate_vmname "$VMNAME"

vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt."
vm_is_running "$VMNAME" || die "VM '$VMNAME' is not running -- nothing to reboot."

log "Rebooting VM '$VMNAME'..."
"${VIRSH[@]}" reboot "$VMNAME"

# No dedicated state_touch helper -- re-setting .status also bumps updated_at.
state_set "$VMNAME" .status "running"

log "Reboot requested for VM '$VMNAME'."
