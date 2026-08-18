# Implementation Plan — Sandbox Linux VMs

Working notes for implementing this repo. Written so that if a session breaks,
a fresh session (human or Claude) can pick up from here without re-deriving
the design decisions below.

## Goal

Bash-based tooling to create/manage cloud-image-based Linux VMs on libvirt/KVM
on a Linux laptop, replacing the ad-hoc scripts in `previous_scripts/`.

## Design decisions (already made, do not re-litigate without reason)

1. **Networking:** default libvirt NAT network + Tailscale for SSH access
   (`vmname.<tailnet>.ts.net`). `setup_config/network-config.tmpl` stays
   effectively unused (DHCP default) — not built out now.
2. **user-data customization:** one fixed cloud-init template, only
   `${VMNAME}` substituted. Same shape as `previous_scripts/user-data.tmpl`
   (fixed user `abhinav`, fixed SSH keys, fixed package list, installs
   docker, disables cloud-init after first boot).
3. **state.yaml scope:** per-VM state file living next to that VM's disk in
   the disk pool — NOT a single global registry. `50_list_vms.sh` aggregates by
   scanning the disk pool directory.
4. **Tooling:** bash + `yq` for reading/writing the per-VM YAML state files.
5. **Storage pool mapping** (this is the part most likely to be misread by a
   fresh session — get it from here, not from `previous_scripts/`, which used
   a different mapping):
   - `STORAGE_POOL_IMAGES` (libvirt `default` pool) — base cloud `.img`
     files only (e.g. `noble-server-cloudimg-amd64.img`). Read-only/shared.
   - `STORAGE_POOL_DISKS` (`disk-pool`) — per-VM working files, flat,
     directly in this dir (not subdirectories, so libvirt's dir-pool volume
     scan sees them): `<vmname>.qcow2`, `<vmname>.state.yaml`.
   - `STORAGE_POOL_CLOUD_INIT_ISOS` (`cloudinit-pool`) — cloud-init seed
     ISOs built by `00_init_vm-automated.sh` (`<vmname>-seed.iso`), kept separate from
     `STORAGE_POOL_DISKS` and `STORAGE_POOL_ISOS` for mental clarity: this
     pool holds *generated configuration disks*, not installer media or
     persistent VM disks.
   - `STORAGE_POOL_ISOS` (`iso-pool`) — reserved for the Option-1
     ISO-installer path (actual OS installer ISOs). Unused by this
     cloud-image flow.
   - `STORAGE_POOL_SNAPSHOTS` (`snapshot-pool`) — snapshot files. Only
     meaningful if snapshots end up being external
     (`virsh snapshot-create-as --disk-only`); internal qcow2 snapshots
     wouldn't use it. **Open question, deferred to Phase 6.**
6. **No `sudo` in lifecycle scripts.** The user is already in the `libvirt`
   and `kvm` groups (per SETUP.md), which is sufficient for
   `virsh`/`virt-install` against `qemu:///system` via polkit. To avoid
   needing `sudo` just to `chown` new files to `libvirt-qemu:kvm` (as
   `previous_scripts/create-vm.sh` did), SETUP.md's bootstrap adds
   `chmod g+s` (setgid) on the pool directories so new files inherit group
   `kvm` automatically. `lib/common.sh` pins `virsh -c qemu:///system`
   explicitly rather than relying on ambient default URI.
7. **Definition vs. start are separate steps.** `00_init_vm-automated.sh` defines the
   domain without booting it (`virt-install --print-xml --dry-run` piped
   into `virsh define`); `01_start_vm.sh` actually starts it. This matches the
   numbered-script intent in README.md (00 = init/define, 01 = start) and is
   cleaner than `virt-install --import` (which both defines and boots in one
   step, as `previous_scripts/create-vm.sh` did).
8. **Libvirt autostart is a `00_init_vm-automated.sh` flag, defaulting to off.**
   `--autostart`/`--no-autostart` sets the libvirt "start me when libvirtd
   starts" flag (independent of whether the VM was running before the host
   went down). Default is `DEFAULT_AUTOSTART` (optional env var, not in
   `require_env`'s mandatory list so it doesn't break existing
   `sandbox.sh` configs) or `false` if unset -- chosen so VMs don't
   silently pile up running after every laptop reboot. Recorded in
   `state.yaml` (`autostart: true|false`) and surfaced in `05_status_vm.sh`,
   `51_info_vms.sh`, `50_list_vms.sh`.
9. **Tailscale/UFW live in a post-boot configuration script run over SSH
   (currently `11_configure_vm-interactive.sh`), not in `user-data.tmpl`/
   cloud-init.** Two reasons: (a) cloud-init only runs once --
   `00_init_vm-automated.sh` disables it after first boot -- so anything baked into
   the template can never be changed on an existing VM without
   destroy+recreate, whereas a script run over SSH is re-runnable; (b)
   joining Tailscale needs a secret (`TAILSCALE_AUTHKEY`), and design
   decision #2 keeps `user-data.tmpl` limited to substituting only
   `${VMNAME}` -- putting a secret through that same `envsubst` path would
   mean it lands in the rendered cloud-init seed ISO on disk. The script
   enforces that UFW is only enabled after `tailscale0` is confirmed up,
   since enabling a deny-by-default firewall before that would lock out
   SSH with no fallback besides `virsh console`.
10. **Snapshots (Phase 6) will use internal qcow2 snapshots, not external.**
   Internal snapshots live inside the same qcow2 file
   (`virsh snapshot-create-as`/`snapshot-revert`/`snapshot-delete`), so
   `disk_path()` and every script's one-qcow2-per-VM assumption stays
   valid. External snapshots (new overlay file per snapshot, backed by
   `STORAGE_POOL_SNAPSHOTS`) would require reworking `disk_path()`,
   `state.yaml`, and `04_destroy_vm.sh` to track a chain of files instead of
   one, plus `blockcommit`/`blockpull` for pruning -- more machinery than
   a personal sandbox tool's "snapshot before I break this, revert if it
   goes wrong" use case needs. `STORAGE_POOL_SNAPSHOTS` stays defined but
   unused for now.
11. **`12_configure-manual_vm.sh` is the interactive counterpart to
   `11_configure-automated_vm.sh`, not a `virsh console` wrapper -- and for
   now it's the *only* one of the two that's implemented.** The job (join
   tailnet, lock UFW to tailscale0-only) is done interactively: `confirm`s
   before each step (install Tailscale, `tailscale up`, enable UFW) and runs
   it over `ssh -tt` so output streams live instead of running unattended.
   Nomenclature stays `11` = automated, `12` = manual/interactive -- `11_...`
   is deliberately kept as a stub (see point 12) rather than made interactive
   itself, so the split is ready whenever a fire-and-forget path is wanted.
12. **`11_configure-automated_vm.sh` is a placeholder, not deleted.** As of
   2026-08-16 the user doesn't want an automated (non-interactive)
   configuration pass yet -- `12_...` covers the current need. Rather than
   delete `11_...`, it's kept as a stub (usage comment + `die` pointing at
   `12_...`) so the file, its name, and its slot in the numbering stay
   reserved for when a fire-and-forget version is wanted later. When that
   happens, port the old provisioning logic (single non-interactive SSH run,
   authkey piped over stdin, same ordering-safety rule) back into `11_...`
   -- it's preserved in git history (see the commit that stubbed it out).
13. **(2026-08-18) Naming convention standardized to `NN_verb_vm-modality.sh`;
   `11_...` implemented for real; `04_resume_vm.sh` deleted.** Supersedes the
   "stub" state described in decisions #11/#12 above (left as-is for
   history). Three changes, all by request:
   - Renamed `00_init_vm.sh` → `00_init_vm-automated.sh` and added
     `00_init_vm-interactive.sh` (prompts for vmname/RAM/vCPUs/disk/image/
     os-variant/autostart with `DEFAULT_*` env vars as defaults, then execs
     into `00_init_vm-automated.sh`). Same split, and terminology
     ("interactive", not "manual"), applied to the configure scripts:
     `11_configure-automated_vm.sh` → `11_configure_vm-automated.sh`,
     `12_configure-manual_vm.sh` → `11_configure_vm-interactive.sh`. Both
     configure scripts now share the number `11`, matching `00`'s pattern of
     "same number, `-automated`/`-interactive` suffix decides the variant" --
     this also fixes the prior inconsistency where `11`/`12` put the
     modifier between the verb and `_vm` while `00` had no modifier at all.
     `12` is now free.
   - `11_configure_vm-automated.sh` is no longer a stub: it's the
     fire-and-forget counterpart to `11_configure_vm-interactive.sh`, running
     every step unconditionally (no `confirm()` calls) but keeping the same
     tailscale-before-ufw safety ordering. Idempotency relies on the remote
     steps themselves already no-oping safely on a re-run (tailscale install
     checks `command -v`, the `ufw allow` rule is safe to repeat).
   - The SSH/remote-step-script machinery that the interactive script used to
     own outright (host resolution, remote script upload,
     `run_step`/`check_step`, the tailscale/ufw remote actions) moved into
     `scripts/lib/configure_steps.sh`, sourced by both `11_configure_vm-automated.sh`
     and `11_configure_vm-interactive.sh`, so the two scripts differ only in
     *how* each step is triggered (unconditional vs. `confirm()`-gated), not
     in duplicated logic.
   - `04_resume_vm.sh` (`virsh resume` for a paused domain) was deleted:
     nothing in this toolkit ever pauses a VM (no `virsh suspend` caller
     anywhere), so it was dead code reachable only if a VM were paused
     out-of-band. Not paired with a new pause script since there's no
     current use case for one.
   - **Not yet tested against a real host** (renamed/refactored via `git mv`
     + edits, syntax-checked with `bash -n` only — Claude does not run
     lifecycle scripts directly, see `CLAUDE.md`). Before trusting this in
     day-to-day use, verify: `00_init_vm-interactive.sh` end-to-end,
     `11_configure_vm-automated.sh` against a running test VM (including
     re-running it to confirm the idempotency claim above), and that
     `11_configure_vm-interactive.sh` still behaves identically to the old
     `12_configure-manual_vm.sh` now that it sources the shared lib.
14. **(2026-08-18) `05_destroy_vm.sh` → `04_destroy_vm.sh`, `08_status_vm.sh` →
   `05_status_vm.sh`; added `08_test.sh`.** Renumbered by request so the
   single-VM lifecycle scripts (`00`-`05`) run contiguously with no gap, and
   so slot `08` is free for a new end-to-end smoke test rather than sitting
   next to `09_doctor.sh` for no reason. `08_test.sh` takes no vmname
   argument (like `09_doctor.sh`) -- it runs `09_doctor.sh` first and aborts
   immediately if the host isn't correctly configured, then exercises the
   full single-VM lifecycle (init via both the automated and interactive
   paths -> start -> status -> reboot -> stop -> fleet views -> destroy)
   against ephemeral `sandbox-test-*-$$` VMs it creates and always destroys
   itself, even on failure (trap-based cleanup, same pattern as
   `00_init_vm-automated.sh`'s rollback trap). Deliberately does not exercise
   `11_configure_vm-automated.sh`/`11_configure_vm-interactive.sh` -- those
   need `TAILSCALE_AUTHKEY` and real network reachability to a tailnet,
   which is out of scope for a local host smoke test. **Not yet run against
   a real host** -- syntax-checked with `bash -n` only, same caveat as
   decision #13.
15. **(2026-08-18) `08_test.sh` waits for cloud-init to actually finish, not
   just for `virsh domstate` to say "running".** First real-host run of
   `08_test.sh` exposed the gap: the original version treated
   `wait_for_state ... running` (near-instant once the domain boots) as
   "ready" and immediately moved on to status/reboot/stop, while cloud-init
   was still mid-provisioning in the background (apt upgrade + Docker
   install from `setup_config/user-data.tmpl` can take minutes) -- the
   graceful-stop step then raced that work and had to fall back to
   `--force`. Fix: after each start, the script polls
   `virsh domifaddr --source lease` for the VM's DHCP IP on the default NAT
   network (not `--source agent`, since `qemu-guest-agent` isn't in
   `user-data.tmpl`'s package list), waits for SSH, then runs
   `cloud-init status --wait --long` on the guest over SSH and prints the
   result plus a tail of `/var/log/cloud-init-output.log` -- both so the
   test genuinely blocks until provisioning is done and so a failed/degraded
   cloud-init run is visible in the output, which was the other half of the
   original ask ("display the stuff related to cloud init"). SSH uses
   `StrictHostKeyChecking=no`/`UserKnownHostsFile=/dev/null` (acceptable
   here -- these are ephemeral local VMs whose IPs get reused across runs,
   and nothing is ever written to a known_hosts file) and connects as
   `abhinav`, per the hardcoded user in `user-data.tmpl`. One retry is built
   in for a dropped SSH connection, since `user-data.tmpl`'s
   `package_reboot_if_required: true` can reboot the guest mid-provisioning.
   **Not yet re-verified against a real host** -- the fix responds to a real
   observed failure, but hasn't itself been run end-to-end yet.

## Best practices adopted (vs. previous_scripts/)

- `set -euo pipefail` everywhere (previous scripts only had `set -e`).
- Validate `vmname` against `^[a-zA-Z0-9_-]+$` before it's used in any path
  or virsh command — previous scripts did zero validation.
- `00_init_vm-automated.sh` traps failures and rolls back partial state (e.g. qcow2
  created but seed ISO build failed) so a retry doesn't hit "file already
  exists."
- `yq` added to SETUP.md's dependency list (not previously listed, needed
  for state.yaml).

## Why previous_scripts/ can be deleted once this is done

`previous_scripts/create-vm.sh` + `user-data.tmpl` → superseded by
`00_init_vm-automated.sh` + `01_start_vm.sh` + `setup_config/{user-data,meta-data}.tmpl`.
`previous_scripts/delete-vm.sh` → superseded by `04_destroy_vm.sh`.
`testing-virtual-machines-{meta-data,user-data}` are just example *rendered
output* from a prior run, not templates — nothing to port. Verified line by
line against the new plan (see conversation history / commit message when
`previous_scripts/` is removed for the full diff reasoning).

**Do not delete `previous_scripts/` until Phase 2 testing (create → start →
SSH in → destroy) has actually succeeded once.**

## Directory structure (actual)

All scripts live under `scripts/`, run from the repo root
(e.g. `./scripts/00_init_vm-automated.sh myvm`).

```
scripts/
  lib/
    common.sh              # sourced by every numbered script
    configure_steps.sh     # shared by 11_.../12_... -- see design decision #13
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

## scripts/lib/common.sh contract

- Loads/validates env vars, fails fast if `STORAGE_POOL_*` unset.
- `VIRSH="virsh -c qemu:///system"` wrapper — always use this, never bare
  `virsh` or `sudo virsh`.
- Path helpers: `disk_path <vmname>`, `seed_path <vmname>`,
  `state_path <vmname>`.
- State helpers (wrap `yq`): `state_init`, `state_get`, `state_set`.
- `vm_exists`, `vm_is_running`.
- `validate_vmname` — enforces `^[a-zA-Z0-9_-]+$`, called at the top of any
  script taking a vmname argument.
- `log`, `die`, `confirm` (yes/no prompt, honors a `--force`/`-y` flag).

## env vars (env.sample)

```
SANDBOX_HOME, LIBVIRT_HOME, STORAGE_POOL_IMAGES, STORAGE_POOL_ISOS,
STORAGE_POOL_DISKS, STORAGE_POOL_SNAPSHOTS, DEFAULT_CLOUD_IMG,
DEFAULT_OS_VARIANT, DEFAULT_RAM_MB, DEFAULT_VCPUS, DEFAULT_DISK_GB,
TAILSCALE_TAILNET, TAILSCALE_AUTHKEY
```

## Script specs

- **00_init_vm-automated.sh `<vmname> [--ram N] [--vcpus N] [--disk N] [--image NAME] [--os-variant VARIANT] [--autostart|--no-autostart]`** —
  validate name unused (state file + `$VIRSH list --all`), validate base
  image exists in `STORAGE_POOL_IMAGES`, create qcow2 overlay in
  `STORAGE_POOL_DISKS` backed by the base image, render
  `meta-data.tmpl`/`user-data.tmpl` via `envsubst`, build seed ISO with
  `cloud-localds`, generate domain XML (`virt-install --print-xml
  --dry-run`) and `virsh define` it (no boot), write initial
  `<vmname>.state.yaml` (`status: defined`, resources, base image,
  created_at). Trap-based rollback on any failure.
- **00_init_vm-interactive.sh** — no args; prompts for vmname (validated) and
  shape (RAM/vCPUs/disk/image/os-variant/autostart, `DEFAULT_*` env vars as
  defaults), then `exec`s into `00_init_vm-automated.sh` with the collected
  values as flags. Owns none of the disk/domain-creation logic itself.
- **01_start_vm.sh `<vmname>`** — `$VIRSH start`; state → `status: running`,
  `started_at`.
- **02_stop_vm.sh `<vmname> [--force]`** — graceful `$VIRSH shutdown`, or
  `$VIRSH destroy` with `--force`; update state.
- **03_reboot_vm.sh `<vmname>`** — `$VIRSH reboot`; touch state timestamp.
- **04_destroy_vm.sh `<vmname> [--force]`** — confirm (unless `--force`),
  force-stop if running, `$VIRSH undefine --remove-all-storage --nvram`,
  sweep leftover disk/seed/state files, print the
  `ssh-keygen -R vmname.<tailnet>` reminder.
- **05_status_vm.sh `<vmname>`** — merge `$VIRSH dominfo` with the state file,
  print the Tailscale hostname as the connection hint.
- **09_doctor.sh** — `kvm-ok`, `libvirtd` active check, pool
  status/permissions (`$VIRSH pool-list`, ownership/setgid check on
  `STORAGE_POOL_*`), required binaries present (`virt-install`,
  `cloud-localds`, `qemu-img`, `yq`).
- **08_test.sh** — no vmname arg; end-to-end smoke test. Runs `09_doctor.sh`
  first and aborts on failure, then against ephemeral `sandbox-test-*-$$`
  VMs (one via `00_init_vm-automated.sh`, one via `00_init_vm-interactive.sh`
  fed blank input) exercises start -> wait for cloud-init (via SSH,
  `cloud-init status --wait`) -> status -> reboot -> stop -> fleet-views ->
  destroy, printing `[PASS]`/`[FAIL]` per step. Trap-based cleanup always
  destroys any test VM it created, even on failure. See design decisions
  #14 and #15.
- **50_list_vms.sh** — scan `STORAGE_POOL_DISKS/*.state.yaml`, cross-reference
  live status from `$VIRSH list --all`, print a table.
- **51_info_vms.sh** — no vmname arg; loop over all `STORAGE_POOL_DISKS/*.state.yaml`
  and dump full state file detail + Tailscale hostname hint per VM.
- **11_configure_vm-automated.sh `<vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]`** —
  fire-and-forget: resolves SSH host, uploads the shared remote step script
  (`lib/configure_steps.sh`), runs install-tailscale → bring-up-tailscale →
  poll for `tailscale0` → configure-ufw unconditionally, no prompts. Same
  tailscale-before-ufw safety ordering as `11_configure_vm-interactive.sh`.
  See design decision #13.
- **11_configure_vm-interactive.sh `<vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]`** —
  same flags, host resolution, and tailscale-before-ufw ordering rule as
  `11_configure_vm-automated.sh`, but interactive: `confirm`s before each step
  (install Tailscale, `tailscale up`, enable UFW) and runs it over `ssh -tt`
  (real pty) so output streams live instead of running unattended. Declining
  a step is not an error -- `.tailscale`/`.ufw` in the state file are set to
  `up`/`enabled` only for steps actually run and confirmed, `skipped`
  otherwise. Both configure scripts source `lib/configure_steps.sh` for host
  resolution, remote script upload, and the remote actions themselves -- they
  differ only in how each step is triggered.
- **21/22** — deferred to Phase 6 (see open question above).

## Build order / phases

- **Phase 0 — Foundations.** `lib/common.sh`, `env.sample`,
  `setup_config/*.tmpl`, SETUP.md updates (setgid + yq), `lifecycle.md`.
- **Phase 1 — Core lifecycle.** `00_init_vm-automated.sh`, `01_start_vm.sh`, `04_destroy_vm.sh`.
- **Phase 2 — Rest of single-VM lifecycle.** `02_stop_vm.sh`, `03_reboot_vm.sh`,
  `05_status_vm.sh`. (`04_resume_vm.sh` was built here too, then deleted
  2026-08-18 as dead code -- see design decision #13.)
- **Phase 3 — Fleet view.** `50_list_vms.sh`, `51_info_vms.sh`.
- **Phase 4 — Diagnostics.** `09_doctor.sh`.
- **Phase 5 — Cleanup.** Delete `previous_scripts/` once Phase 1/2 has been
  tested end-to-end against a real VM.
- **Phase 5.5 — Automated configuration.** `11_configure_vm-automated.sh`.
  Originally deferred by request (2026-08-16, kept as a stub, see design
  decision #12); implemented for real 2026-08-18 as a fire-and-forget
  counterpart to `11_configure_vm-interactive.sh`, sharing step logic via
  `lib/configure_steps.sh` -- see design decision #13. Not yet tested against
  a real host.
- **Phase 5.75 — Interactive configuration.** `11_configure_vm-interactive.sh`
  (Tailscale + UFW, post-boot over SSH, confirm-gated and streamed over
  `ssh -tt`). Renamed from `12_configure-manual_vm.sh` (via an intermediate
  `12_configure_vm-interactive.sh`) and refactored to use the shared step lib
  2026-08-18 (behavior unchanged) -- see design decision #13. Now shares
  number `11` with the automated variant, matching `00`'s pattern.
  Also added `00_init_vm-interactive.sh` in this pass (prompts for vmname/shape,
  execs into `00_init_vm-automated.sh`).
- **Phase 6 — Deferred.** `21/22` snapshot scripts, once the snapshot-pool
  (internal vs external) question is resolved.
- **Phase 7 — Smoke test.** `08_test.sh`, added 2026-08-18 alongside the
  `04`/`05` renumbering -- see design decision #14. First real-host run
  surfaced the cloud-init-wait gap fixed in design decision #15. Fix not
  yet re-verified against a real host.

## Testing steps

Host bootstrap (installing packages, starting `libvirtd`, defining storage
pools, `chmod g+s`) requires `sudo` and touches shared system state — **do
not run it without explicit confirmation in the session**, even though it's
scripted in SETUP.md.

Per phase:

- **Phase 0:** `bash -n` (syntax check) on `scripts/lib/common.sh`. Manually
  source it in a shell with the env vars set and call each helper function
  once.
- **Phase 1:** After host bootstrap is confirmed and done (run from repo root):
  1. `./scripts/00_init_vm-automated.sh sandbox-test-01` — verify qcow2 + seed ISO +
     state.yaml created in `STORAGE_POOL_DISKS`, domain shows in
     `virsh -c qemu:///system list --all` as shut off.
  2. `./scripts/01_start_vm.sh sandbox-test-01` — verify domain running
     (`virsh list`), wait ~60-90s, `ssh sandbox-test-01.<tailnet>.ts.net`
     succeeds.
  3. `./scripts/04_destroy_vm.sh sandbox-test-01` — verify domain undefined,
     disk/seed/state files removed, `virsh list --all` no longer shows it.
  4. Re-run `00_init_vm-automated.sh` with the same name immediately after to confirm no
     leftover-file conflicts.
  5. `./scripts/00_init_vm-interactive.sh` — verify the prompts (with blank
     input to accept every default) produce the same result as step 1.
- **Phase 2:** For a running test VM, exercise `02_stop_vm.sh` (graceful),
  confirm `virsh list` shows shut off; `01_start_vm.sh` again; `03_reboot_vm.sh`
  and confirm uptime resets; `02_stop_vm.sh --force`; `05_status_vm.sh` at each
  state transition and confirm it reflects reality.
- **Phase 3:** With 0, 1, and 2+ VMs defined, run `50_list_vms.sh` and confirm
  the table matches `virsh list --all`. Run `51_info_vms.sh` and confirm it
  prints detail for every defined VM, including one that's defined-but-not-
  started (should not error).
- **Phase 4:** Run `09_doctor.sh` on a correctly bootstrapped host (all green)
  and verify it correctly flags a problem when one is deliberately introduced
  (e.g. `libvirtd` stopped).
- **Phase 5:** Only after Phase 1 + 2 pass, `git rm -r previous_scripts/`.
- **Phase 7:** Run `08_test.sh` on a correctly bootstrapped host and confirm
  every step reports `[PASS]`, both `sandbox-test-*-$$` VMs are gone
  afterward (`virsh list --all`, `50_list_vms.sh`), and that deliberately
  killing a step midway (e.g. `Ctrl-C` after the VMs are defined) still
  leaves the host clean -- the trap-based cleanup should destroy whatever
  was created so far.

## Testing results (2026-08-16, real host)

Full cycle tested end-to-end against a real libvirt/KVM host: `00_init_vm.sh` →
`01_start_vm.sh` → `08_status_vm.sh`/`50_list_vms.sh`/`51_info_vms.sh` → `02_stop_vm.sh`
(graceful) → `01_start_vm.sh` → `03_reboot_vm.sh` → `02_stop_vm.sh --force` →
`01_start_vm.sh` → manual `virsh suspend` → `04_resume_vm.sh` → `05_destroy_vm.sh
--force` → re-run `00_init_vm.sh` (no leftover-file conflicts) →
`05_destroy_vm.sh --force` again. All state transitions correct, `state.yaml`
tracked accurately throughout, disk pool left clean after destroy. The test
VM got a DHCP lease on the default NAT network with the correct hostname
(`sandbox-test-01`), confirming cloud-init applied the rendered
user-data/meta-data correctly.

Also tested (2026-08-16, same host): `00_init_vm.sh` with no autostart flag
(`Autostart: disable` in dominfo, `autostart: false` in state.yaml) and with
`--autostart` (`Autostart: enable`, `autostart: true`, correctly shown in
`08_status_vm.sh`/`50_list_vms.sh`), both cleaned up correctly via `05_destroy_vm.sh`.

**Not verified: SSH into a VM.** The public keys baked into
`setup_config/user-data.tmpl` are the user's own keys for their actual
machine; the environment these scripts were tested from doesn't hold the
matching private key. The user should verify `ssh <vmname>.<tailnet>`
(or `ssh abhinav@<dhcp-ip>` without Tailscale) themselves.

Two real bugs found and fixed during this testing pass (not caught by
`bash -n` or code review, only by running the actual host):

1. **`09_doctor.sh`'s `libvirtd is active` check was briefly a false negative
   on a cold host** due to systemd socket-activation (`libvirtd.socket` was
   active but `libvirtd.service` itself hadn't been triggered yet). Resolved
   itself once something (the doctor script's own later `virsh` check)
   triggered activation -- not a code bug, just a note that the very first
   `09_doctor.sh` run right after enabling `libvirtd` may show this as FAIL
   transiently.
2. **Real bug:** `vm_exists`/`vm_is_running` in `common.sh`, and the storage
   pool check loop in `09_doctor.sh`, all piped `virsh` output directly into
   `grep -q`/`grep -qx`. Under `set -o pipefail` (enabled in `common.sh`),
   `grep -q` exiting early on a match can cause `virsh` to die of `SIGPIPE`
   while still writing later output, and pipefail then surfaces that as a
   failure even though the match succeeded. This caused genuinely flaky,
   different-check-fails-each-run behavior in `09_doctor.sh`'s pool loop.
   Fixed by capturing `virsh`'s output into a variable first, then grepping
   the captured string (`<<<`) instead of piping live. Fixed in all three
   locations.

**`11_configure-automated_vm.sh` is a stub (2026-08-16), nothing to test.**
It previously held the fully-automated Tailscale/UFW provisioning logic
(SSH host resolution, install + `tailscale up` with authkey piped over
stdin, then `ufw` lockdown gated on `tailscale0` being confirmed up); that
logic was deliberately removed at the user's request rather than left
untested indefinitely, and is preserved in git history for whenever an
automated pass is wanted again (see design decision #12). Its usage/flags
still document the intended future interface.

**Not yet tested: `12_configure-manual_vm.sh` end-to-end.** Written and
syntax-checked (`bash -n`) but not run against a real VM -- same untested
surface as `11_...` above, plus needs verifying that `ssh -tt` streams
output live for each step (including the authkey-over-stdin `tailscale up`
invocation, which forces `-tt` despite piped stdin) and that declining a
step via `confirm` leaves `.tailscale`/`.ufw` as `skipped` in state.yaml.

## Status

- [x] Phase 0 — Foundations
- [x] Phase 1 — Core lifecycle (tested against a real host, see above)
- [x] Phase 2 — Rest of single-VM lifecycle (tested against a real host, see above)
- [x] Phase 3 — Fleet view (tested against a real host, see above)
- [x] Phase 4 — Diagnostics (tested against a real host, see above)
- [x] Phase 5 — Cleanup (previous_scripts/ removed)
- [ ] Phase 5.5 — Automated configuration (`11_configure_vm-automated.sh`;
      implemented for real 2026-08-18, not yet tested against a real host --
      see design decision #13)
- [x] Phase 5.75 — Interactive configuration (`11_configure_vm-interactive.sh`,
      renamed + refactored to share step logic 2026-08-18; not yet tested
      against a real host, see note below)
- [ ] Phase 6 — Deferred (`21/22` snapshot scripts)

(Update the checklist above as phases complete.)



## Wishlist  
- [ ] Check the networking using Tailscale. See if you want to do it automatically or have a manual setup 
- [ ] Check using the vms - how will you ssh into the machines etc 
- [ ] Install qemu guest agent in the virtual machines. (can be done through cloud-init as well)
```
sudo apt install qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```
Useful for :
```
virsh domifaddr
virsh shutdown
virsh reboot
```

- [ ] The `info` and the `list` scripts can be a little more detailed where you can give the IP addresses of all the vms etc 
```
for vm in $(virsh list --name); do
    printf "%-30s " "$vm"
    virsh domifaddr "$vm" --source agent 2>/dev/null |
        awk '$3 == "ipv4" {print $4}'
done
```

```
# Primary : 
virsh domifaddr VM --source agent

# DHCP Fallback : 
virsh net-dhcp-leases default
```