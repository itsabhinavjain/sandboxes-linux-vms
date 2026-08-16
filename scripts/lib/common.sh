#!/usr/bin/env bash
# Shared helpers for the sandbox lifecycle scripts. Source this, don't run it:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Requires: virsh, virt-install, qemu-img, cloud-localds, envsubst, yq
# (yq here means mikefarah/yq (Go), NOT kislyuk/yq (Python/jq wrapper) --
# the -i in-place and `.key = "value"` syntax below is mikefarah/yq syntax.)

set -euo pipefail

# Resolve repo root relative to this file (scripts/lib/common.sh -> repo
# root is two levels up), not $PWD, so scripts work regardless of the
# caller's working directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Always talk to the system libvirtd explicitly -- never rely on the
# ambient default URI (which may be qemu:///session for a non-root user).
VIRSH=(virsh -c qemu:///system)

log() { echo "==> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# confirm "Prompt text" -- returns 0 (proceed) if FORCE=1 or the user types
# "yes". Scripts that take --force/-y should set FORCE=1 before calling this.
confirm() {
    local prompt="${1:-Continue?}"
    if [[ "${FORCE:-0}" == "1" ]]; then
        return 0
    fi
    local reply
    read -r -p "${prompt} (yes/no): " reply
    [[ "$reply" == "yes" ]]
}

check_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_env() {
    local required=(
        SANDBOX_HOME LIBVIRT_HOME
        STORAGE_POOL_IMAGES STORAGE_POOL_ISOS STORAGE_POOL_DISKS STORAGE_POOL_SNAPSHOTS
        DEFAULT_CLOUD_IMG DEFAULT_OS_VARIANT DEFAULT_RAM_MB DEFAULT_VCPUS DEFAULT_DISK_GB
    )
    local missing=()
    local var
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required environment variables: ${missing[*]}. Copy env.sample and source it (see SETUP.md)."
    fi
}

# validate_vmname <name> -- call this on every user-supplied vmname before
# it's used in any path or virsh command.
validate_vmname() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        die "VM name is required."
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "Invalid VM name '$name': only letters, digits, '_' and '-' are allowed."
    fi
}

# --- Path helpers (all per-VM files live flat in STORAGE_POOL_DISKS) ---

disk_path()  { echo "${STORAGE_POOL_DISKS}/$1.qcow2"; }
seed_path()  { echo "${STORAGE_POOL_DISKS}/$1-seed.iso"; }
state_path() { echo "${STORAGE_POOL_DISKS}/$1.state.yaml"; }

# base_image_path [image-name] -- defaults to DEFAULT_CLOUD_IMG
base_image_path() {
    local image="${1:-$DEFAULT_CLOUD_IMG}"
    echo "${STORAGE_POOL_IMAGES}/${image}.img"
}

# --- libvirt domain lookups ---
#
# NOTE: these capture virsh's output into a variable before grepping it,
# rather than piping directly into `grep -q`/`grep -qx`. Under `pipefail`
# (set above), `grep -q` exits the instant it finds a match, closing its
# end of the pipe while virsh may still be writing -- virsh then dies of
# SIGPIPE, and pipefail surfaces that as the pipeline's exit status even
# though the match succeeded. Capturing first avoids the race entirely.

vm_exists() {
    local list
    list="$("${VIRSH[@]}" list --all --name 2>/dev/null || true)"
    grep -qx "$1" <<< "$list"
}

vm_is_running() {
    local list
    list="$("${VIRSH[@]}" list --name 2>/dev/null || true)"
    grep -qx "$1" <<< "$list"
}

# --- state.yaml helpers ---

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# state_init <vmname> <ram_mb> <vcpus> <disk_gb> <base_image> <autostart: true|false>
state_init() {
    local vmname="$1" ram_mb="$2" vcpus="$3" disk_gb="$4" base_image="$5" autostart="$6"
    local path; path="$(state_path "$vmname")"
    local ts; ts="$(now_utc)"
    cat > "$path" <<EOF
name: "$vmname"
status: initializing
ram_mb: $ram_mb
vcpus: $vcpus
disk_gb: $disk_gb
base_image: "$base_image"
autostart: $autostart
created_at: "$ts"
updated_at: "$ts"
started_at: null
EOF
}

# state_get <vmname> <yq-path, e.g. .status>
state_get() {
    local vmname="$1" key="$2"
    yq -r "$key" "$(state_path "$vmname")"
}

# state_set <vmname> <yq-path> <value> -- value is written as a YAML string.
# Also bumps updated_at. For non-string values, pass a raw yq expression via
# state_set_raw instead.
state_set() {
    local vmname="$1" key="$2" value="$3"
    local path; path="$(state_path "$vmname")"
    yq -i "${key} = \"${value}\"" "$path"
    yq -i ".updated_at = \"$(now_utc)\"" "$path"
}

state_remove() {
    local vmname="$1"
    rm -f "$(state_path "$vmname")"
}
