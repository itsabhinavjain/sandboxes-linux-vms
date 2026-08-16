## Overall process 

- Layer 5 : Clients : a) Virsh (Vir-install and other shell) b) Virt-Manager c) Cockpit etc 
- Layer 4 : Libvirt 
- Layer 3 : QEMU : Better management of KVM 
- Layer 2 : KVM : Makes Linux Kernel the hypervisor
- Layer 1 : Linux Kernel 

---

- `ubuntu-24.04-live-server-amd64.iso` : ISO Images : Installation DVD - Installer, Packages, Bootloader : Typically requires one to click next etc (Interactive Installation)
- `ubuntu.qcow2`                       : Virtual HardDisk : This is essentially where ubuntu lives (Operating system) - erpnext-demo-01.qcow2 : "The hard drive belonging to my VM."

- `ubuntu.vmdk`                        : VMware Disks 
- `ubuntu.vdi`                         : VirtualBox Disks

- `storage pools` : Are essentially just directories that libvirt has access to. These can be local or remote. 
- a `domain` in libvirt essentially means a VM 

- image : A reusable template from which I create machines.
- snapshot : A saved state of an existing machine at a particular point in time.

- Note we can provision using  
	- CLI         : CLI 
	- vir-manager : GUI 
	- Cockpit     : GUI (Remote) 

```
             IMAGE
               │
               │ used to create
               ▼
        ┌──────────────┐
        │     VM       │
        │              │
        │ CPU          │
        │ RAM          │
        │ Network      │
        │              │
        │ Disk ◄───────┼── image-derived disk
        └──────────────┘
```

---

Cloud images and cloud Init 
- `ubuntu.img`                         : Raw Image (Virtual Disk) : Usually used by Cloud Providers - Template - A starting point for your VM. A cloud image already has operating system pre-installed. 
	- Cloud images are typically bootable, with ubuntu installed and configured for cloud-init
        - Cloud-Init is used to configure a cloud image (First boot configuration system for your VM)
- cloud-init iso ? seed-iso 
```
seed.iso
│
├── user-data
├── meta-data
└── network-config
```

When VM boots, it boots with two disks
```
┌─────────────────────────────────────┐
│          erpnext-demo-01            │
│                                     │
│ CPU: 4                              │
│ RAM: 8 GB                           │
│                                     │
│ Disk 1                              │
│ ┌───────────────────────────────┐   │
│ │ Ubuntu VM disk                │   │
│ │                               │   │
│ │ /etc                          │   │
│ │ /home                         │   │
│ │ /usr                          │   │
│ │ /var                          │   │
│ └───────────────────────────────┘   │
│                                     │
│ Disk 2                              │
│ ┌───────────────────────────────┐   │
│ │ cloud-init seed               │   │
│ │                               │   │
│ │ hostname                      │   │
│ │ SSH key                       │   │
│ │ users                         │   │
│ │ network configuration         │   │
│ └───────────────────────────────┘   │
└─────────────────────────────────────┘
```

```
                  DOWNLOAD ONCE
                       │
                       ▼
            ┌──────────────────────┐
            │ Ubuntu Cloud Image   │
            │                      │
            │ Ubuntu pre-installed │
            └──────────┬───────────┘
                       │
                       │ clone/copy
                       ▼
            ┌──────────────────────┐
            │ VM Disk               │
            │ erpnext-demo-01.qcow2│
            └──────────┬───────────┘
                       │
                       │
          ┌────────────┴────────────┐
          │                         │
          │                         │
          ▼                         ▼
   ┌──────────────┐        ┌──────────────────┐
   │ VM Definition│        │ Cloud-init Seed  │
   │              │        │                  │
   │ CPU: 4       │        │ hostname         │
   │ RAM: 8GB     │        │ user             │
   │ network      │        │ SSH key          │
   │ disks        │        │ network config   │
   └──────┬───────┘        └────────┬─────────┘
          │                         │
          └────────────┬────────────┘
                       ▼
                 ┌───────────┐
                 │    VM     │
                 │           │
                 │  Ubuntu   │
                 │  running  │
                 └───────────┘
```


On first boot :- 
```
Ubuntu boots
     ↓
cloud-init discovers seed
     ↓
reads configuration
     ↓
creates user
     ↓
installs SSH key
     ↓
sets hostname
     ↓
configures network
     ↓
installs packages
     ↓
done
```
After that, the seed disk generally has no ongoing role.


---

Storage pools 

In general 
pool: vm-images
pool: vm-disks
pool: vm-cloudinit
pool: vm-snapshots
pool: iso

export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"       
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"           
export STORAGE_POOL_DISKS="${LIBVIRT_HOME}/disks"         
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"
export STORAGE_POOL_CLOUD_INIT_ISOS="${LIBVIRT_HOME}/cloud-init"


Abhinav chose (2026-08-16, final -- separate cloud-init pool for mental clarity):
export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"              : Will have the cloud images that I have downloaded from the internet. 
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"                  : Will have installer-ISOs (an installer) 
export STORAGE_POOL_DISKS="${LIBVIRT_HOME}/disks"                : Will have the qcow2 disks and yaml specifications 
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"        : Will be used in case we have external snapshots. Right now we are planning internal snapshots only. 
export STORAGE_POOL_CLOUD_INIT_ISOS="${LIBVIRT_HOME}/cloud-init" : Will have seed-ISOs (cloud-init isos - essentially a configuration disk) that I create from cloud-init.

This keeps cloud-init separate from the isos pool for mental clarity:
cloud-init-pool (`STORAGE_POOL_CLOUD_INIT_ISOS`) holds the seed-isos created
from cloud-init and used for configuration; iso-pool (`STORAGE_POOL_ISOS`)
holds actual operating-system installer ISOs (not currently used).

```
VM name = erpnext-demo-01
CPU = 4
RAM = 8 GB
Disk = erpnext-demo-01.qcow2
CD-ROM = erpnext-demo-01-seed.iso
Network = default
```

---


```
validate arguments
        ↓
validate cloud image
        ↓
validate VM name doesn't already exist
        ↓
create VM disk
        ↓
create cloud-init seed
        ↓
define VM
        ↓
configure networking
        ↓
configure autostart
        ↓
start VM
        ↓
wait for guest
        ↓
display IP
``` 

--- 

Snapshots 




## Libvirt Reference
```
sudo virsh list --all                                     # all VMs and their state

sudo virsh dominfo myvm                                   # info about a VM
sudo virsh dumpxml myvm                                   # see/dump the raw VM definition
sudo virsh edit myvm                                      # edit XML (opens in $EDITOR)

sudo virsh start myvm                                     # start a VM
sudo virsh shutdown myvm                                  # graceful shutdown
sudo virsh destroy myvm                                   # force power off (yanks the cord)
sudo virsh reboot myvm                                    # restart the VM 
sudo virsh suspend myvm                                   # suspend the VM 
sudo virsh resume myvm                                    # resume the VM 

virsh undefine ubuntu-test --remove-all-storage --nvram   # removes the vm and frees up all the resources that it ever used 

sudo virsh autostart myvm                                 # enable autostart 
sudo virsh autostart --disable myvm                       # disable autostart 

sudo virsh console myvm                                   # get a serial console (text-only)

sudo virsh save ubuntu-test /tmp/ubuntu-test.state        # save the state of a vm to a state file 
sudo virsh restore /tmp/ubuntu-test.state                 # restore the state 

sudo virsh pool-list --all                                # list storage pools
sudo virsh vol-list default                               # what's in a pool

sudo virsh net-list --all 

sudo virsh snapshot-list myvm                             # list snapshots
sudo virsh snapshot-create-as myvm snap1                  # create snapshot
sudo virsh snapshot-revert myvm snap1                     # revert
sudo virsh snapshot-delete myvm snap1                     # delete snapshot
```
