## ROADMAP 
## Things to implement 
- [ ] Check the networking using Tailscale. See if you want to do it automatically or have a manual setup 
- [ ] Check if the networking has been setup as per the design decisions that I have taken 
- [ ] Check using the vms - how will you ssh into the machines etc 
- [ ] user-data customization. Can ask to specify the user instead of hardcoded to `abhinav`. this can also be controlled from an environment variable. 

## Wishlist (Might implement later. Dont implement this right now - overengineering and wastage of time)
- [ ] Snapshot scripts (`21/22` snapshot scripts)
- [ ] Move from individual yaml state files to a global repositry. Think this through later. Dont waste your time on this. 
- CLI tool development (Long shot - Dont invest your time on this right now)
  - [ ] Change from scripts to an actual cli tool that I can design. That would make it more distributable 
  - [ ] When making into a CLI tool, you can actually make the tool a little more generic and support other types of sandboxes like - microvms, docker containers etc 
  - [ ] While implementing the cli tool, you could also implement a gateway of sort and expose using an API so that AI agents can provision and manage the sandboxes on demand 

--- 

## AGENT LOGS 
Claude and Other Coding Agents can add their log here :- 

### 2026-08-18 (4) -- Claude (Sonnet 5)
Renamed `09_doctor.sh` -> `09_doctor_host.sh` (it only ever checked the
host, not any VM -- the name was ambiguous next to the new script below) and
added `06_doctor_vm.sh`: per-VM diagnostics, filling the "is this VM
actually configured right" gap `05_status_vm.sh` (dumps info, doesn't judge
it) and `09_doctor_host.sh` (host-only) both leave open. Checks, in two
groups (`[PASS]`/`[FAIL]` per check, exit 1 on any failure):
- libvirt/on-disk (always): state file / domain / disk / seed-ISO / base
  image all exist; domain's actual vCPUs, max-memory, and autostart (via
  `virsh dominfo`) and the qcow2's actual virtual size (via
  `resize_disk_current_gb`, reused from `lib/resize_steps.sh`) all match
  `state.yaml` -- catches drift from a partial resize or a manual `virsh`
  edit.
- guest (only if the VM is running): qemu-guest-agent responds, SSH is
  reachable (reuses `configure_resolve_ssh_host` from
  `lib/configure_steps.sh`), cloud-init finished, and -- only for whichever
  of Docker/Tailscale/UFW `state.yaml` actually recorded as configured, not
  `skipped` -- that the guest's live state agrees.

Updated `08_test.sh` (Step 1 + its own docstring/usage) to call
`09_doctor_host.sh`, and `README.md`/`lifecycle.md`/`DECISIONS.md` for both
the rename and the new script.

Verified end-to-end against this real host, not just `bash -n`: ran
`09_doctor_host.sh` (19/19 checks passed) and a full `08_test.sh` pass
(13/13) to confirm the rename didn't break anything downstream. For
`06_doctor_vm.sh`, ran three throwaway VMs through
init -> start -> (wait for cloud-init) -> `11_configure_vm.sh
--skip-tailscale --skip-ufw` -> `06_doctor_vm.sh` -> destroy (all
self-cleaned, no leftovers). First real run caught an actual bug: the
cloud-init check only accepted `status: done`, but this repo's
`user-data.tmpl` touches `/etc/cloud/cloud-init.disabled` as its last
`runcmd` step (see "cloud-init only runs once" under `11_configure_vm.sh` in
lifecycle.md), so `cloud-init status` legitimately reports `disabled`, not
`done`, on any check after first boot -- every run after the VM's first
boot was a guaranteed false-positive `[FAIL]`. Fixed to accept `done` *or*
`disabled`; re-ran and got a clean all-`[PASS]` result including live
Docker/SSH/guest-agent checks. Tailscale/UFW guest-check branches
themselves are still unverified against a real tailnet -- no
`TAILSCALE_AUTHKEY` on this host, same caveat as `11_configure_vm.sh`'s
existing log entries below.

### 2026-08-18 (3) -- Claude (Sonnet 5)
End-to-end verification of the automated/interactive merge + `--help` work
(2026-08-18 (2) below) against this real host -- previously only
syntax-checked. Ran `09_doctor.sh`, a full `08_test.sh` pass, and manual
coverage of the two scripts `08_test.sh` doesn't exercise
(`12_resize_vm.sh` entirely; `11_configure_vm.sh`'s non-Tailscale steps).
Found and fixed two real bugs:

- **Merged scripts weren't executable.** `Write` doesn't preserve/set the
  execute bit the way `git mv` would have, so `00_init_vm.sh`,
  `11_configure_vm.sh`, and `12_resize_vm.sh` were created `-rw-rw-r--` --
  every invocation failed with "Permission denied" (`08_test.sh` caught this
  immediately on its first run). Fixed with `chmod +x`.
- **`12_resize_vm.sh` was broken against any running VM, for any field.**
  `resize_disk_current_gb()` in `scripts/lib/resize_steps.sh` calls
  `qemu-img info` unconditionally (even for a RAM-only or autostart-only
  resize, since it's needed for the "Current:"/"Requested:" print rows) --
  but `qemu-img info` without `-U`/`--force-share` can't get a lock on a
  qcow2 that's actively attached to a running domain, so it failed with
  "Failed to get shared 'write' lock", `bytes` ended up as the literal
  string `"null"`, and the arithmetic on it crashed with `set -u`'s "unbound
  variable" under that name. Pre-existing bug in `resize_steps.sh`'s
  function body (untouched by the merge) -- `12_resize_vm-automated.sh`/
  `-interactive.sh` had the same bug before the merge, it had just never
  been run against a live host before (see prior "not verified end-to-end"
  caveats). Fixed by adding `-U` to the `qemu-img info` call -- safe here
  since it's read-only metadata inspection and virtual-size doesn't change
  except through `resize_apply_disk_grow`, which only runs while stopped.

Also fixed a minor, unrelated flakiness noticed during the `08_test.sh` run:
Step 6 (`03_reboot_vm.sh`) issued a reboot and Step 7 immediately attempted
a graceful stop with no wait in between; `virsh reboot` doesn't change
libvirt's reported domain state (stays "running" the whole time), so
there's nothing to poll for there, and the guest's ACPI listener isn't
always back up yet when the stop request lands -- causing an unnecessary
`--force` fallback (observed once, see below). Fixed by waiting for the
guest's SSH to come back up after reboot before Step 7 runs.

Full manual coverage exercised: `00_init_vm.sh` (already-exists guard,
unknown-flag/invalid-name/missing-vmname rejection, rollback leaves no
partial artifacts); `12_resize_vm.sh` (RAM+vCPU resize while running
stops/applies/restarts correctly, no-op detection, disk grow, shrink
refusal, immediate autostart toggle with no restart, `-i` mode blank-input
no-op / real-value-with-confirm / decline-aborts-cleanly, unknown flag);
`11_configure_vm.sh` (missing-authkey die path, not-running die path, real
Docker install + idempotent re-run, `-i` mode step decline, unknown flag).
Tailscale/UFW steps in `11_configure_vm.sh` were NOT exercised -- no
`TAILSCALE_AUTHKEY` configured on this host -- so treat those two steps
specifically as still "believed correct but unverified."

Test run 1 (before the two fixes): 2/13 `08_test.sh` steps failed
(permission denied on both init calls). Test run 2 (after `chmod +x`,
before the resize fix): 12/13 passed (1 unrelated reboot/stop flake, see
above). Test run 3 (final, all fixes applied): 13/13 passed. All test VMs
(both from `08_test.sh` and the manually-created one used for resize/
configure coverage) were destroyed at the end of each run; host left with
no leftover libvirt domains, disks, or state files, confirmed via
`virsh list --all` and directory listing after each run.

### 2026-08-18 (2) -- Claude (Sonnet 5)
Implemented the wishlist item on unifying automated/interactive scripts, plus
`--help` everywhere:
- **Merged `-automated`/`-interactive` pairs**: `00_init_vm-automated.sh` +
  `00_init_vm-interactive.sh` -> `00_init_vm.sh`; same for
  `11_configure_vm-*` -> `11_configure_vm.sh` and `12_resize_vm-*` ->
  `12_resize_vm.sh`. Each now takes `-i`/`--interactive`: without it, any
  field not passed as a flag resolves silently from its default (old
  `-automated` behavior); with it, unset fields are prompted for instead and
  mutating steps confirm first (old `-interactive` behavior). `<vmname>` is
  now a required positional arg in every mode -- `00_init_vm-interactive.sh`
  used to prompt for it, which was the odd one out vs. the other two
  scripts; that inconsistency is gone. Promoted `prompt_default`/
  `prompt_int`/`prompt_bool` into `scripts/lib/common.sh`. See DECISIONS.md
  ("Decision : Unify automated/interactive scripts...") for full rationale.
- **`--help` on every script**: added a `show_help_if_requested` helper to
  `common.sh` (checked before `require_env`, so `--help` works even with a
  broken/unconfigured environment) and a full NAME/USAGE/REQUIRED/OPTIONS/
  EXAMPLES block to every script in `scripts/`. `lifecycle.md` trimmed to
  stop restating full flag lists (that's now `--help`'s job) and instead
  focuses on cross-script rationale/ordering, to cut the number of places a
  flag's documentation can drift.
- Updated `08_test.sh`'s two init calls (previously
  `00_init_vm-automated.sh` / `00_init_vm-interactive.sh` with blank stdin)
  to point at `00_init_vm.sh` (flags) and `00_init_vm.sh -i` (blank stdin,
  now 6 blank lines instead of 7 since vmname is no longer prompted for).
  Also fixed two pre-existing stale references in `env.sample`
  (`05_destroy_vm.sh` -> `04_destroy_vm.sh`,
  `11_configure-automated_vm.sh` -> `11_configure_vm.sh`) noticed while
  updating it.

Not verified end-to-end against a real host in this session -- syntax-checked
(`bash -n`) every touched/new script, and exercised `--help` output and the
promoted prompt helpers directly, but did not run `08_test.sh` or otherwise
create real VMs (would have real side effects on the host). Same "believed
correct but unverified" caveat as prior sessions' unverified items.

### 2026-08-18 -- Claude (Sonnet 5)
Implemented three wishlist items:
- **qemu-guest-agent**: added to `setup_config/user-data.tmpl`'s packages
  list (+ explicit `systemctl enable --now`), and added the required
  virtio-serial channel device (`--channel unix,target_type=virtio,
  name=org.qemu.guest_agent.0`) to the `virt-install` call in
  `00_init_vm-automated.sh`. New VMs only -- see DECISIONS.md.
- **Docker off cloud-init**: removed the Docker `runcmd` block from
  `user-data.tmpl`, added an idempotent `install_docker` remote step to
  `scripts/lib/configure_steps.sh`, wired into both
  `11_configure_vm-automated.sh`/`-interactive.sh` behind a new
  `--skip-docker` flag, recorded as `.docker` in state.yaml.
- **Resize script**: new `scripts/12_resize_vm-automated.sh` /
  `12_resize_vm-interactive.sh`, sharing `scripts/lib/resize_steps.sh`.
  Edits RAM/vCPUs/disk/autostart on an existing VM; RAM/vCPU/disk changes
  always apply while stopped (`--config` only, no live hotplug -- see
  DECISIONS.md) and restart the VM if it was running; disk resize is
  grow-only. Also added `state_set_raw` to `scripts/lib/common.sh` (numeric
  state fields, `state_set`'s own doc comment referenced this but it didn't
  exist yet).

Not verified end-to-end against a real host in this session (no VM was
started/stopped) -- syntax-checked (`bash -n`) all touched/new scripts
only. Treat as "believed correct but unverified," same caveat as the
existing `11_configure_vm-*` note above.
