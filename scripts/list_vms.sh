#!/usr/bin/env bash
# Usage: scripts/list_vms.sh
#
# Scans STORAGE_POOL_DISKS for all managed VM state files and prints a table
# cross-referencing state.yaml (authoritative resource config) against live
# libvirt domain status.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

check_bin yq

shopt -s nullglob
STATE_FILES=("$STORAGE_POOL_DISKS"/*.state.yaml)

if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
    log "No VMs found."
    exit 0
fi

printf "%-24s %-12s %-18s %-10s %-8s %-6s %-9s\n" "NAME" "LIVE" "STATE.YAML STATUS" "AUTOSTART" "RAM(MB)" "VCPUS" "DISK(GB)"

for f in "${STATE_FILES[@]}"; do
    VMNAME="$(yq -r '.name' "$f")"
    LIVE="$("${VIRSH[@]}" domstate "$VMNAME" 2>/dev/null || echo "not-defined")"
    STATUS="$(state_get "$VMNAME" .status)"
    AUTOSTART="$(state_get "$VMNAME" .autostart)"
    RAM="$(state_get "$VMNAME" .ram_mb)"
    VCPUS="$(state_get "$VMNAME" .vcpus)"
    DISK="$(state_get "$VMNAME" .disk_gb)"
    printf "%-24s %-12s %-18s %-10s %-8s %-6s %-9s\n" "$VMNAME" "$LIVE" "$STATUS" "$AUTOSTART" "$RAM" "$VCPUS" "$DISK"
done
