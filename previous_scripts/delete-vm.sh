#!/bin/bash
set -e

# Usage: ./delete-vm.sh <vm-name> [--force]
VMNAME="${1:?Usage: $0 <vm-name> [--force]}"
FORCE="${2:-}"

IMAGES_DIR="/mnt/extreme_ssd/libvirt/images"

BASE_IMAGE_NAME="noble-server-cloudimg-amd64"

DISK_PATH="$IMAGES_DIR/$BASE_IMAGE_NAME-${VMNAME}.qcow2"
SEED_PATH="$IMAGES_DIR/${VMNAME}-seed.iso"

# Confirmation prompt unless --force
if [ "$FORCE" != "--force" ]; then
    echo "This will permanently delete VM '$VMNAME':"
    echo "  - libvirt definition"
    echo "  - $DISK_PATH"
    echo "  - $SEED_PATH"
    echo ""
    read -p "Continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

echo ""
echo "==> Deleting VM: $VMNAME"

# 1. Force-stop the VM if running
if sudo virsh list --name | grep -qx "$VMNAME"; then
    echo "==> Stopping running VM..."
    sudo virsh destroy "$VMNAME" || true
fi

# 2. Undefine and remove disks via libvirt
if sudo virsh list --all --name | grep -qx "$VMNAME"; then
    echo "==> Removing libvirt definition and disks..."
    sudo virsh undefine "$VMNAME" --remove-all-storage --nvram 2>/dev/null \
        || sudo virsh undefine "$VMNAME" --remove-all-storage
fi

# 3. Belt-and-suspenders: remove disk files if libvirt missed them
[ -f "$DISK_PATH" ] && { echo "==> Removing leftover disk file..."; sudo rm -f "$DISK_PATH"; }
[ -f "$SEED_PATH" ] && { echo "==> Removing leftover seed ISO..."; sudo rm -f "$SEED_PATH"; }


echo ""
echo "==> VM '$VMNAME' fully deleted."
echo ""
echo "==> NOTE: On your MacBook, also run:"
echo "    ssh-keygen -R ${VMNAME}.${TAILSCALE_TAILNET:-<your-tailnet>.ts.net}"

