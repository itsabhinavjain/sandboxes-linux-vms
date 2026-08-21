#!/usr/bin/env bash
# Shared helpers for the host-administration tier (scripts/8*_host_*.sh --
# 83/84 today). Deliberately separate from scripts/lib/common.sh, which is
# the VM-tier's own contract (env-var loading, state.yaml helpers, etc.) --
# see CLAUDE.md's "Script conventions (host-administration scripts)" for why
# this tier doesn't source that file. Requires `sudo virsh` to already work;
# callers are responsible for their own env-var validation before sourcing.

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# yes/no prompt; honors a FORCE=1 set by the caller (e.g. a -y/--force flag)
# to skip straight to "yes".
confirm() {
    local prompt="${1:-Continue?}"
    if [[ "${FORCE:-0}" -eq 1 ]]; then
        return 0
    fi
    local reply
    read -r -p "${prompt} (yes/no): " reply
    [[ "$reply" == "yes" ]]
}

# There's no real `virsh pool-is-active` subcommand -- check the "State:"
# line from pool-info instead. Capture to a variable before grepping it,
# not a straight pipe into `grep -q`, to avoid the SIGPIPE race under
# `pipefail` documented in DECISIONS.md. (This exact gap bit both 83 and 84
# independently, as two separate bugs fixed on two separate days, before
# this helper existed to share -- see PLAN.md's 2026-08-21 agent log.)
pool_is_active() {
    local pool="$1" info
    info="$(sudo virsh pool-info "$pool" 2>/dev/null)" || return 1
    grep -q "^State:.*running" <<< "$info"
}

# Define (or redefine, if it exists but points at the wrong directory) a
# directory-based libvirt storage pool, then ensure autostart + running.
# Idempotent: safe to call against a pool that's already correct, already
# active, or currently inactive (e.g. mid-migration in 84).
ensure_pool() {
    local pool="$1" target="$2"
    log "Ensuring pool: $pool -> $target"

    local exists=0 current_target=""
    if sudo virsh pool-info "$pool" >/dev/null 2>&1; then
        exists=1
        current_target="$(
            sudo virsh pool-dumpxml "$pool" |
            sed -n 's:.*<path>\(.*\)</path>.*:\1:p' |
            head -n1
        )"
    fi

    if [[ "$exists" -eq 0 ]]; then
        log "    Pool does not exist; creating it."
        sudo virsh pool-define-as "$pool" dir --target "$target"
    elif [[ "$current_target" != "$target" ]]; then
        log "    Existing pool points to $current_target, expected $target -- redefining."
        if pool_is_active "$pool"; then
            sudo virsh pool-destroy "$pool"
        fi
        sudo virsh pool-undefine "$pool"
        sudo virsh pool-define-as "$pool" dir --target "$target"
    else
        log "    Pool definition is already correct."
    fi

    local autostart_out
    autostart_out="$(sudo virsh pool-autostart "$pool" 2>&1)"
    if ! grep -q "already marked" <<< "$autostart_out"; then
        sudo virsh pool-autostart "$pool" >/dev/null
    fi

    if pool_is_active "$pool"; then
        log "    Pool is already active."
    else
        log "    Starting pool."
        sudo virsh pool-start "$pool"
    fi

    sudo virsh pool-refresh "$pool" >/dev/null
}
