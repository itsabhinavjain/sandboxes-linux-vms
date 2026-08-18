#!/usr/bin/env bash
# Usage: ./scripts/02_stop_vm.sh <vmname> [--force]
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    02_stop_vm.sh -- stop a running VM

USAGE
    ./scripts/02_stop_vm.sh <vmname> [--force]

REQUIRED
    <vmname>    VM name of an already-defined VM

OPTIONS
    --force     Hard power off (virsh destroy) instead of a graceful ACPI shutdown
    -h, --help  Show this help and exit

No-op (exit 0) if the VM is already stopped. Without --force, shutdown is
requested (ACPI) and async -- the VM may take a while to actually stop.
EOF
)
show_help_if_requested "$USAGE" "$@"
require_env

VMNAME="${1:?Missing <vmname>. Run './scripts/02_stop_vm.sh --help' for usage.}"
shift

FORCE_STOP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE_STOP=1; shift ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

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
