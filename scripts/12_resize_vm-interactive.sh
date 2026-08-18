#!/usr/bin/env bash
# Usage: scripts/12_resize_vm-interactive.sh <vmname>
#
# Interactive counterpart to 12_resize_vm-automated.sh: shows the VM's
# current shape (RAM, vCPUs, disk, autostart), prompts for each field
# (blank = keep current), then confirms once before applying -- same
# underlying apply logic as the -automated variant
# (scripts/lib/resize_steps.sh), just gathering the new values
# interactively instead of via flags.
#
# RAM/vCPU/disk changes require the VM to be stopped; if any of those
# actually change and the VM is currently running, this stops it (graceful
# ACPI shutdown, waits for it to actually stop), applies the changes, and
# starts it back up. If the VM is already stopped, changes are applied and
# it's left stopped. Disk resize is grow-only -- shrinking is refused.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resize_steps.sh"
require_env

check_bin qemu-img
check_bin yq

VMNAME="${1:?Usage: scripts/12_resize_vm-interactive.sh <vmname>}"
validate_vmname "$VMNAME"

[[ -f "$(state_path "$VMNAME")" ]] || die "No state file for '$VMNAME' -- run scripts/00_init_vm-automated.sh $VMNAME first."
vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt."

CUR_RAM="$(state_get "$VMNAME" .ram_mb)"
CUR_VCPUS="$(state_get "$VMNAME" .vcpus)"
CUR_AUTOSTART="$(state_get "$VMNAME" .autostart)"
CUR_DISK="$(resize_disk_current_gb "$VMNAME")"

resize_print_row "Current:" "$CUR_RAM" "$CUR_VCPUS" "$CUR_DISK" "$CUR_AUTOSTART"
echo ""

read -r -p "RAM in MB [${CUR_RAM}]: " NEW_RAM
NEW_RAM="${NEW_RAM:-$CUR_RAM}"

read -r -p "vCPUs [${CUR_VCPUS}]: " NEW_VCPUS
NEW_VCPUS="${NEW_VCPUS:-$CUR_VCPUS}"

while true; do
    read -r -p "Disk size in GB (grow-only) [${CUR_DISK}]: " NEW_DISK
    NEW_DISK="${NEW_DISK:-$CUR_DISK}"
    if (( NEW_DISK < CUR_DISK )); then
        echo "Disk size can't be smaller than the current ${CUR_DISK}G (shrink isn't supported). Try again." >&2
        continue
    fi
    break
done

while true; do
    read -r -p "Autostart true/false [${CUR_AUTOSTART}]: " NEW_AUTOSTART
    NEW_AUTOSTART="${NEW_AUTOSTART:-$CUR_AUTOSTART}"
    if [[ "$NEW_AUTOSTART" == "true" || "$NEW_AUTOSTART" == "false" ]]; then
        break
    fi
    echo "Enter 'true' or 'false'." >&2
done

RAM_CHANGED=0
VCPUS_CHANGED=0
DISK_CHANGED=0
AUTOSTART_CHANGED=0

[[ "$NEW_RAM" != "$CUR_RAM" ]] && RAM_CHANGED=1
[[ "$NEW_VCPUS" != "$CUR_VCPUS" ]] && VCPUS_CHANGED=1
[[ "$NEW_DISK" != "$CUR_DISK" ]] && DISK_CHANGED=1
[[ "$NEW_AUTOSTART" != "$CUR_AUTOSTART" ]] && AUTOSTART_CHANGED=1

if [[ "$RAM_CHANGED" == "0" && "$VCPUS_CHANGED" == "0" && "$DISK_CHANGED" == "0" && "$AUTOSTART_CHANGED" == "0" ]]; then
    log "No changes requested for '$VMNAME'."
    exit 0
fi

echo ""
resize_print_row "Requested:" "$NEW_RAM" "$NEW_VCPUS" "$NEW_DISK" "$NEW_AUTOSTART"
echo ""

NEEDS_STOP=0
[[ "$RAM_CHANGED" == "1" || "$VCPUS_CHANGED" == "1" || "$DISK_CHANGED" == "1" ]] && NEEDS_STOP=1

WAS_RUNNING=0
vm_is_running "$VMNAME" && WAS_RUNNING=1

if [[ "$NEEDS_STOP" == "1" && "$WAS_RUNNING" == "1" ]]; then
    confirm "Apply these changes to '$VMNAME'? This will stop and restart it" || { log "Aborted, no changes made."; exit 0; }
else
    confirm "Apply these changes to '$VMNAME'?" || { log "Aborted, no changes made."; exit 0; }
fi

if [[ "$NEEDS_STOP" == "1" && "$WAS_RUNNING" == "1" ]]; then
    resize_stop_vm "$VMNAME" 0
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
