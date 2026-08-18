This file mentions the basic setup that is required on the host machine to enable having libvirt based vms. 

1) Install the dependencies that are required
2) Bootstrap script (Setup first time)
3) Configuration script (Setup before running lifecycle scripts)
4) VM lifecycle scripts
5) Check the environment 

## Installing and setting up with dependencies 
```
egrep -c '(vmx|svm)' /proc/cpuinfo
sudo apt install -y cpu-checker
sudo kvm-ok

sudo apt update && sudo apt upgrade -y
sudo apt autoremove --purge -y
sudo apt autoclean -y

sudo apt install -y qemu-kvm 
sudo apt install -y libvirt-daemon-system 
sudo apt install -y libvirt-clients 
sudo apt install -y virtinst 
sudo apt install -y bridge-utils
sudo apt install -y libosinfo-bin
sudo apt install -y virt-top
sudo apt install -y virt-manager
sudo apt install -y genisoimage
sudo apt install -y cloud-image-utils

sudo apt install -y jq

# yq -- used to read/write state.yaml. The `yq` package in apt is NOT
# guaranteed to be mikefarah/yq (Go); install the Go binary explicitly so
# the -i / `.key = "value"` syntax used by lib/common.sh works:
sudo curl -fsSL -o /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
yq --version   # should print "yq (https://github.com/mikefarah/yq/) version ..."

sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER

sudo systemctl enable libvirtd
sudo systemctl start libvirtd

# Log out and back in 
sudo systemctl status libvirtd

groups

sudo virsh list --all
sudo virsh net-list --all
sudo virsh pool-list --all


```

## Bootstrap script
Filename : `sudo nano /etc/profile.d/sandbox.sh`

```
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

```

Change the permissions : `sudo chmod 644 /etc/profile.d/sandbox.sh`

## Configuring Libvirt and the storage pools 

```
grep "^user" /etc/libvirt/qemu.conf
grep "^group" /etc/libvirt/qemu.conf

mkdir -p ${STORAGE_POOL_IMAGES} ${STORAGE_POOL_ISOS} ${STORAGE_POOL_DISKS} ${STORAGE_POOL_SNAPSHOTS} ${STORAGE_POOL_CLOUD_INIT_ISOS}

sudo chown -R libvirt-qemu:kvm ${LIBVIRT_HOME}
sudo chmod -R 775 ${LIBVIRT_HOME}

# setgid on all pool directories: files the lifecycle scripts create (as
# your regular user, no sudo) inherit group `kvm`, so libvirt-qemu (a member
# of kvm) can read/write them without needing to be chown'd afterwards.
sudo find ${LIBVIRT_HOME} -type d -exec chmod g+s {} \;

ls -la ${LIBVIRT_HOME}

sudo virsh pool-list --all
sudo virsh vol-list default
sudo virsh list --all

# Stop and remove the existing default pool definition
sudo virsh pool-destroy default
sudo virsh pool-undefine default

# Define the new default pool on the SSD
sudo virsh pool-define-as default dir --target ${STORAGE_POOL_IMAGES}
sudo virsh pool-autostart default
sudo virsh pool-start default 

sudo virsh pool-define-as iso-pool dir --target ${STORAGE_POOL_ISOS}
sudo virsh pool-autostart iso-pool
sudo virsh pool-start iso-pool

sudo virsh pool-define-as disk-pool dir --target ${STORAGE_POOL_DISKS}
sudo virsh pool-autostart disk-pool
sudo virsh pool-start disk-pool

sudo virsh pool-define-as snapshot-pool dir --target ${STORAGE_POOL_SNAPSHOTS}
sudo virsh pool-autostart snapshot-pool
sudo virsh pool-start snapshot-pool

sudo virsh pool-define-as cloudinit-pool dir --target ${STORAGE_POOL_CLOUD_INIT_ISOS}
sudo virsh pool-autostart cloudinit-pool
sudo virsh pool-start cloudinit-pool

sudo virsh pool-refresh default
sudo virsh pool-refresh iso-pool
sudo virsh pool-refresh disk-pool
sudo virsh pool-refresh snapshot-pool
sudo virsh pool-refresh cloudinit-pool

sudo virsh pool-list --all

sudo virsh pool-info default
sudo virsh pool-info iso-pool
sudo virsh pool-info disk-pool
sudo virsh pool-info snapshot-pool
sudo virsh pool-info cloudinit-pool

virsh pool-dumpxml default
virsh pool-dumpxml iso-pool
virsh pool-dumpxml disk-pool
virsh pool-dumpxml snapshot-pool
virsh pool-dumpxml cloudinit-pool

```

## Checking configurations
```
virt-install --version
cloud-init --version
qemu-img --version
yq --version

virsh -c qemu:///system list --all
virsh -c qemu:///system pool-list --all
virsh -c qemu:///system net-list --all

# Confirm the lifecycle scripts can run without sudo (requires the
# usermod -aG libvirt/kvm above and a fresh login session):
virsh -c qemu:///system list --all

```

vm Lifecycle scripts can now assume it has 
```
LIBVIRT_HOME
STORAGE_POOL_IMAGES
STORAGE_POOL_ISOS
STORAGE_POOL_DISKS
STORAGE_POOL_SNAPSHOTS
STORAGE_POOL_CLOUD_INIT_ISOS
```

This system-level bootstrap is the baseline. If you want per-checkout
overrides (a different storage pool location, different defaults) without
touching `/etc/profile.d/sandbox.sh`, copy [`env.sample`](./env.sample) to
`.env` in the repo root instead -- `scripts/lib/common.sh` loads it
automatically and it takes precedence over the system-level variables set
above. See [README.md](./README.md#requirements-for-the-repo) for the full
precedence order.

## Download the cloud img 
```
curl -fsSL -o "$STORAGE_POOL_IMAGES/noble-server-cloudimg-amd64.img" \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

## TAILSCALE 
1) Reusable + ephemeral auth key → TAILSCALE_AUTHKEY
Go to https://login.tailscale.com/admin/settings/keys
1. Click "Generate auth key..."
2. Description: something like sandboxes-linux-vms fleet
3. Toggle Reusable on
4. Toggle Ephemeral on
5. Under Tags, select tag:dmz-ephemeral
6. Set expiry (90 days is the max for a reusable key) — this is your rotation reminder
7. Click Generate key, copy the value immediately (it's shown once, starts tskey-auth-...)

2) OAuth client → TAILSCALE_API_CLIENT_ID / TAILSCALE_API_CLIENT_SECRET
Go to https://login.tailscale.com/admin/settings/oauth
1. Click "Generate OAuth client..."
2. Description: something like sandboxes-linux-vms destroy cleanup
3. Under Scopes, select only Devices → Core, and make sure it's set to Write (not read-only — deleting a device needs write)
4. Under Tags, restrict this client to tag:dmz-ephemeral only — this is what guarantees the credential can't touch anything else on your tailnet
5. Click Generate client, copy both the Client ID and Client Secret immediately (the secret is shown once)

Once you have all three values, you can either paste them here and I'll write them into .env for you, or add them yourself:

TAILSCALE_AUTHKEY="tskey-auth-..."
TAILSCALE_API_CLIENT_ID="..."
TAILSCALE_API_CLIENT_SECRET="..."

