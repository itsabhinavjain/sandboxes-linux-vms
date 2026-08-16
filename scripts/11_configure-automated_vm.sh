#!/usr/bin/env bash
# Usage: scripts/11_configure-automated_vm.sh <vmname> [--skip-tailscale] [--skip-ufw] [--authkey KEY]
#
# Reserved for a future fully-automated (non-interactive, fire-and-forget)
# post-boot configuration pass -- joining an already-running VM to the
# Tailscale tailnet and locking UFW down to deny all inbound except
# tailscale0. Not implemented for now: use
# scripts/12_configure-manual_vm.sh <vmname> instead, which does the same
# job but confirms before each step. See PLAN.md (design decision #11) for
# why this file is being kept around as a placeholder rather than deleted.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_env

die "Not implemented yet -- use scripts/12_configure-manual_vm.sh $* for interactive configuration."
