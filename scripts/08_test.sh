#!/usr/bin/env bash
# Usage: scripts/08_test.sh
#
# End-to-end smoke test of the sandbox lifecycle tooling against a real
# libvirt host. Runs 09_doctor.sh first (aborts immediately if the host
# isn't correctly configured), then exercises the full single-VM lifecycle
# -- init (both the automated and interactive paths) -> start -> wait for
# cloud-init to actually finish provisioning -> status -> reboot -> stop ->
# fleet views -> destroy -- against ephemeral test VMs it creates itself.
# Always destroys every test VM it created, even on failure, so nothing is
# left behind on the host. Prints [PASS]/[FAIL] per step; exits 1 if any
# check failed, 0 if everything passed.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

check_bin ssh

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
RUN_ID="$$"
VM_AUTO="sandbox-test-auto-${RUN_ID}"
VM_INTERACTIVE="sandbox-test-interactive-${RUN_ID}"

# The user baked into setup_config/user-data.tmpl -- see CLAUDE.md gotcha
# ("hardcodes user abhinav ... intentionally not parameterized").
VM_SSH_USER="abhinav"

# Host key checking is off deliberately: these are freshly-created VMs on
# the local NAT network whose IPs get reused across test runs, so a stored
# host key from a previous test VM would otherwise cause a false-positive
# mismatch. /dev/null as the known_hosts file means nothing is ever written
# to disk, so there's no cleanup needed either.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)

IP_WAIT_TIMEOUT="${IP_WAIT_TIMEOUT:-90}"
SSH_WAIT_TIMEOUT="${SSH_WAIT_TIMEOUT:-60}"
CLOUDINIT_WAIT_TIMEOUT="${CLOUDINIT_WAIT_TIMEOUT:-900}"

CREATED_VMS=()
FAILURES=0
STEP_NUM=0

step() {
    STEP_NUM=$((STEP_NUM + 1))
    log "Step $STEP_NUM: $*"
}

pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
    local rc=$?
    echo ""
    log "Cleaning up test VMs..."
    local vm
    for vm in "${CREATED_VMS[@]}"; do
        if vm_exists "$vm" || [[ -f "$(state_path "$vm")" ]]; then
            log "Destroying test VM '$vm'..."
            "$SCRIPT_DIR/04_destroy_vm.sh" "$vm" --force \
                || log "WARNING: failed to destroy '$vm' -- clean up manually."
        fi
    done
    exit "$rc"
}
trap cleanup EXIT

# wait_for_state <vmname> <expected virsh domstate> [timeout-seconds]
wait_for_state() {
    local vmname="$1" expected="$2" timeout="${3:-60}" waited=0 state
    while true; do
        state="$("${VIRSH[@]}" domstate "$vmname" 2>/dev/null || echo "unknown")"
        [[ "$state" == "$expected" ]] && return 0
        waited=$((waited + 5))
        [[ "$waited" -ge "$timeout" ]] && return 1
        sleep 5
    done
}

# get_vm_ip <vmname> [timeout-seconds] -- polls the default NAT network's
# dnsmasq lease file (via `virsh domifaddr --source lease`) until the VM has
# an IPv4 lease, echoes it, and returns 0. Deliberately not
# `--source agent`: that needs qemu-guest-agent, which isn't in
# setup_config/user-data.tmpl's package list.
get_vm_ip() {
    local vmname="$1" timeout="${2:-90}" waited=0 ip
    while true; do
        ip="$("${VIRSH[@]}" domifaddr "$vmname" --source lease 2>/dev/null \
            | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1)"
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        waited=$((waited + 5))
        [[ "$waited" -ge "$timeout" ]] && return 1
        sleep 5
    done
}

# wait_for_ssh <ip> [timeout-seconds] -- polls until sshd on the VM accepts
# a connection (a DHCP lease can show up slightly before sshd is ready).
wait_for_ssh() {
    local ip="$1" timeout="${2:-60}" waited=0
    while true; do
        ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${ip}" true 2>/dev/null && return 0
        waited=$((waited + 5))
        [[ "$waited" -ge "$timeout" ]] && return 1
        sleep 5
    done
}

# wait_for_cloudinit <vmname> -- waits for a DHCP lease, then SSH, then runs
# `cloud-init status --wait` on the guest so this actually blocks until
# provisioning (package installs, docker, etc. in user-data.tmpl) is done
# instead of racing it, and prints the cloud-init status plus a log tail so
# a failed/degraded run is visible. Retries once if the SSH connection drops
# mid-wait, since user-data.tmpl's `package_reboot_if_required: true` can
# reboot the guest partway through provisioning. Returns non-zero if the
# lease/SSH/cloud-init wait didn't succeed.
wait_for_cloudinit() {
    local vmname="$1" attempt ip cloudinit_out cloudinit_rc
    for attempt in 1 2; do
        log "Waiting for '$vmname' to get a DHCP lease (attempt $attempt)..."
        if ! ip="$(get_vm_ip "$vmname" "$IP_WAIT_TIMEOUT")"; then
            log "WARNING: '$vmname' did not get a DHCP lease within ${IP_WAIT_TIMEOUT}s."
            return 1
        fi
        log "'$vmname' is at $ip -- waiting for SSH..."
        if ! wait_for_ssh "$ip" "$SSH_WAIT_TIMEOUT"; then
            log "WARNING: could not SSH to '$vmname' ($ip) within ${SSH_WAIT_TIMEOUT}s."
            return 1
        fi
        log "Waiting for cloud-init to finish on '$vmname' (up to ${CLOUDINIT_WAIT_TIMEOUT}s)..."
        cloudinit_out="$(timeout "$CLOUDINIT_WAIT_TIMEOUT" ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${ip}" \
            'cloud-init status --wait --long' 2>&1)"
        cloudinit_rc=$?
        if [[ "$cloudinit_rc" == "255" && "$attempt" == "1" ]]; then
            log "SSH connection dropped (likely a package_reboot_if_required reboot mid-provisioning) -- retrying..."
            sleep 10
            continue
        fi
        break
    done
    echo "$cloudinit_out" | sed 's/^/  /'
    log "cloud-init log tail (/var/log/cloud-init-output.log) on '$vmname':"
    ssh "${SSH_OPTS[@]}" "${VM_SSH_USER}@${ip}" 'tail -n 40 /var/log/cloud-init-output.log' 2>/dev/null | sed 's/^/  /'
    return "$cloudinit_rc"
}

# --- Step 1: host diagnostics ---
step "Host diagnostics (09_doctor.sh)"
if "$SCRIPT_DIR/09_doctor.sh"; then
    pass "09_doctor.sh"
else
    fail "09_doctor.sh -- host is not correctly configured, aborting test"
    exit 1
fi

# --- Step 2: init via the automated path ---
step "Init '$VM_AUTO' (00_init_vm-automated.sh)"
AUTO_DEFINED=0
if "$SCRIPT_DIR/00_init_vm-automated.sh" "$VM_AUTO" --no-autostart; then
    CREATED_VMS+=("$VM_AUTO")
    AUTO_DEFINED=1
    pass "init '$VM_AUTO'"
else
    fail "init '$VM_AUTO'"
fi

# --- Step 3: start ---
AUTO_RUNNING=0
if [[ "$AUTO_DEFINED" == "1" ]]; then
    step "Start '$VM_AUTO' (01_start_vm.sh)"
    if "$SCRIPT_DIR/01_start_vm.sh" "$VM_AUTO" && wait_for_state "$VM_AUTO" "running" 30; then
        AUTO_RUNNING=1
        pass "start '$VM_AUTO'"
    else
        fail "start '$VM_AUTO'"
    fi
fi

# --- Step 4: wait for cloud-init to actually finish provisioning ---
if [[ "$AUTO_RUNNING" == "1" ]]; then
    step "Wait for cloud-init provisioning on '$VM_AUTO'"
    if wait_for_cloudinit "$VM_AUTO"; then
        pass "cloud-init provisioning on '$VM_AUTO'"
    else
        fail "cloud-init provisioning on '$VM_AUTO'"
    fi
fi

# --- Step 5: status ---
if [[ "$AUTO_DEFINED" == "1" ]]; then
    step "Status '$VM_AUTO' (05_status_vm.sh)"
    STATUS_OUT="$("$SCRIPT_DIR/05_status_vm.sh" "$VM_AUTO" 2>&1)" && STATUS_RC=0 || STATUS_RC=1
    if [[ "$STATUS_RC" == "0" ]] && grep -q "$VM_AUTO" <<< "$STATUS_OUT"; then
        pass "status '$VM_AUTO'"
    else
        fail "status '$VM_AUTO'"
    fi
fi

# --- Step 6: reboot (only while running) ---
if [[ "$AUTO_RUNNING" == "1" ]]; then
    step "Reboot '$VM_AUTO' (03_reboot_vm.sh)"
    if "$SCRIPT_DIR/03_reboot_vm.sh" "$VM_AUTO"; then
        pass "reboot '$VM_AUTO'"
    else
        fail "reboot '$VM_AUTO'"
    fi
fi

# --- Step 7: graceful stop, falling back to --force if it doesn't shut off in time ---
if [[ "$AUTO_RUNNING" == "1" ]]; then
    step "Graceful stop '$VM_AUTO' (02_stop_vm.sh)"
    if "$SCRIPT_DIR/02_stop_vm.sh" "$VM_AUTO" && wait_for_state "$VM_AUTO" "shut off" 90; then
        pass "graceful stop '$VM_AUTO'"
    else
        log "Graceful shutdown did not complete in time -- forcing."
        "$SCRIPT_DIR/02_stop_vm.sh" "$VM_AUTO" --force || true
        fail "graceful stop '$VM_AUTO' (had to force)"
    fi
fi

# --- Step 8: init via the interactive path (blank input = accept every default) ---
step "Init '$VM_INTERACTIVE' (00_init_vm-interactive.sh, defaults accepted)"
INTERACTIVE_DEFINED=0
if printf '%s\n\n\n\n\n\n\n' "$VM_INTERACTIVE" | "$SCRIPT_DIR/00_init_vm-interactive.sh"; then
    CREATED_VMS+=("$VM_INTERACTIVE")
    INTERACTIVE_DEFINED=1
    pass "init '$VM_INTERACTIVE' (interactive)"
else
    fail "init '$VM_INTERACTIVE' (interactive)"
fi

# --- Step 9: start the interactively-defined VM ---
INTERACTIVE_RUNNING=0
if [[ "$INTERACTIVE_DEFINED" == "1" ]]; then
    step "Start '$VM_INTERACTIVE' (01_start_vm.sh)"
    if "$SCRIPT_DIR/01_start_vm.sh" "$VM_INTERACTIVE" && wait_for_state "$VM_INTERACTIVE" "running" 30; then
        INTERACTIVE_RUNNING=1
        pass "start '$VM_INTERACTIVE'"
    else
        fail "start '$VM_INTERACTIVE'"
    fi
fi

# --- Step 10: wait for cloud-init to actually finish provisioning ---
if [[ "$INTERACTIVE_RUNNING" == "1" ]]; then
    step "Wait for cloud-init provisioning on '$VM_INTERACTIVE'"
    if wait_for_cloudinit "$VM_INTERACTIVE"; then
        pass "cloud-init provisioning on '$VM_INTERACTIVE'"
    else
        fail "cloud-init provisioning on '$VM_INTERACTIVE'"
    fi
fi

# --- Step 11: fleet views list both test VMs ---
step "Fleet views (50_list_vms.sh / 51_info_vms.sh)"
LIST_OUT="$("$SCRIPT_DIR/50_list_vms.sh" 2>/dev/null || true)"
INFO_OUT="$("$SCRIPT_DIR/51_info_vms.sh" 2>/dev/null || true)"
FLEET_OK=1
[[ "$AUTO_DEFINED" == "1" ]] && { grep -q "$VM_AUTO" <<< "$LIST_OUT" || FLEET_OK=0; grep -q "$VM_AUTO" <<< "$INFO_OUT" || FLEET_OK=0; }
[[ "$INTERACTIVE_DEFINED" == "1" ]] && { grep -q "$VM_INTERACTIVE" <<< "$LIST_OUT" || FLEET_OK=0; grep -q "$VM_INTERACTIVE" <<< "$INFO_OUT" || FLEET_OK=0; }
if [[ "$FLEET_OK" == "1" ]]; then
    pass "fleet views list the test VM(s)"
else
    fail "fleet views list the test VM(s)"
fi

# --- Step 12: destroy every test VM ---
step "Destroy test VMs (04_destroy_vm.sh --force)"
for vm in "$VM_AUTO" "$VM_INTERACTIVE"; do
    if vm_exists "$vm" || [[ -f "$(state_path "$vm")" ]]; then
        if "$SCRIPT_DIR/04_destroy_vm.sh" "$vm" --force; then
            pass "destroy '$vm'"
        else
            fail "destroy '$vm'"
        fi
    fi
done

# --- Step 13: verify no leftovers ---
step "Verify no leftover libvirt domains or files"
LEFTOVER=0
for vm in "$VM_AUTO" "$VM_INTERACTIVE"; do
    if vm_exists "$vm" || [[ -f "$(state_path "$vm")" || -f "$(disk_path "$vm")" || -f "$(seed_path "$vm")" ]]; then
        LEFTOVER=1
    fi
done
if [[ "$LEFTOVER" == "0" ]]; then
    pass "no leftover files/domains for test VMs"
    CREATED_VMS=()
else
    fail "leftover files/domains found for test VMs"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    log "All checks passed ($STEP_NUM steps)."
    exit 0
else
    log "$FAILURES check(s) failed."
    exit 1
fi
