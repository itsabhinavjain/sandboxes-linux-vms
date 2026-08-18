# Lifecycle scripts

All scripts live in `scripts/` and are run from the repo root (e.g.
`./scripts/00_init_vm-automated.sh myvm`). Each takes a `<vmname>` as its
first argument unless noted, and sources `scripts/lib/common.sh`. None
require `sudo` (see SETUP.md / PLAN.md for why). State is tracked per-VM in
`${STORAGE_POOL_DISKS}/<vmname>.state.yaml`.

Naming convention: single-VM scripts are numbered `00`-`05` and suffixed
`_vm.sh`; fleet-wide scripts (operate across all VMs on the host) are
numbered `50`+ and suffixed `_vms.sh`. `09_doctor.sh` is host-level
diagnostics with no VM involved, so it carries neither suffix. `08_test.sh`
is likewise host-level -- an end-to-end smoke test that creates and destroys
its own ephemeral test VMs -- so it takes no vmname argument either. Scripts
that have both a non-interactive and an interactive variant carry a
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
(`virsh define`, no boot). The domain is defined with a virtio-serial
channel (`org.qemu.guest_agent.0`) for `qemu-guest-agent`, which cloud-init
installs and enables in the guest -- together these make
`virsh domifaddr --source agent`, `virsh shutdown`, `virsh reboot` etc. work
against the guest agent instead of only the NAT/DHCP lease file. This
channel is only set at definition time, so it only applies to VMs created
by this script going forward, not VMs defined before this change. Writes
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

### `scripts/04_destroy_vm.sh <vmname> [--force]`
Permanently deletes the VM: force-stops if running, undefines the libvirt
domain and its storage, removes the qcow2/seed/state files, and prints a
reminder to run `ssh-keygen -R <vmname>.<tailnet>` on any machine that has
SSH'd into it. Prompts for confirmation unless `--force` is given.

### `scripts/05_status_vm.sh <vmname>`
Shows `virsh dominfo` merged with the state file contents, plus the
Tailscale SSH hint (`<vmname>.<tailnet>.ts.net`).

### `scripts/09_doctor.sh`
No vmname argument -- host-level diagnostics. Checks KVM support
(`kvm-ok`), `libvirtd` is active, the five storage pools exist and are
correctly permissioned/setgid, and required binaries
(`virt-install`, `cloud-localds`, `qemu-img`, `yq`) are present.

### `scripts/08_test.sh`
No vmname argument -- end-to-end smoke test of the whole toolkit against a
real host. Runs `09_doctor.sh` first and aborts immediately if it fails,
then exercises the full single-VM lifecycle against two ephemeral test VMs
(`sandbox-test-auto-$$` via `00_init_vm-automated.sh`,
`sandbox-test-interactive-$$` via `00_init_vm-interactive.sh` with blank
input to accept every default): init -> start -> **wait for cloud-init to
actually finish provisioning** -> status -> reboot -> graceful stop -> fleet
views (`50_list_vms.sh`/`51_info_vms.sh`) -> destroy. Prints `[PASS]`/`[FAIL]`
per step and exits non-zero if anything failed. Always destroys every test
VM it created, even on failure (trap-based cleanup), so a failed run doesn't
leave VMs behind on the host.

After each start, rather than treating "libvirt says it's running" as
ready, the script polls the default NAT network's dnsmasq lease file
(`virsh domifaddr --source lease`) for an IP, waits for SSH, then runs
`cloud-init status --wait --long` on the guest over SSH so the test actually
blocks until provisioning (the `packages`/`runcmd` block in
`setup_config/user-data.tmpl` -- apt upgrade, qemu-guest-agent enable,
etc.) is done, instead of racing it. Prints the cloud-init status output
plus a
40-line tail of `/var/log/cloud-init-output.log` either way, so a
failed/degraded run is visible in the test output. Retries the wait once if
the SSH connection drops mid-provisioning (`package_reboot_if_required:
true` in `user-data.tmpl` can trigger a mid-provisioning reboot). SSH uses
`StrictHostKeyChecking=no`/`UserKnownHostsFile=/dev/null` (safe here since
these are freshly-created local VMs whose IPs get reused across runs) and
connects as `abhinav`, the user hardcoded into `user-data.tmpl`. Timeouts
are overridable via `IP_WAIT_TIMEOUT`, `SSH_WAIT_TIMEOUT`, and
`CLOUDINIT_WAIT_TIMEOUT` env vars (defaults 90s/60s/900s).

Does not exercise `11_configure_vm-automated.sh`/`11_configure_vm-interactive.sh`
(those need `TAILSCALE_AUTHKEY` and real network reachability to a tailnet,
out of scope for a local smoke test).

## Configuration

Both configuration scripts share the same end state (VM joined to the
tailnet, UFW locked down to `tailscale0`-only, Docker installed), the same
flags, and the same SSH/remote-step-script machinery, factored into
`scripts/lib/configure_steps.sh`. They differ only in how each step is
triggered: the `-automated` variant runs every step unconditionally
(fire-and-forget), while the `-interactive` variant confirms before each
step and streams its output live. Both refuse
to enable UFW unless `tailscale0` is confirmed up first, to avoid locking
out SSH with no fallback besides `virsh console`. Both are
re-runnable/idempotent -- this is how you change network/firewall config
and install/update Docker on an existing VM, since cloud-init only runs
once (`00_init_vm-automated.sh` disables it after first boot) -- and both
record `.tailscale`/`.ufw`/`.docker` status in the VM's state file. Docker
installation lives here rather than in cloud-init specifically so it can be
(re-)run against already-running VMs, not just at first boot -- see
`DECISIONS.md`.

### `scripts/11_configure_vm-automated.sh <vmname> [--skip-tailscale] [--skip-ufw] [--skip-docker] [--authkey KEY]`
Fire-and-forget: installs Docker, joins the VM to the tailnet (`tailscale
up`, needs `TAILSCALE_AUTHKEY` in `.env` or `--authkey`), and enables UFW,
running every step unconditionally with no prompts. Idempotency comes from
the remote steps themselves (e.g. `install_tailscale`/`install_docker`
check `command -v tailscale`/`command -v docker` first; the `ufw allow`
rule is safe to repeat). Useful for chaining after `01_start_vm.sh` in a
script, or reconfiguring a VM without babysitting it.

### `scripts/11_configure_vm-interactive.sh <vmname> [--skip-tailscale] [--skip-ufw] [--skip-docker] [--authkey KEY]`
Interactive counterpart to `11_configure_vm-automated.sh`: confirms before each step (install
Docker, install Tailscale, `tailscale up`, enable UFW) and runs it over `ssh -tt` (real pty)
so output streams live instead of running unattended. Useful for configuring
a new base image for the first time, or debugging why Docker/Tailscale/UFW
isn't coming up cleanly. Declining a step isn't an error --
`.tailscale`/`.ufw`/`.docker` in the state file record
`up`/`enabled`/`installed` only for steps actually confirmed and run,
`skipped` otherwise.

## Resize

Both resize scripts edit an existing VM's shape (RAM, vCPUs, disk, autostart)
and share their apply logic via `scripts/lib/resize_steps.sh`. RAM/vCPU
changes go through `virsh setmaxmem`/`setvcpus --config` (persistent config
only -- `virt-install` originally defines memory/vcpus as a single
current==max value, so there's no live ceiling to hotplug into; a change
takes effect the next time the domain starts). Disk resize is grow-only via
`qemu-img resize` -- shrinking is refused, since it can destroy data past
the new boundary and would need an in-guest filesystem shrink first, which
this toolkit doesn't attempt. Because of this, RAM/vCPU/disk changes always
require the VM to be stopped: if any of those actually change and the VM is
currently running, the script stops it (graceful ACPI shutdown, blocks
until it's actually off -- unlike `02_stop_vm.sh`, which is fire-and-forget,
this has to be certain the disk isn't in use before resizing it), applies
the changes, and starts it back up; if the VM is already stopped, changes
are applied and it's left stopped. Autostart changes apply immediately via
`virsh autostart`/`--disable` regardless of run state, no stop/restart
needed for that alone. Growing the disk only resizes the block device --
the guest's partition/filesystem still needs growing separately (e.g.
`growpart` + `resize2fs`).

### `scripts/12_resize_vm-automated.sh <vmname> [--ram MB] [--vcpus N] [--disk GB] [--autostart|--no-autostart] [--force]`
Fire-and-forget: unlike `00_init_vm-automated.sh`, every flag is optional
and only the fields actually passed are changed -- omitted flags mean
"leave as-is". Prints current vs. requested config before doing anything,
and exits cleanly with no changes if nothing differs. `--force`, if a stop
is needed, hard-powers the VM off (`virsh destroy`) instead of waiting for
a graceful shutdown -- same meaning as `02_stop_vm.sh --force`.

### `scripts/12_resize_vm-interactive.sh <vmname>`
Interactive counterpart -- no flags. Shows the current config, prompts for
each field (blank input keeps the current value; disk re-prompts if you
try to shrink it), then confirms once before applying. Same underlying
`resize_steps.sh` functions as the -automated variant.

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
plus its full `virsh dominfo`, use `05_status_vm.sh <vmname>` instead.


