#!/usr/bin/env bash
# Move LIBVIRT_HOME (and all 5 libvirt storage pools) to a new location,
# migrating every VM this toolkit manages -- disk overlay, seed ISO, base
# image backing-file pointer, and libvirt domain XML -- along with it.
#
# This is a host-level admin script (like 81/82/83/85), not a lifecycle
# script -- it uses sudo throughout, same as 83_host_configure_libvirt_storage_pools.sh.

set -euo pipefail

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

USAGE=$(cat <<'EOF'
NAME
    84_host_change_libvirt_storage_pools.sh -- move LIBVIRT_HOME (and all 5
    storage pools) to a new location, migrating every VM this toolkit
    manages along with it.

USAGE
    ./scripts/84_host_change_libvirt_storage_pools.sh <new-libvirt-home> [options]

REQUIRED
    <new-libvirt-home>   Absolute path to the new LIBVIRT_HOME, e.g.
                          /mnt/new_ssd/libvirt. Must differ from the
                          current LIBVIRT_HOME and not be nested inside it
                          (or vice versa).

OPTIONS
    -y, --force    Skip the "are you sure?" confirmation, and hard power
                   off (virsh destroy) any managed VM that doesn't shut
                   down gracefully within the stop timeout.
    --dry-run      Print the migration plan (old/new paths, managed VMs,
                   data size) and exit without changing anything.
    --purge-old    Delete the old pool directories after the copy to the
                   new location is verified. Without this (the default),
                   old data is left in place -- remove it by hand once
                   you've confirmed everything works at the new location.
    -h, --help     Show this help and exit.

WHAT IT DOES
    1. Finds every VM this toolkit manages (a *.state.yaml under the
       current STORAGE_POOL_DISKS) and stops any that are running,
       remembering which ones to restart afterwards. Domains not managed
       by this toolkit are left untouched throughout.
    2. Deactivates the 5 libvirt storage pools (default, iso-pool,
       disk-pool, snapshot-pool, cloudinit-pool).
    3. rsync's each pool's contents to the new location, verifying file
       counts match before touching anything in the old location.
    4. Redefines the 5 pools pointing at their new targets and starts them.
    5. For every managed VM: rebases its qcow2 overlay's backing-file
       pointer onto the moved base image (qemu-img rebase -u), and
       redefines its libvirt domain XML with the new disk/seed-ISO paths.
    6. Restarts whichever managed VMs were running in step 1.
    7. Rewrites /etc/profile.d/sandbox.sh's LIBVIRT_HOME to the new path
       (backing up the old file first), and updates any
       LIBVIRT_HOME/STORAGE_POOL_* lines found in this repo's .env, if
       one exists (backed up first too).

EXAMPLES
    ./scripts/84_host_change_libvirt_storage_pools.sh /mnt/new_ssd/libvirt --dry-run
    ./scripts/84_host_change_libvirt_storage_pools.sh /mnt/new_ssd/libvirt
    ./scripts/84_host_change_libvirt_storage_pools.sh /mnt/new_ssd/libvirt --purge-old -y
EOF
)

for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        printf '%s\n' "$USAGE"
        exit 0
    fi
done

# -----------------------------------------------------------------------------
# Small local helpers (this script doesn't source scripts/lib/common.sh --
# it's a host-level script in the 80s series, same as 81/82/83/85, not a
# per-VM lifecycle script)
# -----------------------------------------------------------------------------

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

FORCE=0
confirm() {
    local prompt="${1:-Continue?}"
    if [[ "$FORCE" -eq 1 ]]; then
        return 0
    fi
    local reply
    read -r -p "${prompt} (yes/no): " reply
    [[ "$reply" == "yes" ]]
}

human_size() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1} bytes"
    else
        echo "${1} bytes"
    fi
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

NEW_LIBVIRT_HOME=""
DRY_RUN=0
PURGE_OLD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--force)   FORCE=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --purge-old)  PURGE_OLD=1; shift ;;
        -*)
            die "Unknown flag: $1 (see --help)"
            ;;
        *)
            if [[ -n "$NEW_LIBVIRT_HOME" ]]; then
                die "Unexpected extra argument: $1 (see --help)"
            fi
            NEW_LIBVIRT_HOME="$1"
            shift
            ;;
    esac
done

[[ -n "$NEW_LIBVIRT_HOME" ]] || die "Missing required argument <new-libvirt-home> (see --help)"
NEW_LIBVIRT_HOME="${NEW_LIBVIRT_HOME%/}"
[[ "$NEW_LIBVIRT_HOME" == /* ]] || die "New LIBVIRT_HOME must be an absolute path, got: $NEW_LIBVIRT_HOME"

# -----------------------------------------------------------------------------
# Required environment variables (current/old location)
# -----------------------------------------------------------------------------

required_vars=(
    SANDBOX_HOME LIBVIRT_HOME
    STORAGE_POOL_IMAGES STORAGE_POOL_ISOS STORAGE_POOL_DISKS STORAGE_POOL_SNAPSHOTS STORAGE_POOL_CLOUD_INIT_ISOS
    DEFAULT_CLOUD_IMG DEFAULT_OS_VARIANT DEFAULT_RAM_MB DEFAULT_VCPUS DEFAULT_DISK_GB
)
missing_vars=()
for var in "${required_vars[@]}"; do
    [[ -z "${!var:-}" ]] && missing_vars+=("$var")
done
if (( ${#missing_vars[@]} > 0 )); then
    echo "ERROR: Required environment variables are not defined:" >&2
    printf '  %s\n' "${missing_vars[@]}" >&2
    echo "Source your environment first, e.g.: source /etc/profile.d/sandbox.sh" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Compute old/new paths (cheap argument-sanity checks -- do these before
# touching virsh at all, so a plain mistake in <new-libvirt-home> doesn't
# require a working libvirt connection to be caught)
# -----------------------------------------------------------------------------

OLD_LIBVIRT_HOME="$LIBVIRT_HOME"

if [[ "$NEW_LIBVIRT_HOME" == "$OLD_LIBVIRT_HOME" ]]; then
    die "New LIBVIRT_HOME is the same as the current one ($OLD_LIBVIRT_HOME) -- nothing to do."
fi
if [[ "$NEW_LIBVIRT_HOME" == "$OLD_LIBVIRT_HOME"/* || "$OLD_LIBVIRT_HOME" == "$NEW_LIBVIRT_HOME"/* ]]; then
    die "New LIBVIRT_HOME ($NEW_LIBVIRT_HOME) cannot be nested inside the current one ($OLD_LIBVIRT_HOME), or vice versa."
fi

check_bin virsh
check_bin rsync
check_bin qemu-img

if ! sudo virsh uri >/dev/null 2>&1; then
    die "Cannot connect to libvirt (sudo virsh uri failed)."
fi

POOL_NAMES=(default iso-pool disk-pool snapshot-pool cloudinit-pool)
OLD_DIRS=("$STORAGE_POOL_IMAGES" "$STORAGE_POOL_ISOS" "$STORAGE_POOL_DISKS" "$STORAGE_POOL_SNAPSHOTS" "$STORAGE_POOL_CLOUD_INIT_ISOS")

NEW_IMAGES="$NEW_LIBVIRT_HOME/images"
NEW_ISOS="$NEW_LIBVIRT_HOME/isos"
NEW_DISKS="$NEW_LIBVIRT_HOME/disks"
NEW_SNAPSHOTS="$NEW_LIBVIRT_HOME/snapshots"
NEW_CLOUDINIT="$NEW_LIBVIRT_HOME/cloud-init"
NEW_DIRS=("$NEW_IMAGES" "$NEW_ISOS" "$NEW_DISKS" "$NEW_SNAPSHOTS" "$NEW_CLOUDINIT")

OLD_DISKS="$STORAGE_POOL_DISKS"
OLD_IMAGES="$STORAGE_POOL_IMAGES"
OLD_CLOUDINIT="$STORAGE_POOL_CLOUD_INIT_ISOS"

# -----------------------------------------------------------------------------
# Discover VMs this toolkit manages (a state.yaml under the current disk
# pool -- same scoping 50_list_vms.sh uses). Domains on this host with no
# matching state file are never touched by this script.
# -----------------------------------------------------------------------------

MANAGED_VMS=()
shopt -s nullglob
for f in "$OLD_DISKS"/*.state.yaml; do
    MANAGED_VMS+=("$(basename "$f" .state.yaml)")
done
shopt -u nullglob

# -----------------------------------------------------------------------------
# Preflight: disk space
# -----------------------------------------------------------------------------

OLD_SIZE_BYTES=0
if [[ -d "$OLD_LIBVIRT_HOME" ]]; then
    OLD_SIZE_BYTES="$(sudo du -sb "$OLD_LIBVIRT_HOME" 2>/dev/null | awk '{print $1}')"
    OLD_SIZE_BYTES="${OLD_SIZE_BYTES:-0}"
fi

NEW_PARENT="$(dirname "$NEW_LIBVIRT_HOME")"
sudo mkdir -p "$NEW_PARENT"
FREE_BYTES="$(df --output=avail -B1 "$NEW_PARENT" 2>/dev/null | tail -n1 | tr -d ' ')"
FREE_BYTES="${FREE_BYTES:-0}"

if (( FREE_BYTES > 0 && OLD_SIZE_BYTES > FREE_BYTES )); then
    die "Not enough free space at $NEW_PARENT: need ~$(human_size "$OLD_SIZE_BYTES"), have $(human_size "$FREE_BYTES")."
fi

# -----------------------------------------------------------------------------
# Print plan
# -----------------------------------------------------------------------------

echo "============================================================"
echo "Migration plan"
echo "============================================================"
echo "Old LIBVIRT_HOME: $OLD_LIBVIRT_HOME  (~$(human_size "$OLD_SIZE_BYTES"))"
echo "New LIBVIRT_HOME: $NEW_LIBVIRT_HOME"
echo
echo "Pools:"
for i in "${!POOL_NAMES[@]}"; do
    printf '  %-14s %s -> %s\n' "${POOL_NAMES[$i]}" "${OLD_DIRS[$i]}" "${NEW_DIRS[$i]}"
done
echo
if (( ${#MANAGED_VMS[@]} == 0 )); then
    echo "Managed VMs: none found."
else
    echo "Managed VMs (${#MANAGED_VMS[@]}): ${MANAGED_VMS[*]}"
fi
echo
echo "Old data will be $( [[ "$PURGE_OLD" -eq 1 ]] && echo "DELETED after verification" || echo "left in place" )."
echo "============================================================"

if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run -- no changes made."
    exit 0
fi

confirm "Proceed with this migration?" || die "Aborted."

# -----------------------------------------------------------------------------
# Step 1: stop running managed VMs
# -----------------------------------------------------------------------------

STOP_TIMEOUT="${STOP_TIMEOUT:-120}"
RUNNING_BEFORE=()

for vm in "${MANAGED_VMS[@]}"; do
    if ! sudo virsh dominfo "$vm" >/dev/null 2>&1; then
        log "WARNING: $vm has a state file but no libvirt domain -- skipping it entirely."
        continue
    fi
    state="$(sudo virsh domstate "$vm" 2>/dev/null || echo unknown)"
    if [[ "$state" == "running" ]]; then
        RUNNING_BEFORE+=("$vm")
    fi
done

if (( ${#RUNNING_BEFORE[@]} > 0 )); then
    log "Gracefully stopping running managed VMs: ${RUNNING_BEFORE[*]}"
    for vm in "${RUNNING_BEFORE[@]}"; do
        sudo virsh shutdown "$vm" >/dev/null 2>&1 || true
    done
    for vm in "${RUNNING_BEFORE[@]}"; do
        waited=0
        state="$(sudo virsh domstate "$vm" 2>/dev/null || echo unknown)"
        while [[ "$state" != "shut off" && "$waited" -lt "$STOP_TIMEOUT" ]]; do
            sleep 3
            waited=$((waited + 3))
            state="$(sudo virsh domstate "$vm" 2>/dev/null || echo unknown)"
        done
        if [[ "$state" != "shut off" ]]; then
            if [[ "$FORCE" -eq 1 ]]; then
                log "  $vm still '$state' after ${STOP_TIMEOUT}s -- forcing power off (--force)."
                sudo virsh destroy "$vm" >/dev/null 2>&1 || true
            else
                die "$vm did not shut down within ${STOP_TIMEOUT}s. Stop it manually, or re-run with --force to hard power it off."
            fi
        else
            log "  $vm is shut off."
        fi
    done
fi

# -----------------------------------------------------------------------------
# Step 2: deactivate the old pools
# -----------------------------------------------------------------------------

log "Deactivating storage pools"
for pool in "${POOL_NAMES[@]}"; do
    # No `virsh pool-is-active` predicate exists -- pool-destroy on an
    # already-inactive pool just errors, which is fine to swallow here.
    if sudo virsh pool-info "$pool" >/dev/null 2>&1; then
        sudo virsh pool-destroy "$pool" >/dev/null 2>&1 || true
    fi
done

# -----------------------------------------------------------------------------
# Step 3: copy data to the new location, verifying before touching old data
# -----------------------------------------------------------------------------

log "Copying pool data to $NEW_LIBVIRT_HOME"
for i in "${!POOL_NAMES[@]}"; do
    old_dir="${OLD_DIRS[$i]}"
    new_dir="${NEW_DIRS[$i]}"
    log "  ${POOL_NAMES[$i]}: $old_dir -> $new_dir"
    sudo mkdir -p "$new_dir"
    if [[ -d "$old_dir" ]]; then
        sudo rsync -aH "$old_dir/" "$new_dir/"
        old_count="$(sudo find "$old_dir" -type f | wc -l)"
        new_count="$(sudo find "$new_dir" -type f | wc -l)"
        if [[ "$old_count" != "$new_count" ]]; then
            die "File count mismatch after copying ${POOL_NAMES[$i]} ($old_dir -> $new_dir): old=$old_count new=$new_count. Old data left untouched -- investigate before re-running."
        fi
        log "    verified: $new_count files."
    else
        log "    old directory does not exist, nothing to copy."
    fi
done

log "Setting ownership and permissions on $NEW_LIBVIRT_HOME"
sudo chown -R libvirt-qemu:kvm "$NEW_LIBVIRT_HOME"
sudo chmod -R 775 "$NEW_LIBVIRT_HOME"
sudo find "$NEW_LIBVIRT_HOME" -type d -exec chmod g+s {} \;

# -----------------------------------------------------------------------------
# Step 4: redefine pools at the new targets
# -----------------------------------------------------------------------------

ensure_pool() {
    local pool="$1" target="$2"
    log "  $pool -> $target"
    local exists=0 current_target=""
    if sudo virsh pool-info "$pool" >/dev/null 2>&1; then
        exists=1
        current_target="$(sudo virsh pool-dumpxml "$pool" | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -n1)"
    fi
    if [[ "$exists" -eq 0 ]]; then
        sudo virsh pool-define-as "$pool" dir --target "$target"
    elif [[ "$current_target" != "$target" ]]; then
        sudo virsh pool-destroy "$pool" >/dev/null 2>&1 || true
        sudo virsh pool-undefine "$pool"
        sudo virsh pool-define-as "$pool" dir --target "$target"
    fi
    sudo virsh pool-autostart "$pool" >/dev/null 2>&1 || true
    # No `virsh pool-is-active` predicate exists -- just try to start it;
    # if it's already active this errors harmlessly, hence `|| true`.
    sudo virsh pool-start "$pool" >/dev/null 2>&1 || true
    sudo virsh pool-refresh "$pool" >/dev/null 2>&1 || true
}

log "Redefining storage pools at their new targets"
for i in "${!POOL_NAMES[@]}"; do
    ensure_pool "${POOL_NAMES[$i]}" "${NEW_DIRS[$i]}"
done

# -----------------------------------------------------------------------------
# Step 5: per-VM -- rebase qcow2 backing file, rewrite domain XML
# -----------------------------------------------------------------------------

update_vm_paths() {
    local vm="$1"
    log "Updating $vm"

    local xml new_xml src changed=0
    xml="$(sudo virsh dumpxml "$vm")"
    new_xml="$xml"

    while IFS= read -r src; do
        [[ -z "$src" ]] && continue
        local new_src="$src"

        if [[ "$src" == "$OLD_DISKS"/* ]]; then
            new_src="${NEW_DISKS}${src#"$OLD_DISKS"}"
        elif [[ "$src" == "$OLD_CLOUDINIT"/* ]]; then
            new_src="${NEW_CLOUDINIT}${src#"$OLD_CLOUDINIT"}"
        else
            continue
        fi

        if [[ "$new_src" != "$src" ]]; then
            new_xml="${new_xml//$src/$new_src}"
            changed=1
        fi

        if [[ "$src" == "$OLD_DISKS"/* ]]; then
            local backing
            backing="$(sudo qemu-img info --output=json "$new_src" 2>/dev/null \
                | grep -oP '"backing-filename":\s*"\K[^"]+' || true)"
            if [[ -n "$backing" && "$backing" == "$OLD_IMAGES"/* ]]; then
                local new_backing="${NEW_IMAGES}${backing#"$OLD_IMAGES"}"
                log "    rebasing $new_src onto $new_backing"
                sudo qemu-img rebase -u -F qcow2 -b "$new_backing" "$new_src"
            fi
        fi
    done < <(grep -oP "(?<=<source file=[\"'])[^\"']+" <<< "$xml")

    if [[ "$changed" -eq 1 ]]; then
        local tmpxml
        tmpxml="$(mktemp)"
        printf '%s\n' "$new_xml" > "$tmpxml"
        sudo virsh define "$tmpxml" >/dev/null
        rm -f "$tmpxml"
        log "    domain redefined with new paths."
    else
        log "    no path changes needed."
    fi
}

if (( ${#MANAGED_VMS[@]} > 0 )); then
    log "Updating managed VM disks and domain definitions"
    for vm in "${MANAGED_VMS[@]}"; do
        sudo virsh dominfo "$vm" >/dev/null 2>&1 || continue
        update_vm_paths "$vm"
    done
fi

# -----------------------------------------------------------------------------
# Step 6: restart VMs that were running before the migration
# -----------------------------------------------------------------------------

if (( ${#RUNNING_BEFORE[@]} > 0 )); then
    log "Restarting VMs that were running before the migration"
    for vm in "${RUNNING_BEFORE[@]}"; do
        if sudo virsh start "$vm" >/dev/null 2>&1; then
            log "  $vm started."
        else
            log "  WARNING: failed to restart $vm -- check 'sudo virsh dumpxml $vm' and start it manually."
        fi
    done
fi

# -----------------------------------------------------------------------------
# Step 7: update /etc/profile.d/sandbox.sh and this repo's .env
# -----------------------------------------------------------------------------

update_profile() {
    local profile_file="/etc/profile.d/sandbox.sh"
    if [[ ! -f "$profile_file" ]]; then
        log "No $profile_file found -- skipping profile update."
        return
    fi

    local backup
    backup="${profile_file}.bak.$(date +%Y%m%d%H%M%S)"
    sudo cp "$profile_file" "$backup"
    sudo cmp -s "$profile_file" "$backup" || die "Backup of $profile_file to $backup doesn't match the original -- aborting before writing a new one over it. Check disk space / filesystem health at $(dirname "$backup")."
    log "Backed up $profile_file -> $backup"

    cat > /tmp/sandbox.sh <<EOF
#!/usr/bin/env bash

export SANDBOX_HOME="\${SANDBOX_HOME:-$SANDBOX_HOME}"

# LIBVIRT_HOME was migrated by 84_host_change_libvirt_storage_pools.sh on
# $(date -u +%Y-%m-%dT%H:%M:%SZ). Pinned to a static path rather than any
# previous mountpoint auto-detect -- hand-edit this file if you want that
# kind of conditional back.
export LIBVIRT_HOME="$NEW_LIBVIRT_HOME"

export STORAGE_POOL_IMAGES="\${LIBVIRT_HOME}/images"
export STORAGE_POOL_ISOS="\${LIBVIRT_HOME}/isos"
export STORAGE_POOL_DISKS="\${LIBVIRT_HOME}/disks"
export STORAGE_POOL_SNAPSHOTS="\${LIBVIRT_HOME}/snapshots"
export STORAGE_POOL_CLOUD_INIT_ISOS="\${LIBVIRT_HOME}/cloud-init"

export DEFAULT_CLOUD_IMG="$DEFAULT_CLOUD_IMG"
export DEFAULT_OS_VARIANT="$DEFAULT_OS_VARIANT"
export DEFAULT_RAM_MB="$DEFAULT_RAM_MB"
export DEFAULT_VCPUS="$DEFAULT_VCPUS"
export DEFAULT_DISK_GB="$DEFAULT_DISK_GB"

export DEFAULT_AUTOSTART="${DEFAULT_AUTOSTART:-false}"

# Used for SSH connection hints (vmname.<tailnet>.ts.net) and the
# ssh-keygen -R reminder printed by 04_destroy_vm.sh. Set this to your tailnet
# name, e.g. "tailnet-name.ts.net" or leave unset if you don't use Tailscale.
export TAILSCALE_TAILNET="${TAILSCALE_TAILNET:-}"
EOF

    sudo install -m 644 /tmp/sandbox.sh "$profile_file"
    rm -f /tmp/sandbox.sh
    log "Updated $profile_file (LIBVIRT_HOME=$NEW_LIBVIRT_HOME)"
}

update_env_file() {
    local repo_root env_file
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    env_file="$repo_root/.env"

    if [[ ! -f "$env_file" ]]; then
        log "No .env in repo root -- skipping."
        return
    fi

    local backup
    backup="${env_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$env_file" "$backup"
    cmp -s "$env_file" "$backup" || die "Backup of .env to $backup doesn't match the original -- aborting before writing a new one over it. Check disk space / filesystem health at $(dirname "$backup")."
    log "Backed up .env -> $(basename "$backup")"

    local vars=(LIBVIRT_HOME STORAGE_POOL_IMAGES STORAGE_POOL_ISOS STORAGE_POOL_DISKS STORAGE_POOL_SNAPSHOTS STORAGE_POOL_CLOUD_INIT_ISOS)
    local vals=("$NEW_LIBVIRT_HOME" "$NEW_IMAGES" "$NEW_ISOS" "$NEW_DISKS" "$NEW_SNAPSHOTS" "$NEW_CLOUDINIT")
    local updated=0

    for i in "${!vars[@]}"; do
        local var="${vars[$i]}" val="${vals[$i]}"
        if grep -qE "^(export )?${var}=" "$env_file"; then
            sed -i -E "s|^(export )?${var}=.*|${var}=\"${val}\"|" "$env_file"
            log "  updated $var in .env"
            updated=1
        fi
    done

    if [[ "$updated" -eq 0 ]]; then
        log "  .env has no LIBVIRT_HOME/STORAGE_POOL_* overrides to update."
    fi
}

update_profile
update_env_file

# -----------------------------------------------------------------------------
# Step 8: optionally purge old data (only after everything above succeeded)
# -----------------------------------------------------------------------------

if [[ "$PURGE_OLD" -eq 1 ]]; then
    log "Purging old pool data (--purge-old)"
    for old_dir in "${OLD_DIRS[@]}"; do
        [[ -d "$old_dir" ]] || continue
        sudo rm -rf "$old_dir"
        log "  removed $old_dir"
    done
else
    log "Old data left in place under: ${OLD_DIRS[*]}"
    log "Once you've confirmed everything works at the new location, remove it manually, e.g.:"
    for old_dir in "${OLD_DIRS[@]}"; do
        echo "  sudo rm -rf \"$old_dir\""
    done
fi

echo
echo "============================================================"
echo "Migration complete."
echo "============================================================"
echo "New LIBVIRT_HOME: $NEW_LIBVIRT_HOME"
echo
echo "Next steps:"
echo "  source /etc/profile.d/sandbox.sh   # or open a new shell"
echo "  ./scripts/85_host_check_libvirt_config.sh"
echo "  ./scripts/50_list_vms.sh"
