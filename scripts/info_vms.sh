#!/usr/bin/env bash
# Usage: scripts/info_vms.sh <vmname>
#
# Dumps the state.yaml fields for a single VM plus its live libvirt domstate
# and the Tailscale SSH hint (if TAILSCALE_TAILNET is set).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

check_bin yq

VMNAME="${1:?Usage: $0 <vmname>}"
validate_vmname "$VMNAME"

STATE_PATH="$(state_path "$VMNAME")"
[[ -f "$STATE_PATH" ]] || die "No state file for '$VMNAME' ($STATE_PATH) -- has it been created with scripts/00_init.sh?"

LIVE="$("${VIRSH[@]}" domstate "$VMNAME" 2>/dev/null || echo "not-defined")"

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
    echo ""
    echo "ssh ${VMNAME}.${TAILSCALE_TAILNET}"
fi
