#!/usr/bin/env bash
# Usage: scripts/11_configure-automated_vm.sh <vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]
#
# Post-boot configuration for an already-running VM: joins it to the
# Tailscale tailnet (needs TAILSCALE_AUTHKEY -- set it in .env, or pass
# --authkey) and locks UFW down to deny all inbound except tailscale0.
#
# Deliberately NOT baked into user-data.tmpl/cloud-init:
#   - cloud-init only runs once -- 00_init_vm.sh disables it after first
#     boot -- so re-running this script is the only way to change
#     network/firewall config on an existing VM without destroying and
#     recreating it.
#   - Joining Tailscale needs a secret (TAILSCALE_AUTHKEY). Keeping it out
#     of user-data.tmpl (which only ever has ${VMNAME} substituted, see
#     PLAN.md) avoids baking a secret into the rendered cloud-init seed ISO.
#   - Enabling UFW before Tailscale is confirmed up would lock out SSH with
#     no fallback other than `virsh console`; this script enforces that
#     ordering and refuses to enable UFW otherwise.
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

REMOTE_SCRIPT=/tmp/.sandbox-configure-vm.sh

cleanup_remote() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "sudo rm -f $REMOTE_SCRIPT" >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT

log "Uploading configuration script..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "cat > $REMOTE_SCRIPT" <<'REMOTE_EOF'
#!/usr/bin/env bash
set -euo pipefail

VMNAME="$1"
DO_TAILSCALE="$2"
DO_UFW="$3"

log() { echo "==> [$VMNAME] $*"; }

if [[ "$DO_TAILSCALE" == "1" ]]; then
    read -r TS_AUTHKEY

    if ! command -v tailscale >/dev/null 2>&1; then
        log "Installing Tailscale..."
        . /etc/os-release
        install -m 0755 -d /usr/share/keyrings
        curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get update -qq
        apt-get install -y -qq tailscale
    fi

    log "Bringing up Tailscale..."
    tailscale up --authkey="$TS_AUTHKEY" --hostname="$VMNAME"
fi

TAILSCALE_UP=0
for _ in $(seq 1 8); do
    if ip link show tailscale0 >/dev/null 2>&1; then
        TAILSCALE_UP=1
        break
    fi
    sleep 2
done

if [[ "$DO_TAILSCALE" == "1" && "$TAILSCALE_UP" != "1" ]]; then
    echo "ERROR: tailscale0 did not come up after 'tailscale up'." >&2
    exit 1
fi

if [[ "$DO_UFW" == "1" ]]; then
    if [[ "$TAILSCALE_UP" != "1" ]]; then
        echo "ERROR: refusing to enable UFW without a confirmed tailscale0 interface -- this would lock out future SSH with no console fallback. Configure Tailscale first, or pass --skip-ufw." >&2
        exit 1
    fi

    log "Configuring UFW (deny all inbound except tailscale0)..."
    command -v ufw >/dev/null 2>&1 || apt-get install -y -qq ufw

    ufw default deny incoming
    ufw default allow outgoing
    # Tailscale's own ACLs are the real access-control layer here -- ufw's
    # job is just to keep the NAT-facing interface closed to everything.
    ufw allow in on tailscale0 comment 'Tailscale tailnet traffic'
    ufw --force enable
    ufw status verbose
fi

log "Done."
REMOTE_EOF

log "Running configuration (sudo)..."
if [[ "$DO_TAILSCALE" == "1" ]]; then
    printf '%s\n' "$AUTHKEY"
else
    printf '\n'
fi | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "sudo bash $REMOTE_SCRIPT '$VMNAME' '$DO_TAILSCALE' '$DO_UFW'"

if [[ "$DO_TAILSCALE" == "1" ]]; then
    state_set "$VMNAME" .tailscale "up"
else
    state_set "$VMNAME" .tailscale "skipped"
fi

if [[ "$DO_UFW" == "1" ]]; then
    state_set "$VMNAME" .ufw "enabled"
else
    state_set "$VMNAME" .ufw "skipped"
fi

log "Configuration complete for '$VMNAME'."
if [[ "$DO_TAILSCALE" == "1" && -n "${TAILSCALE_TAILNET:-}" ]]; then
    log "Reconnect via: ssh ${SSH_USER}@${VMNAME}.${TAILSCALE_TAILNET}"
fi
