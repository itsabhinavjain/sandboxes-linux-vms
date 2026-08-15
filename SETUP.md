1) Bootstrap script (Setup first time)
2) Configuration script (Setup before running lifecycle scripts)
3) VM lifecycle scripts

`sudo nano /etc/profile.d/sandbox.sh`
```
#!/usr/bin/env bash

export SANDBOX_HOME="${SANDBOX_HOME:-$HOME/sandboxes}"

if mountpoint -q /mnt/extreme_ssd; then
    export STORAGE_POOL_HOME="/mnt/extreme_ssd/libvirt"
else
    unset STORAGE_POOL_HOME
fi

export LIBVIRT_HOME="${STORAGE_POOL_HOME:-$SANDBOX_HOME/libvirt}"

export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"
```
`sudo chmod 644 /etc/profile.d/sandbox.sh`

Bootstrap script 
```
grep "^user" /etc/libvirt/qemu.conf
grep "^group" /etc/libvirt/qemu.conf

sudo chown -R libvirt-qemu:kvm ${LIBVIRT_HOME}
sudo chmod -R 775 ${LIBVIRT_HOME}

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

sudo virsh pool-define-as snapshot-pool dir --target ${STORAGE_POOL_SNAPSHOTS}
sudo virsh pool-autostart snapshot-pool
sudo virsh pool-start snapshot-pool

sudo virsh pool-refresh default
sudo virsh pool-refresh iso-pool
sudo virsh pool-refresh snapshot-pool

sudo virsh pool-list --all

sudo virsh pool-info default
sudo virsh pool-info iso-pool
sudo virsh pool-info snapshot-pool

virsh pool-dumpxml default
virsh pool-dumpxml iso-pool
virsh pool-dumpxml snapshot-poolSETUP.

```
vm Lifecycle scripts can now assume it has 
```
LIBVIRT_HOME
STORAGE_POOL_IMAGES
STORAGE_POOL_ISOS
STORAGE_POOL_SNAPSHOTS
```