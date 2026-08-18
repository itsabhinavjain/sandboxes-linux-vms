# Sandbox - Linux VMs
The repo can be used to quickly have new linux vms provisioned on a Linux host. 
- Step 1 : Make sure that the Linux host has been setup as defined [SETUP.md](./SETUP.md)
    - You might want to run the doctor script to check if the host and the environment variables have been set up properly. 
- Step 2 : Use the Lifecycle scripts to create and manage the virtual machines

## Requirements on the host machine 
The linux host machine should have various software and environment (system level) setup for the repo to work 

### Environment (Host machine - System level)
- Libvirt related setup : [SETUP.md](./SETUP.md)
- Cockpit for web based gui

### Environment variables (Host machine - System level)
- Libvirt should be setup in a way that the following directories should be setup as storage pools 

```
export SANDBOX_HOME="${SANDBOX_HOME:-$HOME/projects}"
export LIBVIRT_HOME="${STORAGE_POOL_HOME:-$SANDBOX_HOME/libvirt}"
export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"
export STORAGE_POOL_DISKS="${LIBVIRT_HOME}/disks"
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"
export STORAGE_POOL_CLOUD_INIT_ISOS="${LIBVIRT_HOME}/cloud-init"
export DEFAULT_CLOUD_IMG="noble-server-cloudimg-amd64"
```

## Requirements for the repo 
- Copy [`env.sample`](./env.sample) to `.env` in the repo root and uncomment/edit whatever you want to override: `cp env.sample .env`
- Environment variables are resolved with the following precedence, lowest to highest:
  1. System-level environment variables (see above)
  2. `.env` in the repo root, if present -- overrides #1
  3. Parameters passed to a script (e.g. `--ram` on `00_init_vm-automated.sh`) -- overrides both #1 and #2
- `.env` is gitignored, so host- or checkout-specific overrides never get committed
- `scripts/lib/common.sh` loads `.env` automatically (every script sources `common.sh`); nothing else to run

## Scripts 
- See [lifecycle.md](./lifecycle.md) for the full contract of each script.
- All scripts live in [`scripts/`](./scripts) and are run from the repo root (e.g. `./scripts/00_init_vm-automated.sh myvm`). Shared helpers are in `scripts/lib/common.sh`.
- Naming convention: scripts that operate on a single VM (`<vmname>` as the first argument) are numbered `00`-`08` and suffixed `_vm.sh`. Scripts that operate across all VMs on the host are numbered `50`+ and suffixed `_vms.sh`. `09_doctor.sh` is host-level (no VM involved at all), so it carries neither suffix. Scripts that have both a non-interactive and an interactive variant carry a `-automated`/`-interactive` suffix after `_vm` (e.g. `00_init_vm-automated.sh` / `00_init_vm-interactive.sh`).

### Sandbox Lifecycle Scripts 
- Init (choose one)
    - `scripts/00_init_vm-automated.sh`    # Flag/env-driven: RAM, CPU, disk size etc. all have defaults, override with flags
    - `scripts/00_init_vm-interactive.sh`  # Prompts for VM name and shape (RAM, CPU, disk size etc., with defaults), then hands off to the automated script
- `scripts/01_start_vm.sh`             # Starts the VM 
- `scripts/02_stop_vm.sh`
- `scripts/03_reboot_vm.sh`
- `scripts/05_destroy_vm.sh`
- `scripts/08_status_vm.sh`            # Gives the status and info 
- `scripts/09_doctor.sh`               # Runs diagnostic tests 
- Configuration (choose one)
    - `scripts/11_configure_vm-automated.sh`    # Fire-and-forget: runs every step unconditionally, no prompts
    - `scripts/11_configure_vm-interactive.sh`  # Confirms before each step, streams output live
- Snapshots (not yet built, see PLAN.md Phase 6)
    - `scripts/21_snapshot_vm.sh`
    - `scripts/22_restore_vm.sh`

### Managing Sandboxes 
- `scripts/50_list_vms.sh`             # Will list all the vms and their statuses
- `scripts/51_info_vms.sh`             # Dumps full state.yaml detail for every VM (no vmname arg) 

## Notes 
- Naming convention : `vir-ubuntu-01` and then additional numbers. The name should always suggest that it is a virtual machine
- `state.yaml` : Will have the state of the vm and will be kept updated by the scripts. 
- [Logs and Decisions](./LOGS.md)
- [Implmentation Plan and roadmap](./PLAN.md)
- [libvirt reference](./docs/libvirt_reference.md)
