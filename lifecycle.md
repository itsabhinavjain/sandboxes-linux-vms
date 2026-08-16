# Lifecycle scripts

All scripts live in `scripts/` and are run from the repo root (e.g.
`./scripts/00_init.sh myvm`). Each takes a `<vmname>` as its first argument
unless noted, and sources `scripts/lib/common.sh`. None require `sudo` (see
SETUP.md / PLAN.md for why). State is tracked per-VM in
`${STORAGE_POOL_DISKS}/<vmname>.state.yaml`.

## Sandbox lifecycle

### `scripts/00_init.sh <vmname> [--ram N] [--vcpus N] [--disk N] [--image NAME] [--autostart|--no-autostart]`
Defines a new VM without starting it. Validates the name isn't already in
use, creates a qcow2 overlay disk (backed by the base cloud image) in
`STORAGE_POOL_DISKS`, renders the cloud-init templates and builds the seed
ISO, then defines the libvirt domain (`virsh define`, no boot). Writes
`<vmname>.state.yaml` with `status: defined`. Rolls back any partially
created files if a step fails.

`--autostart` sets the libvirt autostart flag, so the VM is started
automatically whenever `libvirtd` starts (e.g. after a host reboot) --
independent of whatever state the VM was in before. Defaults to
`DEFAULT_AUTOSTART` (or `false` if that's unset). This is a static
per-domain flag, not "remember and resume the VM's last state."

### `scripts/01_start.sh <vmname>`
Starts a defined (or stopped) VM. Updates state to `status: running`.

### `scripts/02_stop.sh <vmname> [--force]`
Gracefully shuts the VM down (ACPI). With `--force`, hard-powers it off
instead. Updates state to `status: stopped`.

### `scripts/03_reboot.sh <vmname>`
Reboots a running VM in place.

### `scripts/04_resume.sh <vmname>`
Resumes a suspended VM.

### `scripts/05_destroy.sh <vmname> [--force]`
Permanently deletes the VM: force-stops if running, undefines the libvirt
domain and its storage, removes the qcow2/seed/state files, and prints a
reminder to run `ssh-keygen -R <vmname>.<tailnet>` on any machine that has
SSH'd into it. Prompts for confirmation unless `--force` is given.

### `scripts/08_status.sh <vmname>`
Shows `virsh dominfo` merged with the state file contents, plus the
Tailscale SSH hint (`<vmname>.<tailnet>.ts.net`).

### `scripts/09_doctor.sh`
No vmname argument -- host-level diagnostics. Checks KVM support
(`kvm-ok`), `libvirtd` is active, the four storage pools exist and are
correctly permissioned/setgid, and required binaries
(`virt-install`, `cloud-localds`, `qemu-img`, `yq`) are present.

## Configuration (Phase 6, not yet built)

### `scripts/11_configure-automated.sh <vmname>`
Re-applies an updated `setup_config/user-data.tmpl` to an existing VM by
rebuilding and swapping its cloud-init seed ISO.

### `scripts/12_configure-manual.sh <vmname>`
Drops into `virsh console` (or prints the SSH command) for manual,
one-off changes.

## Snapshots (Phase 6, not yet built)

### `scripts/21_snapshot.sh <vmname> [snapshot-name]`
### `scripts/22_revert.sh <vmname> <snapshot-name>`

Whether these use internal qcow2 snapshots (simple, no `STORAGE_POOL_SNAPSHOTS`
use) or external ones (`--disk-only`, backed by `STORAGE_POOL_SNAPSHOTS`) is
an open decision -- see PLAN.md.

## Managing sandboxes

### `scripts/list_vms.sh`
Scans `STORAGE_POOL_DISKS/*.state.yaml`, cross-references live status from
`virsh list --all`, and prints a table of all managed VMs.

### `scripts/info_vms.sh <vmname>`
Prints the state file contents and the Tailscale SSH hint for one VM.
