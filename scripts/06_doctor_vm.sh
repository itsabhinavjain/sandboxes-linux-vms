#!/usr/bin/env bash
# Usage: ./scripts/06_doctor_vm.sh <vmname>
#
# Per-VM diagnostics: cross-checks the libvirt domain and on-disk files
# against <vmname>.state.yaml (disk/seed/base-image presence, RAM/vCPU/
# autostart/disk-size drift), and, if the VM is running and reachable over
# SSH, cross-checks the guest's actual Tailscale/UFW/Docker/cloud-init state
# against what state.yaml recorded from 11_configure_vm.sh. Prints
# [PASS]/[FAIL] per check (or a log note for guest checks skipped because
# the VM isn't running/reachable); exits 1 if any check failed, 0 otherwise.
#
# For host-level diagnostics (KVM, libvirtd, storage pools, required
# binaries), see 09_doctor_host.sh instead.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/configure_steps.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/resize_steps.sh"

USAGE=$(cat <<EOF
NAME
    06_doctor_vm.sh -- per-VM diagnostics for the sandbox toolkit

USAGE
    ./scripts/06_doctor_vm.sh <vmname>

    Checks the libvirt domain, disk/seed/base-image files, and RAM/vCPU/
    autostart/disk-size against <vmname>.state.yaml. If the VM is running
    and reachable over SSH, also checks cloud-init completion and the
    guest's actual Tailscale/UFW/Docker state against what state.yaml
    recorded from 11_configure_vm.sh. Prints [PASS]/[FAIL] per check; exits
    1 if any check failed, 0 otherwise.

    For host-level diagnostics (not specific to any one VM), see
    09_doctor_host.sh instead.

REQUIRED
    <vmname>    VM name

OPTIONS
    -h, --help  Show this help and exit
EOF
)
show_help_if_requested "$USAGE" "$@"
require_env
check_bin ssh
check_bin qemu-img

VMNAME="${1:?Missing <vmname>. Run './scripts/06_doctor_vm.sh --help' for usage.}"
validate_vmname "$VMNAME"

FAILURES=0

pass() { printf "[PASS] %s\n" "$1"; }
fail() { printf "[FAIL] %s\n" "$1"; FAILURES=$((FAILURES + 1)); }

STATE_PATH="$(state_path "$VMNAME")"
DISK_PATH="$(disk_path "$VMNAME")"
SEED_PATH="$(seed_path "$VMNAME")"

HAVE_DOMAIN=0
HAVE_STATE=0
vm_exists "$VMNAME" && HAVE_DOMAIN=1
[[ -f "$STATE_PATH" ]] && HAVE_STATE=1

if [[ "$HAVE_DOMAIN" == "0" && "$HAVE_STATE" == "0" ]]; then
    die "VM '$VMNAME' not found (no libvirt domain, no state file)."
fi

echo "=== $VMNAME: libvirt / on-disk checks ==="

if [[ "$HAVE_STATE" == "1" ]]; then
    pass "state file exists: $STATE_PATH"
else
    fail "state file exists: $STATE_PATH (not found -- not managed by this toolkit, or corrupted init)"
fi

if [[ "$HAVE_DOMAIN" == "1" ]]; then
    pass "libvirt domain defined: $VMNAME"
else
    fail "libvirt domain defined: $VMNAME"
fi

if [[ -f "$DISK_PATH" ]]; then
    pass "disk file exists: $DISK_PATH"
else
    fail "disk file exists: $DISK_PATH"
fi

if [[ -f "$SEED_PATH" ]]; then
    pass "cloud-init seed ISO exists: $SEED_PATH"
else
    fail "cloud-init seed ISO exists: $SEED_PATH"
fi

# Everything below this point compares the domain/disk against the *expected*
# shape recorded in state.yaml -- can't be checked without it.
if [[ "$HAVE_STATE" == "1" ]]; then
    STATE_BASE_IMAGE="$(state_get "$VMNAME" .base_image)"
    BASE_IMAGE_PATH="$(base_image_path "$STATE_BASE_IMAGE")"
    if [[ -f "$BASE_IMAGE_PATH" ]]; then
        pass "base image referenced in state.yaml exists: $BASE_IMAGE_PATH"
    else
        fail "base image referenced in state.yaml exists: $BASE_IMAGE_PATH (not found)"
    fi

    if [[ -f "$DISK_PATH" ]]; then
        STATE_DISK_GB="$(state_get "$VMNAME" .disk_gb)"
        ACTUAL_DISK_GB="$(resize_disk_current_gb "$VMNAME")"
        if [[ "$ACTUAL_DISK_GB" == "$STATE_DISK_GB" ]]; then
            pass "disk size matches state.yaml (${ACTUAL_DISK_GB}G)"
        else
            fail "disk size matches state.yaml (actual ${ACTUAL_DISK_GB}G, state.yaml says ${STATE_DISK_GB}G)"
        fi
    fi

    if [[ "$HAVE_DOMAIN" == "1" ]]; then
        DOM_INFO="$("${VIRSH[@]}" dominfo "$VMNAME" 2>/dev/null || true)"
        DOM_VCPUS="$(awk -F': +' '/^CPU\(s\):/{print $2}' <<< "$DOM_INFO" | tr -d '[:space:]')"
        DOM_MAXMEM_KIB="$(awk -F': +' '/^Max memory:/{print $2}' <<< "$DOM_INFO" | awk '{print $1}')"
        DOM_AUTOSTART="$(awk -F': +' '/^Autostart:/{print $2}' <<< "$DOM_INFO" | tr -d '[:space:]')"

        STATE_VCPUS="$(state_get "$VMNAME" .vcpus)"
        STATE_RAM_MB="$(state_get "$VMNAME" .ram_mb)"
        STATE_AUTOSTART="$(state_get "$VMNAME" .autostart)"
        EXPECTED_DOM_AUTOSTART="disable"; [[ "$STATE_AUTOSTART" == "true" ]] && EXPECTED_DOM_AUTOSTART="enable"

        if [[ -n "$DOM_VCPUS" && "$DOM_VCPUS" == "$STATE_VCPUS" ]]; then
            pass "domain vCPUs match state.yaml ($DOM_VCPUS)"
        else
            fail "domain vCPUs match state.yaml (domain: ${DOM_VCPUS:-unknown}, state.yaml: $STATE_VCPUS)"
        fi

        if [[ -n "$DOM_MAXMEM_KIB" && $((DOM_MAXMEM_KIB / 1024)) == "$STATE_RAM_MB" ]]; then
            pass "domain RAM matches state.yaml (${STATE_RAM_MB}MB)"
        else
            fail "domain RAM matches state.yaml (domain: $((${DOM_MAXMEM_KIB:-0} / 1024))MB, state.yaml: ${STATE_RAM_MB}MB)"
        fi

        if [[ "$DOM_AUTOSTART" == "$EXPECTED_DOM_AUTOSTART" ]]; then
            pass "domain autostart matches state.yaml ($DOM_AUTOSTART)"
        else
            fail "domain autostart matches state.yaml (domain: ${DOM_AUTOSTART:-unknown}, state.yaml: $STATE_AUTOSTART)"
        fi
    fi
else
    log "Skipping disk-size/RAM/vCPU/autostart drift checks -- no state file to compare against."
fi

echo ""
echo "=== $VMNAME: guest checks (require the VM running + reachable over SSH) ==="

if [[ "$HAVE_DOMAIN" != "1" ]] || ! vm_is_running "$VMNAME"; then
    log "VM '$VMNAME' is not running -- skipping guest checks (start it with ./scripts/01_start_vm.sh)."
else
    if "${VIRSH[@]}" domifaddr "$VMNAME" --source agent >/dev/null 2>&1; then
        pass "qemu-guest-agent is responding"
    else
        fail "qemu-guest-agent is responding (virsh domifaddr --source agent failed)"
    fi

    log "Resolving an SSH host for '$VMNAME' (Tailscale hostname, else DHCP lease)..."
    SSH_HOST=""
    if SSH_HOST="$(configure_resolve_ssh_host "$VMNAME")"; then
        pass "SSH reachable ($SSH_HOST)"

        guest_run() { ssh "${CONFIGURE_SSH_OPTS[@]}" "${CONFIGURE_SSH_USER}@${SSH_HOST}" "$1"; }

        # "disabled" is the expected steady state, not just "done" -- the
        # last runcmd step in user-data.tmpl touches
        # /etc/cloud/cloud-init.disabled so it never runs again on
        # subsequent boots (see lifecycle_vms.md: "cloud-init only runs once").
        # Any later check (e.g. after the package_reboot_if_required reboot,
        # or just a doctor run days later) will legitimately report
        # "disabled", not "done".
        CLOUDINIT_OUT="$(guest_run 'cloud-init status' 2>&1 || true)"
        if grep -qE "status: (done|disabled)" <<< "$CLOUDINIT_OUT"; then
            pass "cloud-init finished on guest"
        else
            fail "cloud-init finished on guest (${CLOUDINIT_OUT:-no output})"
        fi

        if [[ "$HAVE_STATE" == "1" ]]; then
            STATE_DOCKER="$(state_get "$VMNAME" .docker 2>/dev/null || echo null)"
            if [[ "$STATE_DOCKER" == "installed" ]]; then
                if guest_run 'command -v docker >/dev/null 2>&1 && sudo systemctl is-active --quiet docker'; then
                    pass "Docker is installed and active on guest"
                else
                    fail "Docker is installed and active on guest (state.yaml says 'installed')"
                fi
            else
                log "Docker: state.yaml says '$STATE_DOCKER' -- skipping (run 11_configure_vm.sh to install)."
            fi

            STATE_TAILSCALE="$(state_get "$VMNAME" .tailscale 2>/dev/null || echo null)"
            if [[ "$STATE_TAILSCALE" == "up" ]]; then
                if guest_run 'ip link show tailscale0 >/dev/null 2>&1'; then
                    pass "tailscale0 interface is up on guest"
                else
                    fail "tailscale0 interface is up on guest (state.yaml says 'up')"
                fi
            else
                log "Tailscale: state.yaml says '$STATE_TAILSCALE' -- skipping (run 11_configure_vm.sh to join the tailnet)."
            fi

            STATE_UFW="$(state_get "$VMNAME" .ufw 2>/dev/null || echo null)"
            if [[ "$STATE_UFW" == "enabled" ]]; then
                if guest_run 'sudo ufw status | grep -q "Status: active"'; then
                    pass "UFW is active on guest"
                else
                    fail "UFW is active on guest (state.yaml says 'enabled')"
                fi
            else
                log "UFW: state.yaml says '$STATE_UFW' -- skipping (run 11_configure_vm.sh to enable it)."
            fi
        else
            log "Skipping Docker/Tailscale/UFW checks -- no state file to compare guest state against."
        fi
    else
        fail "SSH reachable (tried Tailscale hostname and DHCP lease IP)"
        log "Guest is running but unreachable over SSH -- skipping cloud-init/Docker/Tailscale/UFW checks."
    fi
fi

echo ""
if [[ $FAILURES -eq 0 ]]; then
    log "All checks passed."
    exit 0
else
    log "$FAILURES check(s) failed."
    exit 1
fi
