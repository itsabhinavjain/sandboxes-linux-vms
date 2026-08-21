#!/usr/bin/env bash
set -euo pipefail

PROFILE_FILE="/etc/profile.d/sandbox.sh"

cat > /tmp/sandbox.sh <<'EOF'
#!/usr/bin/env bash

export SANDBOX_HOME="${SANDBOX_HOME:-$HOME/projects}"

if mountpoint -q /mnt/extreme_ssd; then
    export STORAGE_POOL_HOME="/mnt/extreme_ssd/libvirt"
else
    unset STORAGE_POOL_HOME
fi

export LIBVIRT_HOME="${STORAGE_POOL_HOME:-$SANDBOX_HOME/libvirt}"

export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"
export STORAGE_POOL_DISKS="${LIBVIRT_HOME}/disks"
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"
export STORAGE_POOL_CLOUD_INIT_ISOS="${LIBVIRT_HOME}/cloud-init"

export DEFAULT_CLOUD_IMG="noble-server-cloudimg-amd64"
export DEFAULT_OS_VARIANT="ubuntu24.04"
export DEFAULT_RAM_MB="2048"
export DEFAULT_VCPUS="2"
export DEFAULT_DISK_GB="20"

export DEFAULT_AUTOSTART="false"

# Used for SSH connection hints (vmname.<tailnet>.ts.net) and the
# ssh-keygen -R reminder printed by 04_destroy_vm.sh. Set this to your tailnet
# name, e.g. "tailnet-name.ts.net" or leave unset if you don't use Tailscale.
export TAILSCALE_TAILNET=""
EOF

sudo install -m 644 /tmp/sandbox.sh "$PROFILE_FILE"
rm -f /tmp/sandbox.sh


echo 
echo 
echo "Installed $PROFILE_FILE"
echo "Please : source /etc/profile.d/sandbox.sh" 
echo "Please make sure that we dont run this as sudo since the script uses HOME and USER to setup the environment variables. If you run this as sudo, it will setup the environment variables for root user and not for the current user." 