# Sandbox - Linux VMs
This is an opionated repo that can be used to provision a fleet of VMs on a linux host machine using libvirt. 
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

Storage pools
```
- `images/` → pool `default` — read-only golden cloud `.img` files. Never modify the base image directly; VMs are qcow2 overlays.
- `isos/` → pool `iso-pool` — reserved for installer ISOs, currently unused (cloud-image flow only).
- `disks/` → pool `disk-pool` — flat, per-VM `<vmname>.qcow2` + `<vmname>.state.yaml`.
- `snapshots/` → pool `snapshot-pool` — reserved for *external* snapshots; currently unused (internal qcow2 snapshots were chosen instead — don't build external-snapshot logic without revisiting this decision).
- `cloud-init/` → pool `cloudinit-pool` — generated seed ISOs `<vmname>-seed.iso`.
```


Each VM would have a yaml file that would contain details of the VM. The same yaml files are used to check if there is already existing VM with the same name (during initialisation). The libvirt folder on the host would look broadly something like the following :-
```
├── libvirt
│   ├── cloud-init
│   │   ├── vir-testing-001-seed.iso
│   │   └── vir-testing-002-seed.iso
│   ├── disks
│   │   ├── vir-testing-001.qcow2
│   │   ├── vir-testing-001.state.yaml
│   │   ├── vir-testing-002.qcow2
│   │   └── vir-testing-002.state.yaml
│   ├── images
│   │   └── noble-server-cloudimg-amd64.img
│   ├── isos
│   └── snapshots
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

### Sandbox Lifecycle Scripts (Summary) 
```
# For a paricular VM 
- Init (choose one)
    - `scripts/00_init_vm-automated.sh`    # Flag/env-driven: RAM, CPU, disk size etc. all have defaults, override with flags
    - `scripts/00_init_vm-interactive.sh`  # Prompts for VM name and shape (RAM, CPU, disk size etc., with defaults), then hands off to the automated script
- `scripts/01_start_vm.sh`             # Starts the VM 
- `scripts/02_stop_vm.sh`
- `scripts/03_reboot_vm.sh`
- `scripts/04_destroy_vm.sh`
- `scripts/05_status_vm.sh`            # Gives the status and info 
- Configuration (choose one)
    - `scripts/11_configure_vm-automated.sh`    # Fire-and-forget: runs every step unconditionally, no prompts
    - `scripts/11_configure_vm-interactive.sh`  # Confirms before each step, streams output live
- Snapshots (not yet built, see PLAN.md Phase 6)
    - `scripts/21_snapshot_vm.sh`
    - `scripts/22_restore_vm.sh`

# Testing setups 
- `scripts/09_doctor.sh`               # Runs diagnostic tests 
- `scripts/08_test.sh`                 # End-to-end smoke test: doctor -> init -> lifecycle -> destroy, against ephemeral test VMs

# Managing multiple VMs (Managing the fleet)
- `scripts/50_list_vms.sh`             # Will list all the vms and their statuses
- `scripts/51_info_vms.sh`             # Dumps full state.yaml detail for every VM (no vmname arg) 
```

## Notes 
- Naming convention of virtual machines : 
    - `vir-ubuntu-01` and then additional numbers. The name should always suggest that it is a virtual machine

## References
- Usage 
    - [Linux host setup](./SETUP.md) 
    - [Lifecycle scripts](./lifecycle.md)
- Development 
    - [Implmentation Plan, Roadmap and Implentation Logs](./PLAN.md) : Mentions the various additional things that I can implement in this repo 
    - [Design Decisions and Policies](./DECISIONS.md)
- Additional Documentation 
    - [libvirt reference](./docs/libvirt_reference.md)
