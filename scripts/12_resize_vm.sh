#!/usr/bin/env bash
# Usage: scripts/12_resize_vm.sh <vmname> [-i|--interactive] [--ram MB] [--vcpus N] [--disk GB] [--autostart|--no-autostart] [--force]
#
# Edits an existing VM's shape (RAM, vCPUs, disk, autostart) via
# scripts/lib/resize_steps.sh. Every field is optional -- only fields
# actually given (as a flag, or answered at a prompt) change; the rest are
# left as-is. Prints current vs. requested config before doing anything, and
# exits cleanly with no changes if nothing differs.
#
# RAM/vCPU/disk changes require the VM to be stopped (virsh set{maxmem,vcpus}
# --config has no live ceiling to hotplug into, and disk resize needs the
# disk not in use); if any of those actually change and the VM is currently
# running, this stops it, applies the changes, and starts it back up. If
# already stopped, changes are applied and it's left stopped. Disk resize is
# grow-only -- shrinking is refused. Autostart changes apply immediately
# regardless of run state.
#
# Default (no -i): applies requested changes with no confirmation prompt.
# With -i/--interactive: any field not given as a flag is prompted for,
# seeded with the VM's *current* value (blank = keep it; disk re-prompts if
# you try to shrink it), and a single confirmation is required before
# applying.
#
# --force, if a stop is needed, hard-powers the VM off (virsh destroy)
# instead of waiting for a graceful shutdown -- same meaning as
# 02_stop_vm.sh --force.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resize_steps.sh"

USAGE=$(cat <<EOF
NAME
    12_resize_vm.sh -- change an existing VM's RAM, vCPUs, disk size, or autostart

USAGE
    scripts/12_resize_vm.sh <vmname> [-i|--interactive] [options]

    Only the fields you pass (or answer at a prompt, in -i mode) change --
    everything else is left as-is. Disk resize is grow-only.

REQUIRED
    <vmname>
        VM name of an already-defined VM

OPTIONS
    -i, --interactive
        Prompt for any field below not passed explicitly as a flag, seeded
        with the VM's current value; confirm once before applying
    --ram MB
        New RAM in MB
    --vcpus N
        New vCPU count
    --disk GB
        New disk size in GB (grow-only)
    --autostart
        Enable libvirt autostart
    --no-autostart
        Disable libvirt autostart
    --force
        If a stop is needed, hard power off instead of graceful ACPI shutdown
    -h, --help
        Show this help and exit

EXAMPLES
    scripts/12_resize_vm.sh myvm --ram 4096
    scripts/12_resize_vm.sh myvm -i
EOF
)
show_help_if_requested "$USAGE" "$@"

require_env
check_bin qemu-img
check_bin yq

VMNAME="${1:?Missing <vmname>. Run 'scripts/12_resize_vm.sh --help' for usage.}"
shift

INTERACTIVE=0
NEW_RAM=""
NEW_VCPUS=""
NEW_DISK=""
NEW_AUTOSTART=""
FORCE_STOP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interactive) INTERACTIVE=1; shift ;;
        --ram)           NEW_RAM="$2"; shift 2 ;;
        --vcpus)         NEW_VCPUS="$2"; shift 2 ;;
        --disk)          NEW_DISK="$2"; shift 2 ;;
        --autostart)     NEW_AUTOSTART="true"; shift ;;
        --no-autostart)  NEW_AUTOSTART="false"; shift ;;
        --force)         FORCE_STOP=1; shift ;;
        -h|--help)       printf '%s\n' "$USAGE"; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

validate_vmname "$VMNAME"

[[ -f "$(state_path "$VMNAME")" ]] || die "No state file for '$VMNAME' -- run scripts/00_init_vm.sh $VMNAME first."
vm_exists "$VMNAME" || die "VM '$VMNAME' is not defined in libvirt."

CUR_RAM="$(state_get "$VMNAME" .ram_mb)"
CUR_VCPUS="$(state_get "$VMNAME" .vcpus)"
CUR_AUTOSTART="$(state_get "$VMNAME" .autostart)"
CUR_DISK="$(resize_disk_current_gb "$VMNAME")"

resize_print_row "Current:" "$CUR_RAM" "$CUR_VCPUS" "$CUR_DISK" "$CUR_AUTOSTART"

if [[ "$INTERACTIVE" == "1" ]]; then
    echo ""
    [[ -n "$NEW_RAM" ]]    || NEW_RAM="$(prompt_int "RAM in MB" "$CUR_RAM")"
    [[ -n "$NEW_VCPUS" ]]  || NEW_VCPUS="$(prompt_int "vCPUs" "$CUR_VCPUS")"
    if [[ -z "$NEW_DISK" ]]; then
        while true; do
            NEW_DISK="$(prompt_int "Disk size in GB (grow-only)" "$CUR_DISK")"
            if (( NEW_DISK < CUR_DISK )); then
                echo "Disk size can't be smaller than the current ${CUR_DISK}G (shrink isn't supported). Try again." >&2
                NEW_DISK=""
                continue
            fi
            break
        done
    fi
    [[ -n "$NEW_AUTOSTART" ]] || NEW_AUTOSTART="$(prompt_bool "Autostart" "$CUR_AUTOSTART")"
else
    NEW_RAM="${NEW_RAM:-$CUR_RAM}"
    NEW_VCPUS="${NEW_VCPUS:-$CUR_VCPUS}"
    NEW_DISK="${NEW_DISK:-$CUR_DISK}"
    NEW_AUTOSTART="${NEW_AUTOSTART:-$CUR_AUTOSTART}"
fi

if (( NEW_DISK < CUR_DISK )); then
    die "Refusing to shrink disk for '$VMNAME' (current ${CUR_DISK}G -> requested ${NEW_DISK}G) -- shrinking a qcow2 can destroy data past the new boundary and needs an in-guest filesystem shrink first, which this toolkit doesn't do. Pick a size >= ${CUR_DISK}G."
fi

RAM_CHANGED=0
VCPUS_CHANGED=0
DISK_CHANGED=0
AUTOSTART_CHANGED=0

[[ "$NEW_RAM" != "$CUR_RAM" ]] && RAM_CHANGED=1
[[ "$NEW_VCPUS" != "$CUR_VCPUS" ]] && VCPUS_CHANGED=1
[[ "$NEW_DISK" != "$CUR_DISK" ]] && DISK_CHANGED=1
[[ "$NEW_AUTOSTART" != "$CUR_AUTOSTART" ]] && AUTOSTART_CHANGED=1

echo ""
resize_print_row "Requested:" "$NEW_RAM" "$NEW_VCPUS" "$NEW_DISK" "$NEW_AUTOSTART"

if [[ "$RAM_CHANGED" == "0" && "$VCPUS_CHANGED" == "0" && "$DISK_CHANGED" == "0" && "$AUTOSTART_CHANGED" == "0" ]]; then
    log "No changes requested for '$VMNAME'."
    exit 0
fi

NEEDS_STOP=0
[[ "$RAM_CHANGED" == "1" || "$VCPUS_CHANGED" == "1" || "$DISK_CHANGED" == "1" ]] && NEEDS_STOP=1

WAS_RUNNING=0
vm_is_running "$VMNAME" && WAS_RUNNING=1

if [[ "$INTERACTIVE" == "1" ]]; then
    echo ""
    if [[ "$NEEDS_STOP" == "1" && "$WAS_RUNNING" == "1" ]]; then
        confirm "Apply these changes to '$VMNAME'? This will stop and restart it" || { log "Aborted, no changes made."; exit 0; }
    else
        confirm "Apply these changes to '$VMNAME'?" || { log "Aborted, no changes made."; exit 0; }
    fi
fi

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
