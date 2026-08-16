#!/usr/bin/env bash
# Usage: scripts/51_info_vms.sh
#
# Dumps the full state.yaml fields plus live libvirt domstate and the
# Tailscale SSH hint (if TAILSCALE_TAILNET is set) for every managed VM.
# For a single VM's info plus its full `virsh dominfo`, see 08_status_vm.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

check_bin yq

shopt -s nullglob
STATE_FILES=("$STORAGE_POOL_DISKS"/*.state.yaml)

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
    log "No VMs found."
    exit 0
fi

FIRST=1
for f in "${STATE_FILES[@]}"; do
    VMNAME="$(yq -r '.name' "$f")"
    LIVE="$("${VIRSH[@]}" domstate "$VMNAME" 2>/dev/null || echo "not-defined")"

    [[ "$FIRST" == "1" ]] || echo ""
    FIRST=0

    echo "name:        $(state_get "$VMNAME" .name)"
    echo "status:      $(state_get "$VMNAME" .status)"
    echo "live:        $LIVE"
    echo "autostart:   $(state_get "$VMNAME" .autostart)"
    echo "ram_mb:      $(state_get "$VMNAME" .ram_mb)"
    echo "vcpus:       $(state_get "$VMNAME" .vcpus)"
    echo "disk_gb:     $(state_get "$VMNAME" .disk_gb)"
    echo "base_image:  $(state_get "$VMNAME" .base_image)"
    echo "created_at:  $(state_get "$VMNAME" .created_at)"
    echo "started_at:  $(state_get "$VMNAME" .started_at)"
    echo "updated_at:  $(state_get "$VMNAME" .updated_at)"

    if [[ -n "${TAILSCALE_TAILNET:-}" ]]; then
        echo "ssh:         ${VMNAME}.${TAILSCALE_TAILNET}"
    fi
done
