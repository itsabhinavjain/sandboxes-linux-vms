#!/usr/bin/env bash
# Shared step logic for 11_configure_vm.sh: SSH host resolution, remote
# step-script upload, and the tailscale/ufw remote actions. Source this
# after lib/common.sh, don't run it directly.
#
# Reaches an already-running VM over SSH as the `abhinav` user (already set
# up via cloud-init) -- via its Tailscale hostname if already joined, else
# its NAT/DHCP lease address -- uploads the remote step-script, and runs its
# actions (install-tailscale, bring-up-tailscale, check-tailscale0,
# configure-ufw, install-docker) either unconditionally (default) or behind
# a confirm() per step (11_configure_vm.sh -i/--interactive).

CONFIGURE_SSH_USER="abhinav"
CONFIGURE_SSH_OPTS=(
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

CONFIGURE_REMOTE_SCRIPT=/tmp/.sandbox-configure-vm.sh

configure_vm_dhcp_ip() {
    local out
    out="$("${VIRSH[@]}" domifaddr "$1" --source lease 2>/dev/null || true)"
    awk '$3 == "ipv4" { sub(/\/.*/, "", $4); print $4; exit }' <<< "$out"
}

configure_ssh_probe() { ssh "${CONFIGURE_SSH_OPTS[@]}" "${CONFIGURE_SSH_USER}@$1" true >/dev/null 2>&1; }

# configure_resolve_ssh_host <vmname> -- echoes a reachable SSH host (tries
# the Tailscale hostname first, then the DHCP lease IP) or returns 1.
configure_resolve_ssh_host() {
    local vmname="$1"
    if [[ -n "${TAILSCALE_TAILNET:-}" ]]; then
        local ts_host="${vmname}.${TAILSCALE_TAILNET}"
        if configure_ssh_probe "$ts_host"; then
            echo "$ts_host"
            return 0
        fi
    fi
    local ip
    ip="$(configure_vm_dhcp_ip "$vmname")"
    if [[ -n "$ip" ]] && configure_ssh_probe "$ip"; then
        echo "$ip"
        return 0
    fi
    return 1
}

# configure_wait_for_ssh <vmname> -- polls configure_resolve_ssh_host, echoes
# the host once reachable, or returns 1 after giving up.
configure_wait_for_ssh() {
    local vmname="$1" host=""
    for _ in $(seq 1 12); do
        if host="$(configure_resolve_ssh_host "$vmname")"; then
            echo "$host"
            return 0
        fi
        sleep 5
    done
    return 1
}

# configure_upload_remote_script <ssh_host> -- uploads the remote step script
# that install-tailscale/bring-up-tailscale/check-tailscale0/configure-ufw
# run against.
configure_upload_remote_script() {
    local ssh_host="$1"
    ssh "${CONFIGURE_SSH_OPTS[@]}" "${CONFIGURE_SSH_USER}@${ssh_host}" "cat > $CONFIGURE_REMOTE_SCRIPT" <<'REMOTE_EOF'
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

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Docker already installed."
        return 0
    fi
    log "Installing Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker abhinav
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
    # ufw itself dedupes an `allow` rule that already exists, so this is
    # safe to re-run.
    ufw allow in on tailscale0 comment 'Tailscale tailnet traffic'
    ufw --force enable
    ufw status verbose
}

case "$ACTION" in
    install-tailscale)  install_tailscale ;;
    bring-up-tailscale) bring_up_tailscale ;;
    check-tailscale0)   check_tailscale0 ;;
    configure-ufw)      configure_ufw ;;
    install-docker)     install_docker ;;
    *) echo "Unknown action: $ACTION" >&2; exit 1 ;;
esac
REMOTE_EOF
}

configure_cleanup_remote() {
    local ssh_host="$1"
    ssh "${CONFIGURE_SSH_OPTS[@]}" "${CONFIGURE_SSH_USER}@${ssh_host}" "sudo rm -f $CONFIGURE_REMOTE_SCRIPT" >/dev/null 2>&1 || true
}

# configure_run_step <ssh_host> <vmname> <action> -- runs one remote action
# with an allocated pty (-tt) so output streams live instead of being
# buffered until the command exits.
configure_run_step() {
    local ssh_host="$1" vmname="$2" action="$3"
    ssh -tt "${CONFIGURE_SSH_OPTS[@]}" "${CONFIGURE_SSH_USER}@${ssh_host}" "sudo bash $CONFIGURE_REMOTE_SCRIPT '$vmname' '$action'"
}

# configure_check_step <ssh_host> <vmname> <action> -- quiet, exit-code-only
# variant of configure_run_step, for polling/probing.
configure_check_step() {
    local ssh_host="$1" vmname="$2" action="$3"
    ssh "${CONFIGURE_SSH_OPTS[@]}" "${CONFIGURE_SSH_USER}@${ssh_host}" "sudo bash $CONFIGURE_REMOTE_SCRIPT '$vmname' '$action'" >/dev/null 2>&1
}

# configure_bring_up_tailscale <ssh_host> <vmname> <authkey> -- special-cased
# vs. configure_run_step because the authkey has to go over stdin, never
# argv/env, so it never shows up in `ps` on the remote host. -tt still forces
# pty allocation even though stdin here is a pipe, so tailscale's own status
# output keeps streaming live.
configure_bring_up_tailscale() {
    local ssh_host="$1" vmname="$2" authkey="$3"
    printf '%s\n' "$authkey" | ssh -tt "${CONFIGURE_SSH_OPTS[@]}" "${CONFIGURE_SSH_USER}@${ssh_host}" "sudo bash $CONFIGURE_REMOTE_SCRIPT '$vmname' bring-up-tailscale"
}
