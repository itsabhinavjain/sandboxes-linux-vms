# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal bash tooling for creating and managing libvirt/KVM Linux VMs on a single Linux host, built around Ubuntu cloud images + cloud-init. Solo project (author: Abhinav Jain), documentation/design-decisions-first — see `PLAN.md` (decision log + Wishlist of unbuilt items) and `LOGS.md` (shorter changelog). No package manager, build system, or CI; "running" the project means invoking the numbered scripts in `scripts/` against a real libvirt host.

## Never run lifecycle scripts directly

Scripts under `scripts/` (`00_init_vm-automated.sh`, `00_init_vm-interactive.sh`, `01_start_vm.sh` ... `05_destroy_vm.sh`, `11_configure_vm-automated.sh`, `11_configure_vm-interactive.sh`) create/start/stop/destroy real VMs and mutate real libvirt/storage state. Always propose the command and let the user run it — never invoke these yourself. Read-only scripts (`08_status_vm.sh`, `09_doctor.sh`, `50_list_vms.sh`, `51_info_vms.sh`) are fine to run directly. `SETUP.md` (host bootstrap) requires `sudo` and touches shared system state — never run without explicit confirmation.

## Script naming convention

- `NN_verb_vm.sh` (00–08): acts on a single VM, takes `<vmname>` as first arg.
- `NN_verb_vms.sh` (50+): fleet-wide, acts on all VMs, no vmname arg.
- `09_doctor.sh`: host-level diagnostics, no vmname.
- Scripts with both a non-interactive and an interactive variant share the same number and carry a `-automated`/`-interactive` suffix after `_vm` to distinguish them (e.g. `00_init_vm-automated.sh` / `00_init_vm-interactive.sh`, `11_configure_vm-automated.sh` / `11_configure_vm-interactive.sh`). Use "interactive", not "manual".
- `11` reserved for configuration scripts (`12` is free); `21`/`22` reserved (not yet built) for snapshot scripts.
- VM names should look like `vir-ubuntu-01` (human convention only — `validate_vmname()` in `scripts/lib/common.sh` just enforces `^[a-zA-Z0-9_-]+$`).

## Storage pool layout (5 pools, all under `LIBVIRT_HOME`)

- `images/` → pool `default` — read-only golden cloud `.img` files. Never modify the base image directly; VMs are qcow2 overlays.
- `isos/` → pool `iso-pool` — reserved for installer ISOs, currently unused (cloud-image flow only).
- `disks/` → pool `disk-pool` — flat, per-VM `<vmname>.qcow2` + `<vmname>.state.yaml`.
- `snapshots/` → pool `snapshot-pool` — reserved for *external* snapshots; currently unused (internal qcow2 snapshots were chosen instead — don't build external-snapshot logic without revisiting this decision).
- `cloud-init/` → pool `cloudinit-pool` — generated seed ISOs `<vmname>-seed.iso`.

## Required env vars

`scripts/lib/common.sh` auto-sources `.env` (gitignored) via `set -a`. Precedence: `/etc/profile.d/sandbox.sh` (system) < `.env` (repo) < CLI flags. `require_env()` fails fast if any of these are unset: `SANDBOX_HOME`, `LIBVIRT_HOME`, `STORAGE_POOL_IMAGES`, `STORAGE_POOL_ISOS`, `STORAGE_POOL_DISKS`, `STORAGE_POOL_SNAPSHOTS`, `STORAGE_POOL_CLOUD_INIT_ISOS`, `DEFAULT_CLOUD_IMG`, `DEFAULT_OS_VARIANT`, `DEFAULT_RAM_MB`, `DEFAULT_VCPUS`, `DEFAULT_DISK_GB`. `TAILSCALE_AUTHKEY` is a secret consumed by the configure scripts — never commit it.

## Bash conventions already in use

- `set -euo pipefail` in every script.
- Always call `virsh` through the `VIRSH=(virsh -c qemu:///system)` array wrapper, never bare/sudo `virsh` — scripts rely on `libvirt`/`kvm` group membership + setgid pool dirs, not sudo.
- Never pipe `virsh` output directly into `grep -q`/`grep -qx` under `pipefail` (SIGPIPE race) — capture to a variable first, then `grep <<< "$var"`. This bug was found and fixed in three places; don't reintroduce it.
- `yq` means the mikefarah/yq Go binary (installed manually per `SETUP.md`), not the apt-packaged Python kislyuk/yq — the `-i` in-place edit and `.key = "value"` syntax requires the Go version.

## Gotchas / intentional decisions — don't "fix" these

- `11_configure_vm-automated.sh` and `11_configure_vm-interactive.sh` share their SSH/remote-step-script logic via `scripts/lib/configure_steps.sh` — they differ only in whether each step runs unconditionally (`-automated`) or behind a `confirm()` prompt (`-interactive`). Don't duplicate that logic back into either script.
- Cloud-init runs once only — `00_init_vm-automated.sh` disables it after first boot, so template changes only affect newly-created VMs. Post-boot changes (Tailscale, UFW) go through `11_configure_vm-automated.sh`/`11_configure_vm-interactive.sh`.
- UFW is only ever enabled after `tailscale0` is confirmed up, specifically to avoid an SSH lockout with no fallback but `virsh console`.
- Networking is default libvirt NAT + Tailscale (not Tailscale SSH) for reachability at `<vmname>.<tailnet>.ts.net`. Bridged networking is explicitly deferred. `setup_config/network-config.tmpl` exists but is intentionally unused.
- `setup_config/user-data.tmpl` hardcodes user `abhinav`, three specific SSH keys, and timezone `Asia/Kolkata` — intentionally not parameterized beyond `${VMNAME}`.
- SSH-into-VM and `11_configure_vm-interactive.sh` are flagged in `PLAN.md` as unverified end-to-end — treat as "believed correct but unverified." The 2026-08-18 rename/split (`00_init_vm-interactive.sh`, `11_configure_vm-automated.sh` real implementation, shared `lib/configure_steps.sh`, and folding `12_configure_vm-interactive.sh` into `11_configure_vm-interactive.sh` so both configure scripts share number `11`) is likewise unverified against a real host — see `PLAN.md` design decision #13.
- There's no pause/resume script (`04_resume_vm.sh` was deleted 2026-08-18) — nothing in this toolkit calls `virsh suspend`, so it was dead code. Don't add it back without an actual pause use case.

## Scope

Only work on what's explicitly asked — don't proactively pick up open items from `PLAN.md`'s Wishlist unless requested.
