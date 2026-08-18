#!/usr/bin/env bash
# Usage: scripts/00_init_vm-interactive.sh
#
# Interactive counterpart to 00_init_vm-automated.sh: prompts for the VM
# name and shape (RAM, vCPUs, disk, base image, OS variant, autostart),
# showing each DEFAULT_* env var as the default, then execs into
# 00_init_vm-automated.sh with the collected values as flags. Owns no
# disk/domain-creation logic itself -- that all lives in the automated script.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

# prompt_default <prompt> <default> -- echoes user input, or the default if blank.
prompt_default() {
    local prompt="$1" default="$2" reply
    read -r -p "${prompt} [${default}]: " reply
    echo "${reply:-$default}"
}

# prompt_int <prompt> <default> -- like prompt_default, but re-prompts until
# the value is a positive integer.
prompt_int() {
    local prompt="$1" default="$2" value
    while true; do
        value="$(prompt_default "$prompt" "$default")"
        [[ "$value" =~ ^[1-9][0-9]*$ ]] && { echo "$value"; return 0; }
        echo "Please enter a positive whole number." >&2
    done
}

# prompt_bool <prompt> <default: true|false> -- blank input keeps the default.
prompt_bool() {
    local prompt="$1" default="$2" reply
    while true; do
        read -r -p "${prompt} (true/false) [${default}]: " reply
        reply="${reply:-$default}"
        case "$reply" in
            true|false) echo "$reply"; return 0 ;;
            *) echo "Please enter 'true' or 'false'." >&2 ;;
        esac
    done
}

VMNAME=""
while [[ -z "$VMNAME" ]]; do
    read -r -p "VM name: " VMNAME
    if [[ -z "$VMNAME" ]]; then
        echo "VM name is required." >&2
        continue
    fi
    if ! [[ "$VMNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid VM name '$VMNAME': only letters, digits, '_' and '-' are allowed." >&2
        VMNAME=""
        continue
    fi
    if vm_exists "$VMNAME" || [[ -f "$(state_path "$VMNAME")" ]]; then
        echo "VM '$VMNAME' already exists. Run scripts/05_destroy_vm.sh $VMNAME first if you want to recreate it." >&2
        VMNAME=""
    fi
done

RAM="$(prompt_int "RAM (MB)" "$DEFAULT_RAM_MB")"
VCPUS="$(prompt_int "vCPUs" "$DEFAULT_VCPUS")"
DISK="$(prompt_int "Disk (GB)" "$DEFAULT_DISK_GB")"
IMAGE="$(prompt_default "Base image" "$DEFAULT_CLOUD_IMG")"
OS_VARIANT="$(prompt_default "OS variant" "$DEFAULT_OS_VARIANT")"

AUTOSTART="$(prompt_bool "Enable libvirt autostart (start '$VMNAME' automatically whenever libvirtd starts)?" "${DEFAULT_AUTOSTART:-false}")"

AUTOSTART_FLAG="--no-autostart"
[[ "$AUTOSTART" == "true" ]] && AUTOSTART_FLAG="--autostart"

log "Handing off to 00_init_vm-automated.sh..."
exec "$(dirname "${BASH_SOURCE[0]}")/00_init_vm-automated.sh" "$VMNAME" \
    --ram "$RAM" \
    --vcpus "$VCPUS" \
    --disk "$DISK" \
    --image "$IMAGE" \
    --os-variant "$OS_VARIANT" \
    "$AUTOSTART_FLAG"
