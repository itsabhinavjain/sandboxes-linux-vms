# Sandbox - Linux VMs
- Option 1 : Using the ISO Images (Installer, Packages, Bootloader)
- Option 2 (Choosing this): Using Cloud Images (`.img` files). Use base images here. 

- Naming convention : `vir-ubuntu-01` and then additional numbers 
- `state.yaml` : Will have the state of the vm and will be kept updated by the scripts. 

## Scripts 
All scripts live in [`scripts/`](./scripts) and are run from the repo root
(e.g. `./scripts/00_init.sh myvm`). Shared helpers are in `scripts/lib/common.sh`.
See [lifecycle.md](./lifecycle.md) for the full contract of each script.

### Sandbox Lifecycle Scripts 
- `scripts/00_init.sh`              # Helps in setting up the hostname etc. It should check that the same name is not currently in use. It should also ask for specifications (with defaults) for RAM, CPU, Disk Size etc 
- `scripts/01_start.sh`             # Starts the VM 
- `scripts/02_stop.sh`
- `scripts/03_reboot.sh`
- `scripts/04_resume.sh`
- `scripts/05_destroy.sh`
- `scripts/08_status.sh`            # Gives the status and info 
- `scripts/09_doctor.sh`            # Runs diagnostic tests 
- Configuration (not yet built, see PLAN.md Phase 6)
    - `scripts/11_configure-automated.sh`
    - `scripts/12_configure-manual.sh`
- Snapshots (not yet built, see PLAN.md Phase 6)
    - `scripts/21_snapshot.sh`
    - `scripts/22_revert.sh`


### Managing Sandboxes 
- `scripts/list_vms.sh`             # Will list all the vms and their statuses
- `scripts/info_vms.sh`             # Will list the IP address etc 


## Environment 

### Environment 
- Libvirt related : check [SETUP.md](./SETUP.md)
- Cockpit for web based gui

### Environment variables 
- Libvirt should be setup in a way that the following directories should be setup as storage pools 

```
export SANDBOX_HOME="${SANDBOX_HOME:-$HOME/projects}"
export LIBVIRT_HOME="${STORAGE_POOL_HOME:-$SANDBOX_HOME/libvirt}"
export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"
export STORAGE_POOL_DISKS="${LIBVIRT_HOME}/disks"
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"
export DEFAULT_CLOUD_IMG = "noble-server-cloudimg-amd64"
```

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
