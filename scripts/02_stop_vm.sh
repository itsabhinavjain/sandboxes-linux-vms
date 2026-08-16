#!/usr/bin/env bash
# Usage: scripts/02_stop_vm.sh <vmname> [--force]
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

VMNAME="${1:?Usage: $0 <vmname> [--force]}"
shift || true
FORCE_STOP=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE_STOP=1
fi

validate_vmname "$VMNAME"

vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt."

if ! vm_is_running "$VMNAME"; then
    log "VM '$VMNAME' is not running."
    exit 0
fi

if [[ "$FORCE_STOP" == "1" ]]; then
    log "Force-stopping VM '$VMNAME' (hard power off)..."
    "${VIRSH[@]}" destroy "$VMNAME"
else
    log "Requesting graceful shutdown of VM '$VMNAME'..."
    "${VIRSH[@]}" shutdown "$VMNAME"
    log "Shutdown requested (ACPI). This is async -- the VM may take a while to actually stop."
fi

state_set "$VMNAME" .status "stopped"
