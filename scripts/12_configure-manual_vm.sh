#!/usr/bin/env bash
# Usage: scripts/12_configure-manual_vm.sh <vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]
#
# Interactive counterpart to 11_configure-automated_vm.sh: same end state
# (VM joined to the tailnet, UFW locked down to tailscale0-only) but walked
# through step by step over SSH instead of run unattended -- confirms before
# each step and runs it with an allocated pty so output (apt, `tailscale up`,
# `ufw status verbose`) streams live. Use 11_... for a fire-and-forget run;
# use this one to watch/approve each step, e.g. first time configuring a new
# base image, or debugging why tailscale/ufw isn't coming up cleanly.
#
# Still enforces the same ordering safety as 11_...: refuses to enable UFW
# unless tailscale0 is confirmed up first -- enabling a deny-by-default
# firewall before that would lock out SSH with no fallback besides
# `virsh console`.
#
# Reaches the VM over SSH as the `abhinav` user (already set up via
# cloud-init) -- via its Tailscale hostname if already joined, else its
# NAT/DHCP lease address.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

check_bin ssh

VMNAME="${1:?Usage: $0 <vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]}"
shift

DO_TAILSCALE=1
DO_UFW=1
AUTHKEY="${TAILSCALE_AUTHKEY:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-tailscale) DO_TAILSCALE=0; shift ;;
        --skip-ufw)       DO_UFW=0; shift ;;
        --authkey)        AUTHKEY="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

validate_vmname "$VMNAME"

STATE_PATH="$(state_path "$VMNAME")"
[[ -f "$STATE_PATH" ]] || die "No state file for '$VMNAME' -- run scripts/00_init_vm.sh $VMNAME first."
vm_is_running "$VMNAME" || die "VM '$VMNAME' is not running -- run scripts/01_start_vm.sh $VMNAME first."

if [[ "$DO_TAILSCALE" == "1" && -z "$AUTHKEY" ]]; then
    die "TAILSCALE_AUTHKEY not set (.env) and no --authkey given. Generate a reusable/ephemeral key at https://login.tailscale.com/admin/settings/keys, or pass --skip-tailscale."
fi

SSH_USER="abhinav"
SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)

# NAT/DHCP addresses get reused across short-lived sandbox VMs, so a strict
# known_hosts check would fail on stale host keys from a previous VM at the
# same lease address -- these VMs live on a private libvirt NAT network, not
# the open internet, so that tradeoff is acceptable here.

vm_dhcp_ip() {
    local out
    out="$("${VIRSH[@]}" domifaddr "$1" --source lease 2>/dev/null || true)"
    awk '$3 == "ipv4" { sub(/\/.*/, "", $4); print $4; exit }' <<< "$out"
}

ssh_probe() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@$1" true >/dev/null 2>&1; }

resolve_ssh_host() {
    if [[ -n "${TAILSCALE_TAILNET:-}" ]]; then
        local ts_host="${VMNAME}.${TAILSCALE_TAILNET}"
        if ssh_probe "$ts_host"; then
            echo "$ts_host"
            return 0
        fi
    fi
    local ip
    ip="$(vm_dhcp_ip "$VMNAME")"
    if [[ -n "$ip" ]] && ssh_probe "$ip"; then
        echo "$ip"
        return 0
    fi
    return 1
}

log "Waiting for SSH on '$VMNAME'..."
SSH_HOST=""
for _ in $(seq 1 12); do
    if SSH_HOST="$(resolve_ssh_host)"; then
        break
    fi
    sleep 5
done
[[ -n "$SSH_HOST" ]] || die "Could not reach '$VMNAME' over SSH (tried Tailscale hostname and DHCP lease IP). Is it done booting / has cloud-init finished?"
log "Reaching '$VMNAME' via $SSH_HOST"

# Distinct path from 11_configure-automated_vm.sh's remote script so the two
# don't collide if someone runs both against the same VM back to back.
REMOTE_SCRIPT=/tmp/.sandbox-configure-vm-manual.sh

cleanup_remote() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "sudo rm -f $REMOTE_SCRIPT" >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT

log "Uploading configuration script..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "cat > $REMOTE_SCRIPT" <<'REMOTE_EOF'
#!/usr/bin/env bash
set -euo pipefail

VMNAME="$1"
ACTION="$2"

log() { echo "==> [$VMNAME] $*"; }

install_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then
        log "Tailscale already installed."
        return 0
    fi
    log "Installing Tailscale..."
    . /etc/os-release
    install -m 0755 -d /usr/share/keyrings
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    apt-get install -y -qq tailscale
}

bring_up_tailscale() {
    read -r TS_AUTHKEY
    log "Bringing up Tailscale..."
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$VMNAME"
}

check_tailscale0() {
    ip link show tailscale0 >/dev/null 2>&1
}

configure_ufw() {
    log "Configuring UFW (deny all inbound except tailscale0)..."
    command -v ufw >/dev/null 2>&1 || apt-get install -y -qq ufw
    ufw default deny incoming
    ufw default allow outgoing
    # Tailscale's own ACLs are the real access-control layer here -- ufw's
    # job is just to keep the NAT-facing interface closed to everything.
    ufw allow in on tailscale0 comment 'Tailscale tailnet traffic'
    ufw --force enable
    ufw status verbose
}

case "$ACTION" in
    install-tailscale)  install_tailscale ;;
    bring-up-tailscale) bring_up_tailscale ;;
    check-tailscale0)   check_tailscale0 ;;
    configure-ufw)      configure_ufw ;;
    *) echo "Unknown action: $ACTION" >&2; exit 1 ;;
esac
REMOTE_EOF

# Runs one remote action with an allocated pty (-tt) so output streams live
# instead of being buffered until the command exits -- the point of the
# "manual" script is to watch each step happen, not just get a final result.
run_step() {
    ssh -tt "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "sudo bash $REMOTE_SCRIPT '$VMNAME' '$1'"
}

check_step() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "sudo bash $REMOTE_SCRIPT '$VMNAME' '$1'" >/dev/null 2>&1
}

TAILSCALE_STATE="skipped"

if [[ "$DO_TAILSCALE" == "1" ]]; then
    if confirm "Install/verify Tailscale on '$VMNAME'?"; then
        run_step install-tailscale
    else
        log "Skipped Tailscale install step."
    fi

    if confirm "Run 'tailscale up --hostname=${VMNAME}' on '$VMNAME' now?"; then
        # -tt forces pty allocation even though stdin here is a pipe (the
        # authkey), not a terminal -- keeps tailscale's own status output
        # streaming live. Authkey goes over stdin, never argv/env, so it
        # never shows up in `ps` on the remote host.
        printf '%s\n' "$AUTHKEY" | ssh -tt "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "sudo bash $REMOTE_SCRIPT '$VMNAME' bring-up-tailscale"
    else
        log "Skipped 'tailscale up'."
    fi

    log "Checking for tailscale0 interface..."
    TAILSCALE_UP=0
    for _ in $(seq 1 8); do
        if check_step check-tailscale0; then
            TAILSCALE_UP=1
            break
        fi
        sleep 2
    done

    if [[ "$TAILSCALE_UP" == "1" ]]; then
        TAILSCALE_STATE="up"
        log "tailscale0 is up on '$VMNAME'."
    else
        log "tailscale0 is not up on '$VMNAME'."
    fi
fi

UFW_STATE="skipped"

if [[ "$DO_UFW" == "1" ]]; then
    if [[ "$TAILSCALE_STATE" != "up" ]]; then
        die "Refusing to enable UFW without a confirmed tailscale0 interface on '$VMNAME' -- this would lock out SSH with no fallback besides 'virsh console'. Configure Tailscale first, or pass --skip-ufw."
    fi

    if confirm "Enable UFW on '$VMNAME' (deny all inbound except tailscale0)?"; then
        run_step configure-ufw
        UFW_STATE="enabled"
    else
        log "Skipped enabling UFW."
    fi
fi

if [[ "$DO_TAILSCALE" == "1" ]]; then
    state_set "$VMNAME" .tailscale "$TAILSCALE_STATE"
else
    state_set "$VMNAME" .tailscale "skipped"
fi

state_set "$VMNAME" .ufw "$UFW_STATE"

log "Configuration complete for '$VMNAME'."
if [[ "$TAILSCALE_STATE" == "up" && -n "${TAILSCALE_TAILNET:-}" ]]; then
    log "Reconnect via: ssh ${SSH_USER}@${VMNAME}.${TAILSCALE_TAILNET}"
fi
