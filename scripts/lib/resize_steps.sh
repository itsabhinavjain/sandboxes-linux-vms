#!/usr/bin/env bash
# Shared step logic for 12_resize_vm.sh: reading the actual current disk
# size, stopping/starting the VM around a resize, and applying each field
# (RAM/vCPUs/disk/autostart) to the libvirt domain + state.yaml. Source this
# after lib/common.sh, don't run it directly.
#
# RAM and vCPU changes go through `virsh set{maxmem,vcpus} --config` --
# persistent-config-only edits. virt-install originally defines memory/vcpus
# as a single value (current == max), so there's no separate live-hotplug
# ceiling to raise; a `--config` edit takes effect the next time the domain
# starts, not immediately. So instead of tracking live-vs-persistent
# separately, callers here always apply RAM/vCPU/disk changes while the VM
# is stopped, then restart it if it was running before -- simplest correct
# option, and matches "stop and restart as needed" from the original ask.
#
# Disk resize is grow-only (see resize_apply_disk_grow) -- shrinking a
# qcow2 can destroy data past the new boundary and needs an in-guest
# filesystem shrink first, which this toolkit doesn't attempt.

RESIZE_STOP_TIMEOUT="${RESIZE_STOP_TIMEOUT:-60}"
RESIZE_STOP_POLL_INTERVAL=3

# resize_disk_current_gb <vmname> -- echoes the qcow2's actual virtual size
# in whole GB (source of truth for disk size; state.yaml's disk_gb is a
# record of the last requested size, not re-derived from the file). Called
# unconditionally (even when only RAM/vCPUs/autostart are changing) to print
# the current-vs-requested row, so this has to work while the VM is running
# -- -U/--force-share tells qemu-img to read metadata without taking the
# lock qemu already holds on the attached disk (read-only inspection is safe
# here; the value doesn't change except through a resize applied while
# stopped, see resize_apply_disk_grow).
resize_disk_current_gb() {
    local vmname="$1" path bytes
    path="$(disk_path "$vmname")"
    bytes="$(qemu-img info -U --output=json "$path" | yq -p json -r '.["virtual-size"]')"
    echo $(( bytes / 1073741824 ))
}

# resize_print_row <label> <ram_mb> <vcpus> <disk_gb> <autostart>
resize_print_row() {
    printf "%-12s ram_mb=%-8s vcpus=%-4s disk_gb=%-6s autostart=%s\n" "$1" "$2" "$3" "$4" "$5"
}

# resize_stop_vm <vmname> <force:0|1> -- stops the VM and blocks until it's
# actually off (required before qemu-img resize / --config edits taking
# effect on next start). force=1 hard-powers-off immediately (virsh
# destroy, same semantics as 02_stop_vm.sh --force); force=0 requests a
# graceful ACPI shutdown and polls for up to RESIZE_STOP_TIMEOUT seconds,
# dying with a hint to retry with --force if it doesn't stop in time.
resize_stop_vm() {
    local vmname="$1" force="$2"
    if ! vm_is_running "$vmname"; then
        return 0
    fi
    if [[ "$force" == "1" ]]; then
        log "Force-stopping VM '$vmname' (hard power off)..."
        "${VIRSH[@]}" destroy "$vmname" >/dev/null
    else
        log "Requesting graceful shutdown of VM '$vmname'..."
        "${VIRSH[@]}" shutdown "$vmname" >/dev/null
        local waited=0
        while vm_is_running "$vmname"; do
            if (( waited >= RESIZE_STOP_TIMEOUT )); then
                die "VM '$vmname' did not stop within ${RESIZE_STOP_TIMEOUT}s -- retry with --force to hard power it off, or stop it manually first."
            fi
            sleep "$RESIZE_STOP_POLL_INTERVAL"
            waited=$(( waited + RESIZE_STOP_POLL_INTERVAL ))
        done
    fi
    state_set "$vmname" .status "stopped"
    log "VM '$vmname' is stopped."
}

# resize_start_vm <vmname> -- starts the VM back up (mirrors 01_start_vm.sh).
resize_start_vm() {
    local vmname="$1"
    log "Starting VM '$vmname'..."
    "${VIRSH[@]}" start "$vmname" >/dev/null
    state_set "$vmname" .status "running"
    state_set "$vmname" .started_at "$(now_utc)"
}

# resize_apply_ram <vmname> <new_ram_mb> -- VM must already be stopped.
resize_apply_ram() {
    local vmname="$1" new_ram_mb="$2"
    log "Setting RAM to ${new_ram_mb}MiB (persistent config)..."
    "${VIRSH[@]}" setmaxmem "$vmname" "${new_ram_mb}MiB" --config >/dev/null
    "${VIRSH[@]}" setmem "$vmname" "${new_ram_mb}MiB" --config >/dev/null
}

# resize_apply_vcpus <vmname> <new_vcpus> -- VM must already be stopped.
resize_apply_vcpus() {
    local vmname="$1" new_vcpus="$2"
    log "Setting vCPUs to ${new_vcpus} (persistent config)..."
    "${VIRSH[@]}" setvcpus "$vmname" "$new_vcpus" --config --maximum >/dev/null
    "${VIRSH[@]}" setvcpus "$vmname" "$new_vcpus" --config >/dev/null
}

# resize_apply_disk_grow <vmname> <new_disk_gb> <current_disk_gb> -- VM must
# already be stopped. Refuses to shrink. No-ops if sizes already match.
resize_apply_disk_grow() {
    local vmname="$1" new_disk_gb="$2" current_disk_gb="$3"
    if (( new_disk_gb < current_disk_gb )); then
        die "Refusing to shrink disk for '$vmname' (current ${current_disk_gb}G -> requested ${new_disk_gb}G) -- shrinking a qcow2 can destroy data past the new boundary and needs an in-guest filesystem shrink first, which this toolkit doesn't do. Pick a size >= ${current_disk_gb}G."
    fi
    if (( new_disk_gb == current_disk_gb )); then
        log "Disk already ${current_disk_gb}G, nothing to grow."
        return 0
    fi
    log "Growing disk to ${new_disk_gb}G (was ${current_disk_gb}G)..."
    qemu-img resize "$(disk_path "$vmname")" "${new_disk_gb}G" >/dev/null
    log "Disk grown. Remember to grow the guest's partition/filesystem too (e.g. 'sudo growpart /dev/vda 1 && sudo resize2fs /dev/vda1') -- this only resized the block device."
}

# resize_apply_autostart <vmname> <true|false> -- works regardless of VM
# run state, no stop/start needed.
resize_apply_autostart() {
    local vmname="$1" new_autostart="$2"
    if [[ "$new_autostart" == "true" ]]; then
        log "Enabling autostart for '$vmname'..."
        "${VIRSH[@]}" autostart "$vmname" >/dev/null
    else
        log "Disabling autostart for '$vmname'..."
        "${VIRSH[@]}" autostart --disable "$vmname" >/dev/null
    fi
}
