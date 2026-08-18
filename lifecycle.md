# Lifecycle scripts

All scripts live in `scripts/` and are run from the repo root (e.g.
`./scripts/00_init_vm.sh myvm`). Each takes a `<vmname>` as its first
argument unless noted, and sources `scripts/lib/common.sh`. None require
`sudo` (see SETUP.md / PLAN.md for why). State is tracked per-VM in
`${STORAGE_POOL_DISKS}/<vmname>.state.yaml`.

Every script accepts `-h`/`--help` and prints its own full flag reference
(required args, options, defaults, examples) -- that's the source of truth
for exact flags; this file stays focused on the "why" and cross-script
behavior instead of restating every flag.

Naming convention: single-VM scripts are numbered `00`-`05` and suffixed
`_vm.sh`; fleet-wide scripts (operate across all VMs on the host) are
numbered `50`+ and suffixed `_vms.sh`. `09_doctor.sh` is host-level
diagnostics with no VM involved, so it carries neither suffix. `08_test.sh`
is likewise host-level -- an end-to-end smoke test that creates and destroys
its own ephemeral test VMs -- so it takes no vmname argument either.

Scripts that support both a fire-and-forget mode and a prompted/confirmed
mode take a single `-i`/`--interactive` flag rather than being split into
separate `-automated`/`-interactive` files (`00_init_vm.sh`,
`11_configure_vm.sh`, `12_resize_vm.sh`). Without `-i`, any field not passed
as a flag resolves silently from its default (env/`.env`) or, for
`12_resize_vm.sh`, from the VM's current value. With `-i`, any field not
passed as a flag is prompted for instead -- showing that same resolved
default, blank input accepts it -- and mutating steps ask for confirmation
before running. This means `-i` never changes *what* a script does, only
whether it asks first; see DECISIONS.md for why these were merged from
separate files.

`scripts/lib/common.sh` also loads `.env` from the repo root (if present)
before any script logic runs. Environment variables resolve lowest to
highest priority: system-level env vars < `.env` < flags/interactive answers
passed to the script. See [README.md](./README.md#requirements-for-the-repo)
and [env.sample](./env.sample).

## Common Usage Patterns

Copy-pasteable command sequences for the workflows you'll actually run.
Every command below also accepts `-i`/`--interactive` if you'd rather be
prompted/confirmed step by step instead of accepting defaults; see each
script's own section further down, or its `--help`, for the full flag list.

**Spin up a new VM, fastest path (all defaults):**
```
./scripts/00_init_vm.sh myvm
./scripts/01_start_vm.sh myvm
```

**Spin up a new VM, being walked through the shape (RAM/vCPUs/disk/etc.):**
```
./scripts/00_init_vm.sh myvm -i
./scripts/01_start_vm.sh myvm
```

**New VM, fully networked and ready to use (init -> start -> Tailscale/UFW/Docker):**
```
./scripts/00_init_vm.sh myvm
./scripts/01_start_vm.sh myvm
./scripts/11_configure_vm.sh myvm   # needs TAILSCALE_AUTHKEY in .env, or pass --authkey
```

**Check on a VM, or on everything:**
```
./scripts/05_status_vm.sh myvm      # one VM, full detail
./scripts/50_list_vms.sh            # every VM, one-line-per-VM table
./scripts/51_info_vms.sh            # every VM, full detail
```

**Day-to-day power control:**
```
./scripts/02_stop_vm.sh myvm        # graceful shutdown
./scripts/02_stop_vm.sh myvm --force  # hard power off, if it won't shut down
./scripts/03_reboot_vm.sh myvm
./scripts/01_start_vm.sh myvm       # start it back up
```

**Change a VM's RAM/vCPUs/disk/autostart:**
```
./scripts/12_resize_vm.sh myvm --ram 4096 --vcpus 4
# or, to be shown the current config and prompted for each field:
./scripts/12_resize_vm.sh myvm -i
```

**Reconfigure networking/Docker on a VM you already set up (idempotent, safe to re-run):**
```
./scripts/11_configure_vm.sh myvm --skip-docker   # e.g. just refresh Tailscale/UFW
```

**Tear a VM down completely:**
```
./scripts/04_destroy_vm.sh myvm
./scripts/04_destroy_vm.sh myvm --force   # skip the "are you sure?" prompt
```

**Before doing any of the above on a new host, or if something seems off:**
```
./scripts/09_doctor.sh              # host-level diagnostics
./scripts/08_test.sh                # full smoke test against real (ephemeral) VMs
```

**Forgot a flag?** Every script takes `-h`/`--help` and prints its full
reference, including the currently-resolved defaults for that host/checkout:
```
./scripts/00_init_vm.sh --help
```

## Sandbox lifecycle

### `scripts/00_init_vm.sh <vmname> [-i|--interactive] [options]`
Defines a new VM without starting it. Validates the name isn't already in
use, creates a qcow2 overlay disk (backed by the base cloud image) in
`STORAGE_POOL_DISKS`, renders the cloud-init templates and builds the seed
ISO in `STORAGE_POOL_CLOUD_INIT_ISOS`, then defines the libvirt domain
(`virsh define`, no boot). The domain is defined with a virtio-serial
channel (`org.qemu.guest_agent.0`) for `qemu-guest-agent`, which cloud-init
installs and enables in the guest -- together these make
`virsh domifaddr --source agent`, `virsh shutdown`, `virsh reboot` etc. work
against the guest agent instead of only the NAT/DHCP lease file. This
channel is only set at definition time, so it only applies to VMs created by
this script going forward, not VMs defined before this change. Writes
`<vmname>.state.yaml` with `status: defined`. Rolls back any partially
created files if a step fails.

`<vmname>` is always a required positional argument, even with `-i` --
`-i` only affects whether the *shape* fields (RAM, vCPUs, disk, image,
os-variant, autostart) are prompted for or taken from their defaults; it
never prompts for the name itself. Run `--help` for the full flag list and
each field's current resolved default.

`--autostart` sets the libvirt autostart flag, so the VM is started
automatically whenever `libvirtd` starts (e.g. after a host reboot) --
independent of whatever state the VM was in before. Defaults to
`DEFAULT_AUTOSTART` (or `false` if that's unset). This is a static
per-domain flag, not "remember and resume the VM's last state."

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
(`sandbox-test-auto-$$` via the flag-driven path of `00_init_vm.sh`,
`sandbox-test-interactive-$$` via `00_init_vm.sh -i` with blank input to
accept every default): init -> start -> **wait for cloud-init to actually
finish provisioning** -> status -> reboot -> graceful stop -> fleet views
(`50_list_vms.sh`/`51_info_vms.sh`) -> destroy. Prints `[PASS]`/`[FAIL]` per
step and exits non-zero if anything failed. Always destroys every test VM it
created, even on failure (trap-based cleanup), so a failed run doesn't leave
VMs behind on the host.

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

Does not exercise `11_configure_vm.sh` (needs `TAILSCALE_AUTHKEY` and real
network reachability to a tailnet, out of scope for a local smoke test).

## Configuration

### `scripts/11_configure_vm.sh <vmname> [-i|--interactive] [--skip-tailscale] [--skip-ufw] [--skip-docker] [--authkey KEY]`
Installs Docker, joins the VM to the tailnet (`tailscale up`, needs
`TAILSCALE_AUTHKEY` in `.env` or `--authkey`), and enables UFW (deny all
inbound except `tailscale0`), driven by the shared SSH/remote-step-script
machinery in `scripts/lib/configure_steps.sh`. Idempotency comes from the
remote steps themselves (e.g. `install_tailscale`/`install_docker` check
`command -v tailscale`/`command -v docker` first; the `ufw allow` rule is
safe to repeat) -- this is how you change network/firewall config and
install/update Docker on an existing VM, since cloud-init only runs once
(`00_init_vm.sh` disables it after first boot). Records
`.tailscale`/`.ufw`/`.docker` status in the VM's state file. Docker
installation lives here rather than in cloud-init specifically so it can be
(re-)run against already-running VMs, not just at first boot -- see
`DECISIONS.md`.

Without `-i`: runs every step unconditionally, no prompts -- fire-and-forget,
useful for chaining after `01_start_vm.sh` or reconfiguring a VM without
babysitting it. With `-i`/`--interactive`: confirms before each step (install
Docker, install Tailscale, `tailscale up`, enable UFW) and runs it over
`ssh -tt` (real pty) so output streams live instead of running unattended --
useful for configuring a new base image for the first time, or debugging why
Docker/Tailscale/UFW isn't coming up cleanly. Declining a step isn't an error
-- `.tailscale`/`.ufw`/`.docker` in the state file record
`up`/`enabled`/`installed` only for steps actually run, `skipped` otherwise.

Always refuses to enable UFW unless `tailscale0` is confirmed up first, in
both modes -- to avoid locking out SSH with no fallback besides
`virsh console`. This is a hard safety check, not a confirmation prompt, and
isn't skippable short of `--skip-ufw`.

## Resize

### `scripts/12_resize_vm.sh <vmname> [-i|--interactive] [--ram MB] [--vcpus N] [--disk GB] [--autostart|--no-autostart] [--force]`
Edits an existing VM's shape (RAM, vCPUs, disk, autostart) via
`scripts/lib/resize_steps.sh`. RAM/vCPU changes go through
`virsh setmaxmem`/`setvcpus --config` (persistent config only --
`virt-install` originally defines memory/vcpus as a single current==max
value, so there's no live ceiling to hotplug into; a change takes effect the
next time the domain starts). Disk resize is grow-only via `qemu-img resize`
-- shrinking is refused, since it can destroy data past the new boundary and
would need an in-guest filesystem shrink first, which this toolkit doesn't
attempt. Because of this, RAM/vCPU/disk changes always require the VM to be
stopped: if any of those actually change and the VM is currently running,
the script stops it (graceful ACPI shutdown, blocks until it's actually off
-- unlike `02_stop_vm.sh`, which is fire-and-forget, this has to be certain
the disk isn't in use before resizing it), applies the changes, and starts
it back up; if the VM is already stopped, changes are applied and it's left
stopped. Autostart changes apply immediately via `virsh autostart`/
`--disable` regardless of run state, no stop/restart needed for that alone.
Growing the disk only resizes the block device -- the guest's
partition/filesystem still needs growing separately (e.g. `growpart` +
`resize2fs`).

Every field is optional -- only fields actually given (as a flag, or
answered at a prompt in `-i` mode) change; the rest are left as-is. Prints
current vs. requested config before doing anything, and exits cleanly with
no changes if nothing differs. Without `-i`: applies immediately, no
confirmation. With `-i`/`--interactive`: any field not passed as a flag is
prompted for, seeded with the VM's *current* value (not `DEFAULT_*` -- blank
input keeps the current value; disk re-prompts if you try to shrink it), and
a single confirmation is required before applying. `--force`, if a stop is
needed, hard-powers the VM off (`virsh destroy`) instead of waiting for a
graceful shutdown -- same meaning as `02_stop_vm.sh --force`.

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
