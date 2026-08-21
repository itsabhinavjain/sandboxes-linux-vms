#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/host_common.sh"

# -----------------------------------------------------------------------------
# Required environment variables
# -----------------------------------------------------------------------------

required_vars=(
    LIBVIRT_HOME
    STORAGE_POOL_IMAGES
    STORAGE_POOL_ISOS
    STORAGE_POOL_DISKS
    STORAGE_POOL_SNAPSHOTS
    STORAGE_POOL_CLOUD_INIT_ISOS
)

missing_vars=()

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing_vars+=("$var")
    fi
done

if (( ${#missing_vars[@]} > 0 )); then
    echo "ERROR: Required environment variables are not defined:"
    printf '  %s\n' "${missing_vars[@]}"
    echo
    echo "Source your environment first, for example:"
    echo "  source /etc/profile.d/sandbox.sh"
    exit 1
fi

# -----------------------------------------------------------------------------
# Basic validation
# -----------------------------------------------------------------------------

if ! command -v virsh >/dev/null 2>&1; then
    echo "ERROR: virsh is not installed or not in PATH."
    exit 1
fi

if ! sudo virsh uri >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to libvirt."
    exit 1
fi

# -----------------------------------------------------------------------------
# Show current libvirt qemu user/group
# -----------------------------------------------------------------------------

echo "==> libvirt qemu configuration"

grep -E '^(user|group)' /etc/libvirt/qemu.conf || true

echo

# -----------------------------------------------------------------------------
# Create storage directories
# -----------------------------------------------------------------------------

echo "==> Creating storage directories"

mkdir -p \
    "$STORAGE_POOL_IMAGES" \
    "$STORAGE_POOL_ISOS" \
    "$STORAGE_POOL_DISKS" \
    "$STORAGE_POOL_SNAPSHOTS" \
    "$STORAGE_POOL_CLOUD_INIT_ISOS"

# -----------------------------------------------------------------------------
# Set permissions
# -----------------------------------------------------------------------------

echo "==> Setting ownership and permissions"

sudo chown -R libvirt-qemu:kvm "$LIBVIRT_HOME"
sudo chmod -R 775 "$LIBVIRT_HOME"

# Files/directories created underneath the pools inherit the kvm group.
sudo find "$LIBVIRT_HOME" -type d -exec chmod g+s {} \;

echo

# -----------------------------------------------------------------------------
# pool_is_active() / ensure_pool() come from lib/host_common.sh, shared with
# 84_host_change_libvirt_storage_pools.sh.
# -----------------------------------------------------------------------------
# Configure pools
# -----------------------------------------------------------------------------

ensure_pool "default"      "$STORAGE_POOL_IMAGES"
ensure_pool "iso-pool"    "$STORAGE_POOL_ISOS"
ensure_pool "disk-pool"   "$STORAGE_POOL_DISKS"
ensure_pool "snapshot-pool" "$STORAGE_POOL_SNAPSHOTS"
ensure_pool "cloudinit-pool" "$STORAGE_POOL_CLOUD_INIT_ISOS"

# -----------------------------------------------------------------------------
# Final state
# -----------------------------------------------------------------------------

echo "============================================================"
echo "Libvirt storage pools"
echo "============================================================"

sudo virsh pool-list --all

echo
echo "============================================================"
echo "Pool details"
echo "============================================================"

for pool in \
    default \
    iso-pool \
    disk-pool \
    snapshot-pool \
    cloudinit-pool
do
    echo
    echo "### $pool"
    sudo virsh pool-info "$pool"
done

echo
echo "============================================================"
echo "Pool XML"
echo "============================================================"

for pool in \
    default \
    iso-pool \
    disk-pool \
    snapshot-pool \
    cloudinit-pool
do
    echo
    echo "### $pool"
    sudo virsh pool-dumpxml "$pool"
done

echo
echo "Done."