#!/usr/bin/env bash
# Usage: scripts/09_doctor.sh
#
# Host-level diagnostics: KVM support, libvirtd status, required binaries,
# storage pool definitions/state, storage directory setgid bits, and virsh
# access without sudo. Prints [PASS]/[FAIL] per check; exits 1 if any check
# failed, 0 if everything passed.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

FAILURES=0

pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

# 1. KVM support
KVM_EXT_COUNT="$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)"
if [[ "${KVM_EXT_COUNT:-0}" -gt 0 ]]; then
    pass "CPU has virtualization extensions (vmx/svm)"
else
    fail "CPU has virtualization extensions (vmx/svm)"
fi

if command -v kvm-ok >/dev/null 2>&1; then
    if kvm-ok >/dev/null 2>&1; then
        pass "kvm-ok reports KVM acceleration available"
    else
        fail "kvm-ok reports KVM acceleration available"
    fi
else
    log "kvm-ok not installed -- skipping (optional check)"
fi

# 2. libvirtd active
if systemctl is-active --quiet libvirtd; then
    pass "libvirtd is active"
else
    fail "libvirtd is active"
fi

# 3. Required binaries present
for bin in virt-install cloud-localds qemu-img yq envsubst; do
    if command -v "$bin" >/dev/null 2>&1; then
        pass "required binary present: $bin"
    else
        fail "required binary present: $bin"
    fi
done

# 4. Storage pools defined and running
# (capture output before grepping -- see the NOTE in common.sh's vm_exists
# for why piping straight into `grep -q` here would be flaky under pipefail)
for pool in default iso-pool disk-pool snapshot-pool; do
    POOL_INFO="$("${VIRSH[@]}" pool-info "$pool" 2>/dev/null || true)"
    if grep -q "State:.*running" <<< "$POOL_INFO"; then
        pass "storage pool '$pool' is defined and running"
    else
        fail "storage pool '$pool' is defined and running"
    fi
done

# 5. Storage directories exist and are setgid
for dir in "$STORAGE_POOL_IMAGES" "$STORAGE_POOL_ISOS" "$STORAGE_POOL_DISKS" "$STORAGE_POOL_SNAPSHOTS"; do
    if [[ -d "$dir" ]]; then
        PERMS="$(stat -c '%A' "$dir")"
        GROUP_EXEC_BIT="${PERMS:6:1}"
        if [[ "$GROUP_EXEC_BIT" == "s" || "$GROUP_EXEC_BIT" == "S" ]]; then
            pass "directory exists and is setgid: $dir"
        else
            fail "directory exists and is setgid: $dir (perms: $PERMS)"
        fi
    else
        fail "directory exists and is setgid: $dir (does not exist)"
    fi
done

# 6. virsh works without sudo
if "${VIRSH[@]}" list --all >/dev/null 2>&1; then
    pass "virsh -c qemu:///system list --all succeeds without sudo"
else
    fail "virsh -c qemu:///system list --all succeeds without sudo"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
    log "All checks passed."
    exit 0
else
    log "$FAILURES check(s) failed."
    exit 1
fi
