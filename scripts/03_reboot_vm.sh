#!/usr/bin/env bash
# Usage: ./scripts/03_reboot_vm.sh <vmname>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    03_reboot_vm.sh -- reboot a running VM in place

USAGE
    ./scripts/03_reboot_vm.sh <vmname>

REQUIRED
    <vmname>    VM name of an already-running VM

OPTIONS
    -h, --help  Show this help and exit
EOF
)
show_help_if_requested "$USAGE" "$@"
require_env

VMNAME="${1:?Missing <vmname>. Run './scripts/03_reboot_vm.sh --help' for usage.}"
validate_vmname "$VMNAME"

vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt."
vm_is_running "$VMNAME" || die "VM '$VMNAME' is not running -- nothing to reboot."

log "Rebooting VM '$VMNAME'..."
"${VIRSH[@]}" reboot "$VMNAME"

# No dedicated state_touch helper -- re-setting .status also bumps updated_at.
state_set "$VMNAME" .status "running"

log "Reboot requested for VM '$VMNAME'."
