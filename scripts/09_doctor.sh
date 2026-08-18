#!/usr/bin/env bash
# Usage: scripts/09_doctor.sh
#
# Host-level diagnostics: KVM support, libvirtd status, required binaries,
# storage pool definitions/state, storage directory setgid bits, and virsh
# access without sudo. Prints [PASS]/[FAIL] per check; exits 1 if any check
# failed, 0 if everything passed. Also prints an informational host-details
# section (OS, kernel, CPUs, memory, disk space, listening ports) that does
# not affect pass/fail or the exit code.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    09_doctor.sh -- host-level diagnostics for the sandbox toolkit

USAGE
    scripts/09_doctor.sh

    No arguments. Checks KVM support, libvirtd status, required binaries,
    the five storage pools, and setgid bits on their directories. Prints
    [PASS]/[FAIL] per check plus informational host details. Exits 1 if any
    check failed, 0 otherwise.

OPTIONS
    -h, --help  Show this help and exit
EOF
)
show_help_if_requested "$USAGE" "$@"
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

# 2. libvirtd active (or socket-activatable -- libvirtd.service is commonly
# socket-activated, so it can be legitimately inactive until something
# connects to it; treat the socket unit as equally acceptable)
if systemctl is-active --quiet libvirtd || systemctl is-active --quiet libvirtd.socket; then
    pass "libvirtd is active (or socket-activatable)"
else
    fail "libvirtd is active (or socket-activatable)"
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
for pool in default iso-pool disk-pool snapshot-pool cloudinit-pool; do
    POOL_INFO="$("${VIRSH[@]}" pool-info "$pool" 2>/dev/null || true)"
    if grep -q "State:.*running" <<< "$POOL_INFO"; then
        pass "storage pool '$pool' is defined and running"
    else
        fail "storage pool '$pool' is defined and running"
    fi
done

# 5. Storage directories exist and are setgid
for dir in "$STORAGE_POOL_IMAGES" "$STORAGE_POOL_ISOS" "$STORAGE_POOL_DISKS" "$STORAGE_POOL_SNAPSHOTS" "$STORAGE_POOL_CLOUD_INIT_ISOS"; do
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
else
    log "$FAILURES check(s) failed."
fi

# --- Host details (informational only -- doesn't affect FAILURES/exit code) ---

echo ""
log "Host details"

if [[ -f /etc/os-release ]]; then
    OS_PRETTY="$(. /etc/os-release && echo "$PRETTY_NAME")"
else
    OS_PRETTY="unknown"
fi
printf "OS:      %s (kernel %s)\n" "$OS_PRETTY" "$(uname -r)"

printf "CPUs:    %s\n" "$(nproc)"

echo "Memory:"
free -h | sed 's/^/  /'

echo "Disk space (under \$LIBVIRT_HOME: $LIBVIRT_HOME):"
df -h "$LIBVIRT_HOME" | sed 's/^/  /'

echo "Listening ports (TCP/UDP):"
if command -v ss >/dev/null 2>&1; then
    ss -tuln | sed 's/^/  /'
else
    echo "  ss not available -- skipping"
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
    exit 0
else
    exit 1
fi
