#!/usr/bin/env bash
# Usage: scripts/12_resize_vm-automated.sh <vmname> [--ram MB] [--vcpus N] [--disk GB] [--autostart|--no-autostart] [--force]
#
# Fire-and-forget counterpart to 12_resize_vm-interactive.sh: edits an
# existing VM's shape (RAM, vCPUs, disk, autostart) with no prompts. Unlike
# 00_init_vm-automated.sh, every flag is optional here and only the fields
# you actually pass are changed -- omitted flags mean "leave as-is". Prints
# current vs. requested config before doing anything.
#
# RAM/vCPU/disk changes require the VM to be stopped (see
# scripts/lib/resize_steps.sh for why); if any of those actually change and
# the VM is currently running, this script stops it, applies the changes,
# and starts it back up. If the VM is already stopped, changes are applied
# and it's left stopped. Disk resize is grow-only -- shrinking is refused.
# Autostart changes apply immediately regardless of run state, no
# stop/restart needed for that alone.
#
# --force, if a stop is needed, hard-powers the VM off (virsh destroy)
# instead of waiting for a graceful ACPI shutdown -- same meaning as
# 02_stop_vm.sh --force.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resize_steps.sh"
require_env

check_bin qemu-img
check_bin yq

VMNAME="${1:?Usage: scripts/12_resize_vm-automated.sh <vmname> [--ram MB] [--vcpus N] [--disk GB] [--autostart|--no-autostart] [--force]}"
shift

NEW_RAM=""
NEW_VCPUS=""
NEW_DISK=""
NEW_AUTOSTART=""
FORCE_STOP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ram)           NEW_RAM="$2"; shift 2 ;;
        --vcpus)         NEW_VCPUS="$2"; shift 2 ;;
        --disk)          NEW_DISK="$2"; shift 2 ;;
        --autostart)     NEW_AUTOSTART="true"; shift ;;
        --no-autostart)  NEW_AUTOSTART="false"; shift ;;
        --force)         FORCE_STOP=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

validate_vmname "$VMNAME"

[[ -f "$(state_path "$VMNAME")" ]] || die "No state file for '$VMNAME' -- run scripts/00_init_vm-automated.sh $VMNAME first."
vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt."

CUR_RAM="$(state_get "$VMNAME" .ram_mb)"
CUR_VCPUS="$(state_get "$VMNAME" .vcpus)"
CUR_AUTOSTART="$(state_get "$VMNAME" .autostart)"
CUR_DISK="$(resize_disk_current_gb "$VMNAME")"

resize_print_row "Current:"   "$CUR_RAM" "$CUR_VCPUS" "$CUR_DISK" "$CUR_AUTOSTART"
resize_print_row "Requested:" "${NEW_RAM:-$CUR_RAM}" "${NEW_VCPUS:-$CUR_VCPUS}" "${NEW_DISK:-$CUR_DISK}" "${NEW_AUTOSTART:-$CUR_AUTOSTART}"

RAM_CHANGED=0
VCPUS_CHANGED=0
DISK_CHANGED=0
AUTOSTART_CHANGED=0

[[ -n "$NEW_RAM" && "$NEW_RAM" != "$CUR_RAM" ]] && RAM_CHANGED=1
[[ -n "$NEW_VCPUS" && "$NEW_VCPUS" != "$CUR_VCPUS" ]] && VCPUS_CHANGED=1
[[ -n "$NEW_DISK" && "$NEW_DISK" != "$CUR_DISK" ]] && DISK_CHANGED=1
[[ -n "$NEW_AUTOSTART" && "$NEW_AUTOSTART" != "$CUR_AUTOSTART" ]] && AUTOSTART_CHANGED=1

if [[ "$RAM_CHANGED" == "0" && "$VCPUS_CHANGED" == "0" && "$DISK_CHANGED" == "0" && "$AUTOSTART_CHANGED" == "0" ]]; then
    log "No changes requested for '$VMNAME'."
    exit 0
fi

NEEDS_STOP=0
[[ "$RAM_CHANGED" == "1" || "$VCPUS_CHANGED" == "1" || "$DISK_CHANGED" == "1" ]] && NEEDS_STOP=1

WAS_RUNNING=0
vm_is_running "$VMNAME" && WAS_RUNNING=1

if [[ "$NEEDS_STOP" == "1" && "$WAS_RUNNING" == "1" ]]; then
    resize_stop_vm "$VMNAME" "$FORCE_STOP"
fi

[[ "$RAM_CHANGED" == "1" ]]   && resize_apply_ram "$VMNAME" "$NEW_RAM"
[[ "$VCPUS_CHANGED" == "1" ]] && resize_apply_vcpus "$VMNAME" "$NEW_VCPUS"
[[ "$DISK_CHANGED" == "1" ]]  && resize_apply_disk_grow "$VMNAME" "$NEW_DISK" "$CUR_DISK"
[[ "$AUTOSTART_CHANGED" == "1" ]] && resize_apply_autostart "$VMNAME" "$NEW_AUTOSTART"

if [[ "$NEEDS_STOP" == "1" && "$WAS_RUNNING" == "1" ]]; then
    resize_start_vm "$VMNAME"
fi

[[ "$RAM_CHANGED" == "1" ]]    && state_set_raw "$VMNAME" .ram_mb "$NEW_RAM"
[[ "$VCPUS_CHANGED" == "1" ]]  && state_set_raw "$VMNAME" .vcpus "$NEW_VCPUS"
[[ "$DISK_CHANGED" == "1" ]]   && state_set_raw "$VMNAME" .disk_gb "$NEW_DISK"
[[ "$AUTOSTART_CHANGED" == "1" ]] && state_set "$VMNAME" .autostart "$NEW_AUTOSTART"

log "Resize complete for '$VMNAME'."
