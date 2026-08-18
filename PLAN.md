## ROADMAP 
## Things to implement 
- [ ] user-data customization. Can ask to specify the user instead of hardcoded to `abhinav`. this can also be controlled from an environment variable. 
- VM configuration 
  - [ ] the current configuration script is simple. It essentially sets up Tailscale, UFW and Docker only. We can have additional configuration scripts and divide them in simple, advanced, more advanced etc where they can install additional things like Claude code etc. 
  - [ ] Make working within VM easy : in cloudinit or in configuration files, we migt want to add things like autocompelte, history search, jq, fzf etc everything that essentially makes working with VMs easier. Additionally we can install samba server. We can also install VS code extensions that helps working with and navigating the repo easily - e.g. Markdown files handling liek we do in obsidian etc. 

## Wishlist (Might implement later. Dont implement this right now - overengineering and wastage of time)
- [ ] Snapshot scripts (`21/22` snapshot scripts)
- [ ] Move from individual yaml state files to a global repository. Think this through later. Dont waste your time on this. 
- CLI tool development (Long shot - Dont invest your time on this right now)
  - [ ] Change from scripts to an actual cli tool that I can design. That would make it more distributable 
  - [ ] When making into a CLI tool, you can actually make the tool a little more generic and support other types of sandboxes like - microvms, docker containers etc 
  - [ ] While implementing the cli tool, you could also implement a gateway of sort and expose using an API so that AI agents can provision and manage the sandboxes on demand 

--- 

## AGENT LOGS 
Claude and Other Coding Agents can add their log here :- 

### 2026-08-18 (6) -- Claude (Sonnet 5)
End-to-end verification of the Tailscale auth-key setup and the
destroy-time API cleanup from log entry (5) below, once the user generated
real credentials (a reusable+ephemeral key tagged `tag:dmz-ephemeral`, and
an OAuth client scoped to Devices Core write + that same tag) and added
them to `.env`. Ran a real lifecycle against this host and the user's real
tailnet (`dog-tortoise.ts.net`): `09_doctor_host.sh` -> create+boot a test
VM (`ts-func-test`) -> `11_configure_vm.sh --skip-docker` (joins Tailscale,
enables UFW) -> `06_doctor_vm.sh` (all checks passed, including
guest-side Tailscale/UFW) -> `04_destroy_vm.sh --force` -> recreated a
second VM with the identical name -> configured it again -> destroyed it
again. Every "VM deleted"/"tailnet device removed" claim was cross-checked
independently (via `tailscale status` on the host and a fresh Tailscale API
device listing), not just trusted from the scripts' own log output.

**Confirmed the core fix works**: the recreated VM registered as exactly
`ts-func-test` with no `-1` suffix, i.e. the OAuth-based device deletion in
`04_destroy_vm.sh` (added in log entry (5)) genuinely frees the hostname
before a same-named VM is recreated -- the scenario this was all built for.

**Found and fixed a real security bug while testing**, unrelated to the
work in (5): the very first `11_configure_vm.sh` run printed the actual
`TAILSCALE_AUTHKEY` value in plaintext to stdout (visible in this session's
tool output). Root cause: `configure_bring_up_tailscale()` in
`scripts/lib/configure_steps.sh` correctly pipes the authkey over stdin
(to keep it out of `ps` on the remote host) but forced `ssh -tt` (pty
allocation) on that same call for live-output streaming -- and a pty
echoes back whatever it receives on stdin, undoing the whole point of
piping it. Fixed by dropping `-tt` from that one call site only (every
other remote step in the file still uses it, since they don't pipe
secrets). Re-verified by re-running configuration against a live VM and
grepping the full output for the key pattern -- zero matches on the fixed
version (the first re-verification attempt was a false positive: the rerun
had actually failed to reach the VM at all, for an unrelated reason below,
so it never reached the vulnerable code path -- caught this by checking the
run's actual exit status/log content instead of trusting a piped
`grep -c` exit code). **Told the user to revoke/regenerate the exposed
key** at https://login.tailscale.com/admin/settings/keys since it's now in
this transcript; a reusable key revocation doesn't disconnect devices
already joined with it, so this doesn't require re-touching the test VM.

Also hit, incidentally: `TAILSCALE_TAILNET` was unset in `.env` (just
`TAILSCALE_AUTHKEY`/`TAILSCALE_API_CLIENT_ID`/`_SECRET` had been added), and
once UFW came up on the test VM its DHCP/NAT IP stopped being reachable (by
design) with no `TAILSCALE_TAILNET` to build the Tailscale-hostname SSH
fallback -- so the very next `11_configure_vm.sh`/`06_doctor_vm.sh` call
would have been unable to reach the guest at all. Set
`TAILSCALE_TAILNET="dog-tortoise.ts.net"` in `.env` (found via `tailscale
status --json` on this host) and cleaned up a stale duplicate
`TAILSCALE_TAILNET=""` block in `.env` left over from an earlier
`env.sample` copy (referenced the old `05_destroy_vm.sh` script name, from
before that script was renumbered). Not a code bug -- `env.sample` already
documents this var -- but worth flagging since its absence surfaces as a
generic "can't reach VM" failure with no obvious link to UFW.

Left the test host clean: no VMs (`50_list_vms.sh` confirms empty), no
leftover tailnet devices, `ssh-keygen -R`'d the throwaway IPs this session
touched directly (the scripts' own SSH calls already use
`UserKnownHostsFile=/dev/null`, so nothing from them persisted).
DECISIONS.md's "Decision : Tailscale device cleanup on destroy" entry
updated in place to reflect verified status instead of "believed correct
but unverified."

### 2026-08-18 (5) -- Claude (Sonnet 5)
Discussed Tailscale auth-key strategy for these sandbox VMs against the
user's existing tag taxonomy (`dmz-persistent`/`dmz-ephemeral`/
`machine-ephemeral`) and ACL grants -- recommended a single reusable +
ephemeral key tagged `tag:dmz-ephemeral` (matches these VMs' actual shape:
throwaway, outbound-internet-only, reachable by the user's own member
devices via the existing `autogroup:member -> *` grant regardless of tag).
No code needed for that part -- `configure_steps.sh`'s `tailscale up
--authkey=... --hostname=$VMNAME` already just inherits whatever
tag/ephemeral properties the key itself carries.

Then walked through two concrete scenarios (destroy -> recreate same name;
stop -> restart after a gap) and found neither guarantees reclaiming the
same tailnet hostname, because none of `01_start_vm.sh`/`02_stop_vm.sh`/
`04_destroy_vm.sh` ever talk to Tailscale -- an ephemeral node only gets
cleaned up on Tailscale's own schedule, not this toolkit's, so a fast
destroy+recreate can collide with a still-present stale device (Tailscale
auto-suffixes the new one, e.g. `myvm-1`) and a long stop can outlast the
ephemeral-cleanup window (VM comes back with no working `tailscale0`).

Fixed the destroy/recreate gap: new `scripts/lib/tailscale_api.sh`
(OAuth-client-based -- exchanges `TAILSCALE_API_CLIENT_ID`/`_SECRET` for a
short-lived bearer token, looks up the tailnet device by hostname, deletes
it), wired into `04_destroy_vm.sh` as a best-effort step after local
teardown. Chose OAuth-client over a personal API token (can be scoped to
both a permission -- Devices Core write-only -- and a *tag*, e.g. only
`tag:dmz-ephemeral`, so the credential can't touch anything else on the
tailnet) and over SSH-based `tailscale logout` (works even if the guest is
already unreachable by the time destroy runs, since it talks to Tailscale's
control plane directly from the host). Both env vars are optional --
missing them just logs a skip note rather than failing the destroy. Added
`jq` as an optional dependency (present on this host already) -- noted in
`SETUP.md` and as a non-fatal check in `09_doctor_host.sh`, mirroring the
existing `kvm-ok`-optional pattern. Documented the full rationale in
`DECISIONS.md` ("Decision : Tailscale device cleanup on destroy") and
updated `lifecycle.md`'s `04_destroy_vm.sh`/`01_start_vm.sh` sections.

Deliberately left the stop/long-restart gap as a documented caveat rather
than a code change (`lifecycle.md`, `01_start_vm.sh` section) -- fixing it
the same way (delete-on-stop) would break the common fast stop/restart case
where the same node/session should just resume for free; the fix there is
manual (`11_configure_vm.sh <vmname> --skip-docker --skip-ufw` to rejoin)
if it's ever actually hit.

Verified: `bash -n` on all touched/new files, `shellcheck` clean on
`scripts/lib/tailscale_api.sh` (pre-existing warnings elsewhere untouched),
and the two `jq` filters used in it tested standalone against sample
JSON (token extraction, device-id-by-hostname lookup) -- both produced the
expected output. **Not** exercised against the real Tailscale API in this
session (no OAuth client configured on this host yet) -- treat
`tailscale_api.sh` as "believed correct but unverified end-to-end" until
run against a real tailnet with real credentials.

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
