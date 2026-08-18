#!/usr/bin/env bash
# Usage: scripts/00_init_vm.sh <vmname> [-i|--interactive] [--ram MB] [--vcpus N] [--disk GB] [--image NAME] [--os-variant VARIANT] [--autostart|--no-autostart]
#
# Defines a new VM without starting it: creates a qcow2 overlay disk backed
# by the base cloud image, builds a cloud-init seed ISO, and `virsh define`s
# the domain. Run 01_start_vm.sh afterwards to boot it.
#
# Flag/env-driven by default: RAM, vCPUs, disk, etc. all resolve from
# DEFAULT_* (system env / .env), any of which an explicit flag overrides.
# With -i/--interactive, any field NOT given as an explicit flag is prompted
# for instead (showing the resolved default; blank input accepts it) rather
# than silently applied. Run with --help for the full flag reference.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    00_init_vm.sh -- define a new VM (qcow2 overlay disk + cloud-init seed ISO + libvirt domain)

USAGE
    scripts/00_init_vm.sh <vmname> [-i|--interactive] [options]

    Defines the VM only -- it is not started. Run 01_start_vm.sh afterwards.
    Fails if a VM with the same name already exists (in libvirt or as a
    leftover state file); run 04_destroy_vm.sh first to recreate it.

REQUIRED
    <vmname>
        VM name -- letters, digits, '_', '-' only

OPTIONS
    -i, --interactive
        Prompt for any field below not passed explicitly as a flag (shows
        the resolved default; blank input accepts it)
    --ram MB
        RAM in MB (default: ${DEFAULT_RAM_MB:-<unset, see SETUP.md>})
    --vcpus N
        vCPU count (default: ${DEFAULT_VCPUS:-<unset, see SETUP.md>})
    --disk GB
        Disk size in GB (default: ${DEFAULT_DISK_GB:-<unset, see SETUP.md>})
    --image NAME
        Base cloud image name (default: ${DEFAULT_CLOUD_IMG:-<unset, see SETUP.md>})
    --os-variant VARIANT
        virt-install --os-variant value (default: ${DEFAULT_OS_VARIANT:-<unset, see SETUP.md>})
    --autostart
        Start this VM whenever libvirtd starts (e.g. after a host reboot)
    --no-autostart
        Do not autostart (default: ${DEFAULT_AUTOSTART:-false})
    -h, --help
        Show this help and exit

VALUE PRECEDENCE
    system env < .env (repo root) < explicit flag. See README.md.

EXAMPLES
    scripts/00_init_vm.sh myvm --ram 4096 --vcpus 4
    scripts/00_init_vm.sh myvm -i
EOF
)
show_help_if_requested "$USAGE" "$@"

require_env
check_bin virt-install
check_bin qemu-img
check_bin cloud-localds
check_bin envsubst
check_bin yq

VMNAME="${1:?Missing <vmname>. Run 'scripts/00_init_vm.sh --help' for usage.}"
shift

INTERACTIVE=0
RAM="$DEFAULT_RAM_MB"
VCPUS="$DEFAULT_VCPUS"
DISK="$DEFAULT_DISK_GB"
IMAGE="$DEFAULT_CLOUD_IMG"
OS_VARIANT="$DEFAULT_OS_VARIANT"
AUTOSTART="${DEFAULT_AUTOSTART:-false}"

RAM_SET=0
VCPUS_SET=0
DISK_SET=0
IMAGE_SET=0
OS_VARIANT_SET=0
AUTOSTART_SET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interactive) INTERACTIVE=1; shift ;;
        --ram)           RAM="$2"; RAM_SET=1; shift 2 ;;
        --vcpus)         VCPUS="$2"; VCPUS_SET=1; shift 2 ;;
        --disk)          DISK="$2"; DISK_SET=1; shift 2 ;;
        --image)         IMAGE="$2"; IMAGE_SET=1; shift 2 ;;
        --os-variant)    OS_VARIANT="$2"; OS_VARIANT_SET=1; shift 2 ;;
        --autostart)     AUTOSTART="true"; AUTOSTART_SET=1; shift ;;
        --no-autostart)  AUTOSTART="false"; AUTOSTART_SET=1; shift ;;
        -h|--help)       printf '%s\n' "$USAGE"; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

validate_vmname "$VMNAME"

[[ -d "$STORAGE_POOL_DISKS" ]] || die "STORAGE_POOL_DISKS ($STORAGE_POOL_DISKS) does not exist -- run the SETUP.md bootstrap first."
[[ -d "$STORAGE_POOL_CLOUD_INIT_ISOS" ]] || die "STORAGE_POOL_CLOUD_INIT_ISOS ($STORAGE_POOL_CLOUD_INIT_ISOS) does not exist -- run the SETUP.md bootstrap first."

if vm_exists "$VMNAME" || [[ -f "$(state_path "$VMNAME")" ]]; then
    die "VM '$VMNAME' already exists. Run scripts/04_destroy_vm.sh $VMNAME first if you want to recreate it."
fi

if [[ "$INTERACTIVE" == "1" ]]; then
    log "Interactive mode -- press Enter to accept the default shown in [brackets]."
    [[ "$RAM_SET" == "1" ]]        || RAM="$(prompt_int "RAM (MB)" "$RAM")"
    [[ "$VCPUS_SET" == "1" ]]      || VCPUS="$(prompt_int "vCPUs" "$VCPUS")"
    [[ "$DISK_SET" == "1" ]]       || DISK="$(prompt_int "Disk (GB)" "$DISK")"
    [[ "$IMAGE_SET" == "1" ]]      || IMAGE="$(prompt_default "Base image" "$IMAGE")"
    [[ "$OS_VARIANT_SET" == "1" ]] || OS_VARIANT="$(prompt_default "OS variant" "$OS_VARIANT")"
    [[ "$AUTOSTART_SET" == "1" ]]  || AUTOSTART="$(prompt_bool "Enable libvirt autostart (start '$VMNAME' automatically whenever libvirtd starts)?" "$AUTOSTART")"
fi

if [[ "$AUTOSTART" != "true" && "$AUTOSTART" != "false" ]]; then
    die "Invalid autostart value: '$AUTOSTART' (expected true or false -- check DEFAULT_AUTOSTART)"
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
    --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
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
