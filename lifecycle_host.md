# Host administration scripts

All scripts live in `scripts/` and are run from the repo root (e.g.
`./scripts/83_host_configure_libvirt_storage_pools.sh`). These manage the
**Linux host itself** -- installing packages, setting up
`/etc/profile.d/sandbox.sh`, defining/moving the libvirt storage pools --
as opposed to [`lifecycle_vms.md`](./lifecycle_vms.md), which covers
scripts that create/manage individual VMs (or the whole fleet) once the
host is already set up. None of these take a `<vmname>` argument.

Naming convention: `NN_host_verb_noun.sh`, numbered `80`+ -- a separate
range from the `00`-`06`/`08`-`09`/`11`-`12` (single-VM) and `50`+
(fleet-wide) ranges documented in `lifecycle_vms.md`. `09_doctor_host.sh`
and `08_test.sh` are also host-*level* in the sense of taking no vmname
argument, but they belong to the VM tier, not this one -- they source
`scripts/lib/common.sh`, need no `sudo`, and have full `--help`. The
scripts on this page are a different, newer, and deliberately less uniform
tier: most need `sudo` (they're provisioning the host itself), none source
`common.sh`, and `--help` only exists on `84`. See CLAUDE.md's "Script
conventions (host-administration scripts)" section before trying to "fix"
that inconsistency -- it's tracked, not accidental.

## Common Usage Patterns

**Fresh host, from zero to ready for `lifecycle_vms.md`'s scripts:**
```
./scripts/80_host_check_specs.sh                     # confirm KVM/virtualization support first
./scripts/81_host_setup_initial_dependencies.sh      # installs packages, yq, joins libvirt/kvm groups
# log out and back in (or `newgrp libvirt`, `newgrp kvm`) so group membership takes effect
./scripts/82_host_setup_bootstrap_script.sh          # installs /etc/profile.d/sandbox.sh
source /etc/profile.d/sandbox.sh
./scripts/83_host_configure_libvirt_storage_pools.sh # defines/starts the 5 libvirt storage pools
./scripts/85_host_check_libvirt_config.sh            # quick sanity check: env vars, tool versions, pools
./scripts/09_doctor_host.sh                          # full PASS/FAIL host diagnostic (see lifecycle_vms.md)
```

**Just checking whether this host can run VMs at all (read-only, no changes):**
```
./scripts/80_host_check_specs.sh
```

**Re-running pool setup after manually editing `/etc/libvirt` or fixing permissions (idempotent, safe to re-run):**
```
./scripts/83_host_configure_libvirt_storage_pools.sh
```

**Moving `LIBVIRT_HOME` to a new disk/mountpoint, VMs and all:**
```
./scripts/84_host_change_libvirt_storage_pools.sh /new/path --dry-run       # see the plan first, changes nothing
./scripts/84_host_change_libvirt_storage_pools.sh /new/path                 # do it -- stops/restarts managed VMs automatically
./scripts/84_host_change_libvirt_storage_pools.sh /new/path --purge-old -y  # only once you've confirmed everything works at the new location
```
Avoid destination paths starting with `/lib` (e.g. `/libvirt`) -- see
"Gotchas" below, this isn't specific to this script but will break any VM
whose disk path starts with that string.

**Something seems off, or before opening an issue:**
```
./scripts/85_host_check_libvirt_config.sh   # quick dump: env vars, tool versions, pool/net/domain list
./scripts/09_doctor_host.sh                 # full PASS/FAIL diagnostic (see lifecycle_vms.md)
```

## Scripts

### `scripts/80_host_check_specs.sh`
Read-only, no flags, no `sudo`. Prints a full picture of the host's
capacity: `hostnamectl`/kernel/arch, virtualization detection
(`systemd-detect-virt`, `vmx`/`svm` CPU flags, `/dev/kvm` presence), CPU
(`lscpu`, filtered to the fields that matter for VM sizing), memory, disks
(`lsblk`, `df`, plus per-disk model/transport/rotational/scheduler from
`/sys/block`), mount points, NUMA topology (if `numactl` is installed),
IOMMU group count, network interfaces, and a final SUMMARY block. Makes no
changes -- the natural first thing to run on a new host, before installing
anything, and again any time you want a refresher on what the host can
actually support.

### `scripts/81_host_setup_initial_dependencies.sh`
No flags, no prompts -- runs top to bottom unconditionally. Installs
everything the rest of this toolkit depends on: the KVM/libvirt package set
(`qemu-kvm`, `libvirt-daemon-system`, `libvirt-clients`, `virtinst`,
`bridge-utils`, `libosinfo-bin`, `virt-top`, `virt-manager`, `genisoimage`,
`cloud-image-utils`), `jq`, and the **mikefarah/yq (Go)** binary specifically
-- pulled from GitHub releases rather than apt, since the apt package is the
incompatible Python `kislyuk/yq` (see CLAUDE.md/DECISIONS.md for why this
matters: `state.yaml` editing relies on Go-yq-specific `-i`/`.key = "value"`
syntax). Adds the current user to the `libvirt`/`kvm` groups and
enables+starts `libvirtd`. Requires `sudo` throughout -- this is the one
script in the repo that provisions the host's package set. Ends by printing
(not running) a handful of verification commands to run once you've logged
back in, so group membership has actually taken effect.

Safe to re-run (each `apt install`/`systemctl enable` is a no-op on an
already-satisfied host) but doesn't explicitly check state before acting,
unlike `83`/`84`.

### `scripts/82_host_setup_bootstrap_script.sh`
No flags. Renders and installs `/etc/profile.d/sandbox.sh`, which exports
`LIBVIRT_HOME` and the five `STORAGE_POOL_*`/`DEFAULT_*` variables at
system level so every login shell has them without per-user setup. Must
**not** be run as `sudo` itself -- it reads `$HOME` to build the rendered
file, so running it as root would bake root's home into everyone's
environment; the one `sudo` call inside it is scoped to just the final
`install` of the already-rendered file. After running, `source
/etc/profile.d/sandbox.sh` (or log out/in) to pick the new vars up in your
current shell.

Uses a mountpoint-conditional (`STORAGE_POOL_HOME` from `/mnt/extreme_ssd`
if mounted, else `$SANDBOX_HOME/libvirt`) baked into the generated file --
see DECISIONS.md for why `84_host_change_libvirt_storage_pools.sh`
deliberately replaces this with a fixed path when it later rewrites this
same file during a migration.

### `scripts/83_host_configure_libvirt_storage_pools.sh`
No flags, and (unlike every other script in this repo) **no `-h`/`--help`**
-- it exits immediately with an env-var error message if
`LIBVIRT_HOME`/`STORAGE_POOL_*` aren't already set, even if you only wanted
to see usage. A tracked gap, not a design choice -- don't rely on `--help`
here. Requires those six env vars (dies with a message pointing at `source
/etc/profile.d/sandbox.sh` if missing) and a working `sudo virsh`
connection.

Defines or repairs the five libvirt storage pools this toolkit depends on
-- `default`, `iso-pool`, `disk-pool`, `snapshot-pool`, `cloudinit-pool` --
each pointing at its corresponding `STORAGE_POOL_*` directory. Fully
idempotent: creates each pool's target directory, sets
`libvirt-qemu:kvm`/`775`+setgid ownership on the whole `LIBVIRT_HOME` tree,
and for each pool checks whether it already exists and already points at
the right target *before* touching anything -- only destroys/redefines a
pool if its XML actually disagrees with the expected path. Ensures
autostart and running state for all five, then prints a full
`pool-list`/`pool-info`/`pool-dumpxml` report. This is what you re-run
after any manual `/etc/libvirt` edit, or right after `82` on a fresh host.
(There's no real `virsh pool-is-active` subcommand -- this script checks
the `State:` line from `pool-info` instead, captured to a variable before
grepping to avoid the SIGPIPE-under-`pipefail` gotcha documented in
DECISIONS.md.)

### `scripts/84_host_change_libvirt_storage_pools.sh <new-libvirt-home> [options]`
The one script in this tier with a full `-h`/`--help` (checked before its
env-var validation, matching the VM-tier convention). Moves
`LIBVIRT_HOME` -- and all five storage pools -- to a new location,
migrating every VM this toolkit manages along with it. Run `--help` for the
exact flag reference (`-y`/`--force`, `--dry-run`, `--purge-old`); the full
step-by-step (stop managed VMs -> deactivate pools -> `rsync` with a
file-count verification -> redefine pools -> `qemu-img rebase -u` each VM's
disk + redefine its domain XML -> restart VMs that were running ->
rewrite `/etc/profile.d/sandbox.sh` and `.env`) is in its own `--help`
output and in DECISIONS.md's "Decision: unify..." history / PLAN.md's
2026-08-21 agent log, which also documents two real bugs found and fixed
while verifying this against a live host: the nonexistent
`pool-is-active` subcommand (same class of bug `83` above works around),
and a genuine upstream libvirt AppArmor footgun where any disk path
starting with the literal string `/lib` (not just `/lib/`) gets blocked --
so avoid naming a destination `/libvirt` or anything else `/lib`-prefixed.

VM discovery is scoped to this toolkit's own state files
(`STORAGE_POOL_DISKS/*.state.yaml`), not `virsh list --all` -- any other
libvirt domain on the host is left untouched. Old data at the previous
location is kept by default; only `--purge-old` deletes it, and only after
every other step has already succeeded.

### `scripts/85_host_check_libvirt_config.sh`
Read-only, no flags, no `sudo` needed for its own steps (that's the point
-- see below). Prints the six `LIBVIRT_HOME`/`STORAGE_POOL_*` env vars
(shown as `<not set>` rather than crashing if one is missing -- the whole
point of this script is to reveal exactly that), version info for
`virt-install`/`cloud-init`/`qemu-img`/`yq`, and `virsh
list`/`pool-list`/`net-list --all`. That last block runs *without* `sudo`
deliberately: a clean, password-prompt-free run of it is itself the
confirmation that the `libvirt`/`kvm` group membership granted by
`81_host_setup_initial_dependencies.sh` has actually taken effect in your
current shell -- a permission-denied or password prompt there means it
hasn't (often just because you haven't logged back in since running `81`).
A quicker, less rigorous cousin of `09_doctor_host.sh` (see
`lifecycle_vms.md`), which gives PASS/FAIL per check instead of a raw dump.

## Gotchas specific to this tier

- **Don't add `sudo`-free assumptions here.** The VM-tier rule in
  CLAUDE.md ("no scripts require sudo") does not apply to `80`-`85` --
  these provision the host itself (package installs, ownership changes,
  `virsh pool-*` calls against system-owned resources), so `sudo` is
  expected throughout, not a smell to "fix."
- **Don't assume `--help` works.** Only `84` has it. `80`/`81`/`82`/`85`
  take no arguments at all; `83` has no `--help` and will error on missing
  env vars before it would ever get the chance to show one.
- **Avoid `/lib`-prefixed `LIBVIRT_HOME` destinations** when using `84` --
  see its section above.
