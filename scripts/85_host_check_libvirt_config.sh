#!/usr/bin/env bash
set -uo pipefail

echo "Printing the environment variables to verify that they are set correctly:"
echo "LIBVIRT_HOME=${LIBVIRT_HOME:-<not set>}"
echo "STORAGE_POOL_IMAGES=${STORAGE_POOL_IMAGES:-<not set>}"
echo "STORAGE_POOL_ISOS=${STORAGE_POOL_ISOS:-<not set>}"
echo "STORAGE_POOL_DISKS=${STORAGE_POOL_DISKS:-<not set>}"
echo "STORAGE_POOL_SNAPSHOTS=${STORAGE_POOL_SNAPSHOTS:-<not set>}"
echo "STORAGE_POOL_CLOUD_INIT_ISOS=${STORAGE_POOL_CLOUD_INIT_ISOS:-<not set>}"

echo
echo "Printing version information:"
virt-install --version 2>/dev/null || echo "virt-install: not installed"
cloud-init --version 2>/dev/null || echo "cloud-init: not installed"
qemu-img --version 2>/dev/null || echo "qemu-img: not installed"
yq --version 2>/dev/null || echo "yq: not installed"

echo
echo "Printing libvirt configuration (run without sudo -- confirms the"
echo "libvirt/kvm group membership from 81_host_setup_initial_dependencies.sh"
echo "has taken effect; a password prompt or 'permission denied' here means"
echo "it hasn't, or this shell predates the group change):"
virsh -c qemu:///system list --all
virsh -c qemu:///system pool-list --all
virsh -c qemu:///system net-list --all
