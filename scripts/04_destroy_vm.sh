#!/usr/bin/env bash
# Usage: scripts/04_destroy_vm.sh <vmname> [--force]
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    04_destroy_vm.sh -- permanently delete a VM

USAGE
    scripts/04_destroy_vm.sh <vmname> [--force]

    Force-stops the VM if running, undefines the libvirt domain and its
    storage, and removes the qcow2/seed/state files.

REQUIRED
    <vmname>    VM name

OPTIONS
    --force     Skip the "are you sure?" confirmation prompt
    -h, --help  Show this help and exit
EOF
)
show_help_if_requested "$USAGE" "$@"
require_env

VMNAME="${1:?Missing <vmname>. Run 'scripts/04_destroy_vm.sh --help' for usage.}"
shift

FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

validate_vmname "$VMNAME"

DISK_PATH="$(disk_path "$VMNAME")"
SEED_PATH="$(seed_path "$VMNAME")"
STATE_PATH="$(state_path "$VMNAME")"

if ! vm_exists "$VMNAME" && [[ ! -f "$STATE_PATH" && ! -f "$DISK_PATH" ]]; then
    die "VM '$VMNAME' not found (no libvirt domain, disk, or state file)."
fi

echo "This will permanently delete VM '$VMNAME':"
echo "  - libvirt definition"
echo "  - $DISK_PATH"
echo "  - $SEED_PATH"
echo "  - $STATE_PATH"
echo ""
confirm "Continue?" || { log "Aborted."; exit 1; }

if vm_is_running "$VMNAME"; then
    log "Stopping running VM..."
    "${VIRSH[@]}" destroy "$VMNAME" || true
fi

if vm_exists "$VMNAME"; then
    log "Removing libvirt definition and disks..."
    "${VIRSH[@]}" undefine "$VMNAME" --remove-all-storage --nvram 2>/dev/null \
        || "${VIRSH[@]}" undefine "$VMNAME" --remove-all-storage
fi

# Belt-and-suspenders: remove leftover files even if libvirt missed them
# (e.g. the domain was undefined manually outside these scripts).
[[ -f "$DISK_PATH" ]]  && { log "Removing leftover disk file...";  rm -f "$DISK_PATH"; }
[[ -f "$SEED_PATH" ]]  && { log "Removing leftover seed ISO...";   rm -f "$SEED_PATH"; }
[[ -f "$STATE_PATH" ]] && { log "Removing state file...";         rm -f "$STATE_PATH"; }

log "VM '$VMNAME' fully deleted."
if [[ -n "${TAILSCALE_TAILNET:-}" ]]; then
    log "NOTE: also run this on any machine that has SSH'd into it:"
    log "    ssh-keygen -R ${VMNAME}.${TAILSCALE_TAILNET}"
fi
