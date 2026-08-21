#!/usr/bin/env bash

set -u

section() {
  echo
  echo "========== $1 =========="
}

section "SYSTEM"
hostnamectl 2>/dev/null || true
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"

section "PHYSICAL / VIRTUAL"
echo "Virtualization: $(systemd-detect-virt 2>/dev/null || echo none)"
echo "CPU virtualization flags: $(grep -m1 '^flags' /proc/cpuinfo | grep -oE 'vmx|svm' | head -1 || echo none)"
echo "KVM device: $([ -e /dev/kvm ] && echo YES || echo NO)"

section "CPU"
lscpu | grep -E \
  '^(Architecture|CPU\(s\)|On-line CPU|Thread|Core|Socket|NUMA|Model name|CPU MHz|Virtualization):'

section "MEMORY"
free -h
echo
grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree|HugePages_Total|HugePages_Free|Hugepagesize):' /proc/meminfo

section "DISKS"
lsblk -e 7 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,TRAN,ROTA

section "DISK USAGE"
df -hT

section "DISK DETAILS"
for dev in /sys/block/*; do
  name=$(basename "$dev")
  [[ "$name" == loop* || "$name" == ram* || "$name" == sr* ]] && continue

  echo
  echo "/dev/$name"
  echo "  Size:        $(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null)"
  echo "  Model:       $(xargs < "$dev/device/model" 2>/dev/null || echo unknown)"
  echo "  Transport:   $(lsblk -dn -o TRAN "/dev/$name" 2>/dev/null)"
  echo "  Rotational:  $(cat "$dev/queue/rotational" 2>/dev/null || echo unknown)"
  echo "  Scheduler:   $(cat "$dev/queue/scheduler" 2>/dev/null || echo unknown)"
done

section "MOUNT POINTS"
findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE% 2>/dev/null

section "NUMA"
if command -v numactl >/dev/null; then
  numactl --hardware
else
  echo "numactl not installed"
fi

section "IOMMU"
groups=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
echo "IOMMU groups: $groups"
echo "Status: $([ "$groups" -gt 0 ] && echo available || echo not detected)"

section "NETWORK"
ip -br addr 2>/dev/null

section "SUMMARY"
echo "CPUs:        $(nproc)"
echo "RAM:         $(free -h | awk '/^Mem:/ {print $2}')"
echo "KVM:         $([ -e /dev/kvm ] && echo available || echo unavailable)"
echo "Virtualized: $(systemd-detect-virt 2>/dev/null || echo no)"
echo "Disks:"
lsblk -dn -e 7 -o NAME,SIZE,TRAN,ROTA,TYPE 2>/dev/null | awk '$5=="disk"'
