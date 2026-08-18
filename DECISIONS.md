## Decisions I have taken 
There are multiple ways of designing the system. In this file I am writing the various architectural design decisions that I have taken. 


*Rules for developing scripts*
- Developing scripts 
    - `set -euo pipefail` in every script.
    - Always call `virsh` through the `VIRSH=(virsh -c qemu:///system)` array wrapper, never bare/sudo `virsh` — scripts rely on `libvirt`/`kvm` group membership + setgid pool dirs, not sudo.
    - Never pipe `virsh` output directly into `grep -q`/`grep -qx` under `pipefail` (SIGPIPE race) — capture to a variable first, then `grep <<< "$var"`. This bug was found and fixed in three places; don't reintroduce it.
    - `yq` means the mikefarah/yq Go binary (installed manually per `SETUP.md`), not the apt-packaged Python kislyuk/yq — the `-i` in-place edit and `.key = "value"` syntax requires the Go version.

- scripts/lib/common.sh contract
    - Loads/validates env vars, fails fast if `STORAGE_POOL_*` unset.
    - `VIRSH="virsh -c qemu:///system"` wrapper — always use this, never bare
    `virsh` or `sudo virsh`.
    - Path helpers: `disk_path <vmname>`, `seed_path <vmname>`,
    `state_path <vmname>`.
    - State helpers (wrap `yq`): `state_init`, `state_get`, `state_set`
    (quoted/string values), `state_set_raw` (unquoted values, e.g. numbers —
    matches how `state_init` writes `ram_mb`/`vcpus`/`disk_gb`).
    - `vm_exists`, `vm_is_running`.
    - `validate_vmname` — enforces `^[a-zA-Z0-9_-]+$`, called at the top of any
    script taking a vmname argument.
    - `log`, `die`, `confirm` (yes/no prompt, honors a `--force`/`-y` flag).


*Gotchas / intentional decisions — don't "fix" these*

- `11_configure_vm-automated.sh` and `11_configure_vm-interactive.sh` share their SSH/remote-step-script logic via `scripts/lib/configure_steps.sh` — they differ only in whether each step runs unconditionally (`-automated`) or behind a `confirm()` prompt (`-interactive`). Don't duplicate that logic back into either script.
- Cloud-init runs once only — `00_init_vm-automated.sh` disables it after first boot, so template changes only affect newly-created VMs. Post-boot changes (Tailscale, UFW) go through `11_configure_vm-automated.sh`/`11_configure_vm-interactive.sh`.
- UFW is only ever enabled after `tailscale0` is confirmed up, specifically to avoid an SSH lockout with no fallback but `virsh console`.
- Networking is default libvirt NAT + Tailscale (not Tailscale SSH) for reachability at `<vmname>.<tailnet>.ts.net`. Bridged networking is explicitly deferred. `setup_config/network-config.tmpl` exists but is intentionally unused.
- `setup_config/user-data.tmpl` hardcodes user `abhinav`, three specific SSH keys, and timezone `Asia/Kolkata` — intentionally not parameterized beyond `${VMNAME}`.
- SSH-into-VM and `11_configure_vm-interactive.sh` are flagged in `PLAN.md` as unverified end-to-end — treat as "believed correct but unverified." The 2026-08-18 rename/split (`00_init_vm-interactive.sh`, `11_configure_vm-automated.sh` real implementation, shared `lib/configure_steps.sh`, and folding `12_configure_vm-interactive.sh` into `11_configure_vm-interactive.sh` so both configure scripts share number `11`) is likewise unverified against a real host — see `PLAN.md` design decision #13.
- There's no pause/resume script (`04_resume_vm.sh` was deleted 2026-08-18) — nothing in this toolkit calls `virsh suspend`, so it was dead code. Don't add it back without an actual pause use case.
- `12_resize_vm-automated.sh` and `12_resize_vm-interactive.sh` share their stop/apply/start logic via `scripts/lib/resize_steps.sh`, same split pattern as `configure_steps.sh` — don't duplicate that logic back into either script. RAM/vCPU resizing always goes through `virsh set{maxmem,vcpus} --config` while the VM is stopped, never a live hotplug — `virt-install` defines memory/vcpus as a single current==max value with no separate live ceiling, so there's nothing to hotplug into; a `--config` edit only takes effect on next boot anyway. Disk resize is grow-only (`qemu-img resize`) — shrinking a qcow2 can destroy data past the new boundary and needs an in-guest filesystem shrink first, which this toolkit doesn't attempt. Don't add live/hotplug resize or disk shrink without an actual need for it.

*Decision : Storage Pools*
- Moved from a 4 pool system to a 5 pool system 

```
export STORAGE_POOL_IMAGES="${LIBVIRT_HOME}/images"              : Will have the cloud images that I have downloaded from the internet. 
export STORAGE_POOL_ISOS="${LIBVIRT_HOME}/isos"                  : Will have installer-ISOs (an installer). this is not being used right now. Currently we are working with cloud images. 
export STORAGE_POOL_DISKS="${LIBVIRT_HOME}/disks"                : Will have the qcow2 disks and yaml specifications 
export STORAGE_POOL_SNAPSHOTS="${LIBVIRT_HOME}/snapshots"        : Will be used in case we have external snapshots. Right now we are planning internal snapshots only. 
export STORAGE_POOL_CLOUD_INIT_ISOS="${LIBVIRT_HOME}/cloud-init" : Will have seed-ISOs (cloud-init isos - essentially a configuration disk) that I create from cloud-init. 
```

*Decision : Managing Cloud Images*
Operational rule : Treat the base cloud images as immutable.

```
                  GOLDEN IMAGES
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
     Ubuntu         Ubuntu         Rocky
      24.04          22.04           9
        │
        ├──────────────┐
        ▼              ▼
   VM overlay      VM overlay
        │              │
        ▼              ▼
 erpnext-demo-01   odoo-demo-01

```

*Decision : Networking*
- Try to connect the VM directly to Tailnet. (Simple and preferred)
    - Tailscale SSH : I dont want to use Tailscale ssh. This is so that I am not unknowingly get locked out of my machine because of Tailscale configurations. Use normal ssh port exposed over the tailscale network
    - Inside the VM, setup the UFW rules so that the ports are exposed only on Tailnet. Enable UFW rules once you are sure that the machine is accessible using Tailscale. 
    - The VM should be approachable using `virsh console` from the linux host in case it is required for debugging purposes. 
- Alternate way could be to connect using host and subrouter. Dont do this yet, unless required to bypass company firewalls. 

*Decision : Cloud-init and indempotent configuration scripts*
- Cloud-Init : 
    - Setting up hostname and timezone 
    - Non root sudo user `abhinav`
        - ssh keys added 
        - adding to groups 
    - Disable root login 
    - Disable login using password (only through keys) 
    - Setup updates, upgrades, unattended updates
    - Install and enable `qemu-guest-agent` 
- Separate Indempotent Script : 
    - Tailscale
    - UFW 
    - Docker (moved out of cloud-init 2026-08-18 -- cloud-init only runs
      once at first boot, so a VM created before Docker existed, or before a
      Docker version bump, had no way to pick it up; `11_configure_vm-*`
      already re-runs safely, so Docker installation lives there now,
      idempotent via `command -v docker`, gated by `--skip-docker`)

*Decision : qemu-guest-agent channel is new-VMs-only*
`qemu-guest-agent` needs two things to actually work: the package running in
the guest (cloud-init, see above) and a virtio-serial channel device on the
libvirt domain XML (`--channel unix,target_type=virtio,name=org.qemu.guest_agent.0`
on the `virt-install` call in `00_init_vm-automated.sh`) for the guest agent
to connect to. The channel is only set at domain-definition time, so this
only takes effect for VMs created after this change -- existing
already-defined VMs won't get `virsh domifaddr --source agent` etc. working
retroactively without being recreated or having the device attached to
their XML by hand. Not worth automating a retrofit path for a personal
sandbox tool.

*Decision : Autostart settings*
The VMs can be setup so that they autostart when the host linux machine restarts. This is now managed in this repo. 

*Decision : Snapshots - have internal snapshots*
Internal vs. external qcow2 snapshots

Internal snapshots live inside the same qcow2 file as the disk itself. virsh snapshot-create-as vm snap1 adds a snapshot point to vmname.qcow2 directly — no new file, no path changes. Revert (virsh snapshot-revert) and delete are single-file operations libvirt handles atomically.

External snapshots create a new qcow2 file as an overlay (vmname.snap1.qcow2), with the current disk becoming a read-only backing file underneath it. The VM's active disk switches to the new overlay file. This is what STORAGE_POOL_SNAPSHOTS was set up to hold.

Trade-offs:

┌─────────────────────────┬──────────────────────────────────────────────────────┬────────────────────────────────────────────────┐
│                         │                       Internal                       │                    External                    │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ File management         │ One file, simple                                     │ New file per snapshot, chain grows             │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ Revert                  │ virsh snapshot-revert, clean                         │ Needs blockcommit/blockpull or manual XML      │
│                         │                                                      │ repointing — more fragile in libvirt           │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│                         │ Yes — disk_path()/state.yaml/04_destroy_vm.sh all       │ No — the "active disk" changes after every     │
│ Fits our scripts        │ assume exactly one qcow2 per VM, unchanged           │ snapshot, which breaks that assumption         │
│                         │                                                      │ throughout common.sh                           │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ Uses                    │ No (stays empty)                                     │ Yes                                            │
│ STORAGE_POOL_SNAPSHOTS  │                                                      │                                                │
├─────────────────────────┼──────────────────────────────────────────────────────┼────────────────────────────────────────────────┤
│ Good for                │ Occasional "snapshot before I break this, revert if  │ Portable/prunable backup-style snapshot chains │
│                         │ needed"                                              │                                                │
└─────────────────────────┴──────────────────────────────────────────────────────┴────────────────────────────────────────────────┘

My recommendation: internal. This is a personal sandbox tool, not a backup system — the actual need is "try something risky, revert if it goes wrong," and internal snapshots handle that with far less code and no changes to the disk-path assumptions baked into every script so far. STORAGE_POOL_SNAPSHOTS stays defined but unused for now; I'd note that in the docs rather than rip out the pool, in case external snapshots become worth it later. Happy to build it out this way when we get to Phase 6 — say the word.

*Decision : Use Linux Cloud Images instead of provisioning it from ISO images*
- Option 1 : Using the ISO Images (Installer, Packages, Bootloader)
- Option 2 (Choosing this): Using Cloud Images (`.img` files). Use base images here. 

*Decision : Individual state files and not a global registry*
**state.yaml scope:** per-VM state file living next to that VM's disk in
   the disk pool — NOT a single global registry. `50_list_vms.sh` aggregates by
   scanning the disk pool directory.



*Directory Structure* 
## Directory structure (actual)

All scripts live under `scripts/`, run from the repo root
(e.g. `./scripts/00_init_vm-automated.sh myvm`).

```
scripts/
  lib/
    common.sh              # sourced by every numbered script
    configure_steps.sh     # shared by 11_configure_vm-automated/-interactive.sh -- see design decision #13
    resize_steps.sh        # shared by 12_resize_vm-automated/-interactive.sh
  00_init_vm-automated.sh
  00_init_vm-interactive.sh
  01_start_vm.sh
  02_stop_vm.sh
  03_reboot_vm.sh
  04_destroy_vm.sh
  05_status_vm.sh
  08_test.sh                     # see PLAN.md design decision #14
  09_doctor.sh
  50_list_vms.sh
  51_info_vms.sh
  11_configure_vm-automated.sh   # see PLAN.md design decision #13
  11_configure_vm-interactive.sh
  12_resize_vm-automated.sh
  12_resize_vm-interactive.sh
  21_snapshot_vm.sh              # Phase 6, not built yet
  22_revert_vm.sh                # Phase 6, not built yet
setup_config/
  meta-data.tmpl
  network-config.tmpl    # left unused for now (DHCP default)
  user-data.tmpl
env.sample
SETUP.md                    # updated with setgid + yq
lifecycle.md                # filled in with per-script contracts
```