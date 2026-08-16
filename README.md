# Sandbox - Linux VMs
The repo can be used to quickly have new linux vms provisioned on a Linux host. 
- Step 1 : Make sure that the Linux host has been setup as defined [SETUP.md](./SETUP.md)
- Step 2 : Use the Lifecycle scripts to create and manage the virtual machines

## Requirements on the host machine 
The linux host machine should have various software and environment (system level) setup for the repo to work 

### Environment 
- Libvirt related setup : [SETUP.md](./SETUP.md)
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

## Scripts 
- See [lifecycle.md](./lifecycle.md) for the full contract of each script.
- All scripts live in [`scripts/`](./scripts) and are run from the repo root (e.g. `./scripts/00_init.sh myvm`). Shared helpers are in `scripts/lib/common.sh`.

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

## Notes 
- Naming convention : `vir-ubuntu-01` and then additional numbers. The name should always suggest that it is a virtual machine
- `state.yaml` : Will have the state of the vm and will be kept updated by the scripts. 
- [Logs and Decisions](./LOGS.md)
- [Implmentation Plan and roadmap](./PLAN.md)
- [libvirt reference](./docs/libvirt_reference.md)
