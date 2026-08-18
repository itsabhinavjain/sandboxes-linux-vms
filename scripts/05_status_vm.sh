#!/usr/bin/env bash
# Usage: scripts/05_status_vm.sh <vmname>
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USAGE=$(cat <<EOF
NAME
    05_status_vm.sh -- show a single VM's libvirt domain info + state.yaml + SSH hint

USAGE
    scripts/05_status_vm.sh <vmname>

REQUIRED
    <vmname>    VM name

OPTIONS
    -h, --help  Show this help and exit

For every managed VM at once, see 50_list_vms.sh / 51_info_vms.sh instead.
EOF
)
show_help_if_requested "$USAGE" "$@"
require_env

VMNAME="${1:?Missing <vmname>. Run 'scripts/05_status_vm.sh --help' for usage.}"
validate_vmname "$VMNAME"

STATE_PATH="$(state_path "$VMNAME")"
HAVE_DOMAIN=0
HAVE_STATE=0

vm_exists "$VMNAME" && HAVE_DOMAIN=1
[[ -f "$STATE_PATH" ]] && HAVE_STATE=1

if [[ "$HAVE_DOMAIN" == "0" && "$HAVE_STATE" == "0" ]]; then
    die "VM '$VMNAME' not found (no libvirt domain, no state file)."
fi

echo "=== libvirt domain info: $VMNAME ==="
if [[ "$HAVE_DOMAIN" == "1" ]]; then
    "${VIRSH[@]}" dominfo "$VMNAME"
else
    echo "(no libvirt domain defined for '$VMNAME')"
fi
echo ""

echo "=== state file: $STATE_PATH ==="
if [[ "$HAVE_STATE" == "1" ]]; then
    printf "%-12s %s\n" "name:"       "$(state_get "$VMNAME" .name)"
    printf "%-12s %s\n" "status:"     "$(state_get "$VMNAME" .status)"
    printf "%-12s %s\n" "autostart:" "$(state_get "$VMNAME" .autostart)"
    printf "%-12s %s\n" "ram_mb:"     "$(state_get "$VMNAME" .ram_mb)"
    printf "%-12s %s\n" "vcpus:"      "$(state_get "$VMNAME" .vcpus)"
    printf "%-12s %s\n" "disk_gb:"    "$(state_get "$VMNAME" .disk_gb)"
    printf "%-12s %s\n" "base_image:" "$(state_get "$VMNAME" .base_image)"
    printf "%-12s %s\n" "created_at:" "$(state_get "$VMNAME" .created_at)"
    printf "%-12s %s\n" "started_at:" "$(state_get "$VMNAME" .started_at)"
    printf "%-12s %s\n" "updated_at:" "$(state_get "$VMNAME" .updated_at)"
else
    echo "(no state file for '$VMNAME')"
fi
echo ""

if [[ -n "${TAILSCALE_TAILNET:-}" ]]; then
    echo "=== connect ==="
    echo "ssh ${VMNAME}.${TAILSCALE_TAILNET}"
fi
