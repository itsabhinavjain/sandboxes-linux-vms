# Lifecycle scripts

All scripts live in `scripts/` and are run from the repo root (e.g.
`./scripts/00_init_vm-automated.sh myvm`). Each takes a `<vmname>` as its
first argument unless noted, and sources `scripts/lib/common.sh`. None
require `sudo` (see SETUP.md / PLAN.md for why). State is tracked per-VM in
`${STORAGE_POOL_DISKS}/<vmname>.state.yaml`.

Naming convention: single-VM scripts are numbered `00`-`08` and suffixed
`_vm.sh`; fleet-wide scripts (operate across all VMs on the host) are
numbered `50`+ and suffixed `_vms.sh`. `09_doctor.sh` is host-level
diagnostics with no VM involved, so it carries neither suffix. Scripts that
have both a non-interactive and an interactive variant carry a
`-automated`/`-interactive` suffix after `_vm` (e.g. `00_init_vm-automated.sh`
/ `00_init_vm-interactive.sh`).

`scripts/lib/common.sh` also loads `.env` from the repo root (if present)
before any script logic runs. Environment variables resolve lowest to
highest priority: system-level env vars < `.env` < flags passed to the
script. See [README.md](./README.md#requirements-for-the-repo) and
[env.sample](./env.sample).

## Sandbox lifecycle

### `scripts/00_init_vm-automated.sh <vmname> [--ram N] [--vcpus N] [--disk N] [--image NAME] [--os-variant VARIANT] [--autostart|--no-autostart]`
Defines a new VM without starting it. Validates the name isn't already in
use, creates a qcow2 overlay disk (backed by the base cloud image) in
`STORAGE_POOL_DISKS`, renders the cloud-init templates and builds the seed
ISO in `STORAGE_POOL_CLOUD_INIT_ISOS`, then defines the libvirt domain
(`virsh define`, no boot). Writes
`<vmname>.state.yaml` with `status: defined`. Rolls back any partially
created files if a step fails.

`--autostart` sets the libvirt autostart flag, so the VM is started
automatically whenever `libvirtd` starts (e.g. after a host reboot) --
independent of whatever state the VM was in before. Defaults to
`DEFAULT_AUTOSTART` (or `false` if that's unset). This is a static
per-domain flag, not "remember and resume the VM's last state."

### `scripts/00_init_vm-interactive.sh`
Interactive counterpart to `00_init_vm-automated.sh`. Takes no arguments --
prompts for the VM name (validated, and checked against existing VMs) and
shape (RAM, vCPUs, disk, base image, OS variant, autostart), showing each
`DEFAULT_*` env var as the default, then execs into
`00_init_vm-automated.sh` with the collected values as flags. Owns no
disk/domain-creation logic of its own.

### `scripts/01_start_vm.sh <vmname>`
Starts a defined (or stopped) VM. Updates state to `status: running`.

### `scripts/02_stop_vm.sh <vmname> [--force]`
Gracefully shuts the VM down (ACPI). With `--force`, hard-powers it off
instead. Updates state to `status: stopped`.

### `scripts/03_reboot_vm.sh <vmname>`
Reboots a running VM in place.

### `scripts/05_destroy_vm.sh <vmname> [--force]`
Permanently deletes the VM: force-stops if running, undefines the libvirt
domain and its storage, removes the qcow2/seed/state files, and prints a
reminder to run `ssh-keygen -R <vmname>.<tailnet>` on any machine that has
SSH'd into it. Prompts for confirmation unless `--force` is given.

### `scripts/08_status_vm.sh <vmname>`
Shows `virsh dominfo` merged with the state file contents, plus the
Tailscale SSH hint (`<vmname>.<tailnet>.ts.net`).

### `scripts/09_doctor.sh`
No vmname argument -- host-level diagnostics. Checks KVM support
(`kvm-ok`), `libvirtd` is active, the five storage pools exist and are
correctly permissioned/setgid, and required binaries
(`virt-install`, `cloud-localds`, `qemu-img`, `yq`) are present.

## Configuration

Both configuration scripts share the same end state (VM joined to the
tailnet, UFW locked down to `tailscale0`-only), the same flags, and the same
SSH/remote-step-script machinery, factored into
`scripts/lib/configure_steps.sh`. They differ only in how each step is
triggered: the `-automated` variant runs every step unconditionally
(fire-and-forget), while the `-interactive` variant confirms before each
step and streams its output live. Both refuse
to enable UFW unless `tailscale0` is confirmed up first, to avoid locking
out SSH with no fallback besides `virsh console`. Both are
re-runnable/idempotent -- this is how you change network/firewall config on
an existing VM, since cloud-init only runs once (`00_init_vm-automated.sh`
disables it after first boot) -- and both record `.tailscale`/`.ufw` status
in the VM's state file.

### `scripts/11_configure_vm-automated.sh <vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]`
Fire-and-forget: joins the VM to the tailnet (`tailscale up`, needs
`TAILSCALE_AUTHKEY` in `.env` or `--authkey`) and enables UFW, running every
step unconditionally with no prompts. Idempotency comes from the remote
steps themselves (e.g. `install_tailscale` checks `command -v tailscale`
first; the `ufw allow` rule is safe to repeat). Useful for chaining after
`01_start_vm.sh` in a script, or reconfiguring a VM without babysitting it.

### `scripts/11_configure_vm-interactive.sh <vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]`
Interactive counterpart to `11_configure_vm-automated.sh`: confirms before each step (install
Tailscale, `tailscale up`, enable UFW) and runs it over `ssh -tt` (real pty)
so output streams live instead of running unattended. Useful for configuring
a new base image for the first time, or debugging why Tailscale/UFW isn't
coming up cleanly. Declining a step isn't an error -- `.tailscale`/`.ufw` in
the state file record `up`/`enabled` only for steps actually confirmed and
run, `skipped` otherwise.

## Snapshots (Phase 6, not yet built)

### `scripts/21_snapshot_vm.sh <vmname> [snapshot-name]`
### `scripts/22_revert_vm.sh <vmname> <snapshot-name>`

Whether these use internal qcow2 snapshots (simple, no `STORAGE_POOL_SNAPSHOTS`
use) or external ones (`--disk-only`, backed by `STORAGE_POOL_SNAPSHOTS`) is
an open decision -- see PLAN.md.

## Managing sandboxes

### `scripts/50_list_vms.sh`
Scans `STORAGE_POOL_DISKS/*.state.yaml`, cross-references live status from
`virsh list --all`, and prints a table of all managed VMs.

### `scripts/51_info_vms.sh`
Prints the full state file contents and the Tailscale SSH hint for every
managed VM (no `<vmname>` argument -- loops over all `*.state.yaml` files in
`STORAGE_POOL_DISKS`, same as `50_list_vms.sh`). For a single VM's detail
plus its full `virsh dominfo`, use `08_status_vm.sh <vmname>` instead.
