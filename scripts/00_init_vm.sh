#!/usr/bin/env bash
# Usage: scripts/00_init_vm.sh <vmname> [--ram MB] [--vcpus N] [--disk GB] [--image NAME] [--os-variant VARIANT] [--autostart|--no-autostart]
#
# Defines a new VM without starting it: creates a qcow2 overlay disk backed
# by the base cloud image, builds a cloud-init seed ISO, and `virsh define`s
# the domain. Run 01_start_vm.sh afterwards to boot it.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

check_bin virt-install
check_bin qemu-img
check_bin cloud-localds
check_bin envsubst
check_bin yq

VMNAME="${1:?Usage: $0 <vmname> [--ram MB] [--vcpus N] [--disk GB] [--image NAME] [--os-variant VARIANT] [--autostart|--no-autostart]}"
shift

RAM="$DEFAULT_RAM_MB"
VCPUS="$DEFAULT_VCPUS"
DISK="$DEFAULT_DISK_GB"
IMAGE="$DEFAULT_CLOUD_IMG"
OS_VARIANT="$DEFAULT_OS_VARIANT"
AUTOSTART="${DEFAULT_AUTOSTART:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ram)           RAM="$2"; shift 2 ;;
        --vcpus)         VCPUS="$2"; shift 2 ;;
        --disk)          DISK="$2"; shift 2 ;;
        --image)         IMAGE="$2"; shift 2 ;;
        --os-variant)    OS_VARIANT="$2"; shift 2 ;;
        --autostart)     AUTOSTART="true"; shift ;;
        --no-autostart)  AUTOSTART="false"; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

if [[ "$AUTOSTART" != "true" && "$AUTOSTART" != "false" ]]; then
    die "Invalid autostart value: '$AUTOSTART' (expected true or false -- check DEFAULT_AUTOSTART)"
fi

validate_vmname "$VMNAME"

[[ -d "$STORAGE_POOL_DISKS" ]] || die "STORAGE_POOL_DISKS ($STORAGE_POOL_DISKS) does not exist -- run the SETUP.md bootstrap first."

if vm_exists "$VMNAME" || [[ -f "$(state_path "$VMNAME")" ]]; then
    die "VM '$VMNAME' already exists. Run scripts/05_destroy_vm.sh $VMNAME first if you want to recreate it."
fi

BASE_IMAGE="$(base_image_path "$IMAGE")"
[[ -f "$BASE_IMAGE" ]] || die "Base image not found: $BASE_IMAGE (download it into STORAGE_POOL_IMAGES first)"

DISK_PATH="$(disk_path "$VMNAME")"
SEED_PATH="$(seed_path "$VMNAME")"

RENDER_DIR=""
cleanup() {
    local rc=$?
    [[ -n "$RENDER_DIR" && -d "$RENDER_DIR" ]] && rm -rf "$RENDER_DIR"
    if [[ $rc -ne 0 ]]; then
        log "00_init_vm.sh failed (exit $rc) -- rolling back partial state for '$VMNAME'"
        "${VIRSH[@]}" destroy "$VMNAME" >/dev/null 2>&1 || true
        "${VIRSH[@]}" undefine "$VMNAME" --nvram >/dev/null 2>&1 || true
        rm -f "$DISK_PATH" "$SEED_PATH" "$(state_path "$VMNAME")"
    fi
    exit "$rc"
}
trap cleanup EXIT

log "Writing initial state for '$VMNAME'..."
state_init "$VMNAME" "$RAM" "$VCPUS" "$DISK" "$IMAGE" "$AUTOSTART"

log "Creating disk image (${DISK}GB, backed by ${IMAGE})..."
qemu-img create -F qcow2 -b "$BASE_IMAGE" -f qcow2 "$DISK_PATH" "${DISK}G" >/dev/null

log "Rendering cloud-init config..."
RENDER_DIR="$(mktemp -d)"
export VMNAME
envsubst '${VMNAME}' < "$REPO_ROOT/setup_config/user-data.tmpl" > "$RENDER_DIR/user-data"
envsubst '${VMNAME}' < "$REPO_ROOT/setup_config/meta-data.tmpl" > "$RENDER_DIR/meta-data"

log "Building cloud-init seed ISO..."
cloud-localds "$SEED_PATH" "$RENDER_DIR/user-data" "$RENDER_DIR/meta-data"

log "Generating domain definition..."
virt-install \
    --connect qemu:///system \
    --name "$VMNAME" \
    --memory "$RAM" \
    --vcpus "$VCPUS" \
    --disk path="$DISK_PATH",format=qcow2,bus=virtio \
    --disk path="$SEED_PATH",device=cdrom \
    --os-variant "$OS_VARIANT" \
    --network network=default,model=virtio \
    --graphics none \
    --import \
    --print-xml --dry-run > "$RENDER_DIR/domain.xml"

"${VIRSH[@]}" define "$RENDER_DIR/domain.xml" >/dev/null

if [[ "$AUTOSTART" == "true" ]]; then
    log "Enabling autostart (VM will start automatically when libvirtd starts, e.g. after a host reboot)..."
    "${VIRSH[@]}" autostart "$VMNAME" >/dev/null
else
    # Explicit, rather than relying on virt-install's default, so behavior
    # doesn't depend on libvirt version/config.
    "${VIRSH[@]}" autostart --disable "$VMNAME" >/dev/null
fi

state_set "$VMNAME" .status "defined"

log "VM '$VMNAME' defined (not started). Run: scripts/01_start_vm.sh $VMNAME"
