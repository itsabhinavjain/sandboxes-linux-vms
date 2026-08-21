# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A collection of bash scripts for managing a fleet of Linux VMs on a single host via `libvirt`/`virsh` + `qemu`, provisioned from golden cloud images with cloud-init. No app code, no build step — the scripts themselves are the product.

Full docs already exist and are the source of truth — read them instead of guessing:
- @lifecycle_vms.md — the contract for every VM/fleet script (`00`-`06`, `08`-`09`, `11`-`12`, `50`+): what each does, its flags, and a "Common Usage Patterns" section with copy-pasteable command sequences. Every script's `--help`/`-h` is the canonical source for its exact flags (lifecycle_vms.md intentionally doesn't restate them).
- @lifecycle_host.md — the equivalent contract for the host-*administration* scripts (`80`-`85`): host specs, dependency install, the `/etc/profile.d/sandbox.sh` bootstrap, libvirt storage-pool setup/migration. A different, less uniform tier than the VM scripts — see "Script conventions (host-administration scripts)" below before assuming it mirrors lifecycle_vms.md's guarantees.
- @DECISIONS.md — architecture rationale, and a "Gotchas / intentional decisions — don't 'fix' these" section (no pause/resume script, no live resize, no disk shrink, resize/configure logic isolated in `scripts/lib/`).
- @SETUP.md — one-time host bootstrap narrative, walking through the `80`-`85` scripts in order; @lifecycle_host.md has their actual flag/behavior contract.
- @PLAN.md — roadmap/wishlist, and an "AGENT LOGS" section: after doing meaningful work in this repo, append a dated log entry there matching the existing entries' style.

## Script conventions (VM/fleet scripts: `00`-`06`, `08`-`09`, `11`-`12`, `50`+)

- Run every script from the repo root: `./scripts/00_init_vm.sh myvm`.
- Every script starts with `source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"`, which runs under `set -euo pipefail`, auto-loads `.env`, and provides `die()`, `log()`, `confirm()`, `check_bin()`, `validate_vmname()`, `require_env()`, `state_init/get/set/set_raw/remove()`.
- Naming: single-VM scripts are `00`-`06`, suffixed `_vm.sh`; fleet-wide scripts are `50`+, suffixed `_vms.sh`; `09_doctor_host.sh` and `08_test.sh` are host-*level* (no vmname arg) but still belong to this tier — they source `common.sh`, need no `sudo`, and have full `--help`. Don't confuse them with the `80`+ host-*administration* scripts below, which are a different tier entirely (see lifecycle_host.md).
- `-i`/`--interactive` is one merged flag (not separate scripts) supported by `00_init_vm.sh`, `11_configure_vm.sh`, `12_resize_vm.sh` — it only changes whether the script prompts/confirms, never what it does. Explicit flags always win over interactive prompts.
- `--help`/`-h` is handled via a `USAGE=$(cat <<EOF ... EOF)` heredoc + `show_help_if_requested "$USAGE" "$@"`, called **before** `require_env` so help works even without a configured environment.
- Never call `virsh` directly — always through the `VIRSH=(virsh -c qemu:///system)` wrapper from `common.sh`, e.g. `"${VIRSH[@]}" dominfo "$VMNAME"`.
- **Never pipe `virsh` output straight into `grep -q`/`grep -qx` under `pipefail`** — it's a SIGPIPE race, already fixed in 3 places. Capture to a variable first, then grep the variable.
- State is per-VM YAML at `${STORAGE_POOL_DISKS}/<vmname>.state.yaml`, edited only via `yq` — this must be **mikefarah/yq (Go)**, not the apt `kislyuk/yq` (Python); the `-i` in-place `.key = "value"` syntax used here is Go-yq-specific.
- No scripts in this tier require `sudo` (relies on `libvirt`/`kvm` group membership + setgid pool dirs). If a change here seems to need `sudo`, something is likely off vs. the intended design.

## Script conventions (host-administration scripts: `80`-`85`)

These provision/manage the Linux host itself (packages, `/etc/profile.d/sandbox.sh`, libvirt storage pools) rather than any VM, and are a newer, deliberately less uniform tier — read @lifecycle_host.md before "fixing" them into the VM-tier conventions above:
- Naming: `NN_host_verb_noun.sh`, numbered `80`+ — no `_vm(s)` suffix.
- Most require `sudo` for their actual work (package installs, `chown`/`chmod` on `LIBVIRT_HOME`, `virsh pool-*` calls) — unlike the VM tier, needing `sudo` here is expected, not a smell.
- None source `scripts/lib/common.sh`; `83`/`84` do their own required-env-var checks inline instead.
- `--help`/`-h` is inconsistent: only `84` has it (and only `84` checks it before requiring env vars, matching the VM-tier convention). `80`/`81`/`82`/`85` take no flags at all and always run top-to-bottom.
- Idempotency varies per script — `83` and `84` are carefully idempotent (safe to re-run, only change what's actually wrong); `81`/`82` are safe to re-run but don't explicitly check state first (e.g. `apt install` on an already-installed package is just a no-op).

## Env / setup

- Required env vars (`SANDBOX_HOME`, `LIBVIRT_HOME`, five `STORAGE_POOL_*`, five `DEFAULT_*`) are validated by `require_env`; see `env.sample` for the template. Precedence: system env < repo-root `.env` (gitignored) < flags/`-i` prompts.
- `.env` contains real secrets (e.g. `TAILSCALE_AUTHKEY`) — never read it into a commit or otherwise expose its contents.
- Base cloud images (`STORAGE_POOL_IMAGES`) are read-only golden images; VM disks are qcow2 overlays on top — never modify a base image directly.
- Cloud-init runs exactly once per VM (it self-disables via `touch /etc/cloud/cloud-init.disabled` in `runcmd`). Post-boot config changes (Tailscale, UFW, Docker) go through `11_configure_vm.sh`, not by editing `setup_config/user-data.tmpl` and expecting existing VMs to pick it up.
- Disk resize (`12_resize_vm.sh`) is grow-only; RAM/vCPU resize requires the VM stopped and only edits persistent `--config` (no live hotplug).
- `11_configure_vm.sh` refuses to enable UFW unless `tailscale0` is confirmed up first, to avoid SSH lockouts (`--skip-ufw` bypasses this).

## Linting

`.shellcheckrc` at the repo root configures `shellcheck` (run it as `shellcheck scripts/*.sh scripts/lib/*.sh`). No CI runs it yet — treat it as a manual check after editing any script.

## Testing

- There's no CI and no Makefile. `./scripts/08_test.sh` is the closest thing to a test suite — it's a real end-to-end smoke test that creates and destroys ephemeral VMs against an actual libvirt host, running `09_doctor_host.sh` first and aborting if that fails.
- Before debugging anything that "seems off," run `./scripts/09_doctor_host.sh` (host-level checks) and/or `./scripts/06_doctor_vm.sh <vmname>` (per-VM checks) first.
